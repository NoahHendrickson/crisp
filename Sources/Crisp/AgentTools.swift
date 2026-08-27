import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// The agent-facing side of the AI editor: the annotated stills an agent is
/// shown, the previews it can render of its own plan, and the `./crisp`
/// command line it runs from its workspace, which re-enters this binary as
///
///     Crisp --agent-tool --recording <folder> --workspace <dir> <command> …
///
/// Commands: `frame <t> [--raw] [--out name]`, `preview <t> [--plan file]
/// [--out name]`, `validate [file]`, `path [from] [to]`. Everything an agent
/// can see goes through here so the app and the tools agree on coordinates
/// and timing; the plan contract itself lives in `AgentPlan`.
enum AgentTools {
    /// Longest edge of any image handed to an agent: big enough to read UI
    /// text, small enough to fit a model's image budget.
    static let imageMaxEdge: Double = 1280

    // MARK: - Workspace

    /// The standing brief every agent gets: CLAUDE.md for Claude Code and
    /// AGENTS.md for Codex (both CLIs load these from the working directory
    /// on their own), plus the `./crisp` wrapper that re-enters this binary
    /// headlessly for frames, previews and validation.
    static func installWorkspace(in workspace: URL, recording: Recording) throws {
        let briefing = Data(AgentPlan.briefing(config: ZoomPlanner.Config()).utf8)
        try briefing.write(to: workspace.appendingPathComponent("CLAUDE.md"))
        try briefing.write(to: workspace.appendingPathComponent("AGENTS.md"))

        // Every path is quoted as one zsh word: a recording can be named
        // almost anything, and this is shell source.
        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let script = """
        #!/bin/zsh
        # Crisp agent tools — see AGENTS.md. Runs the app headlessly.
        exec \(shellQuoted(executable)) --agent-tool --recording \(shellQuoted(recording.folder.path)) --workspace \(shellQuoted(workspace.path)) "$@"

        """
        let scriptURL = workspace.appendingPathComponent("crisp")
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    /// `s` as a single zsh word: single-quoted, with any embedded quote
    /// closed, escaped and reopened. Nothing inside is expanded.
    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Command line

    static func runBlocking(_ arguments: [String]) {
        let semaphore = DispatchSemaphore(value: 0)
        var status: Int32 = 0
        Task.detached {
            do {
                status = try await run(arguments)
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                status = 2
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(status)
    }

    static let usage = """
        usage: ./crisp <command> [options]

          frame <seconds> [--raw] [--out name.jpg]
              Extract the video frame at that time. By default it is annotated with a
              coordinate grid (video pixels), the clicks within ±1.5s, the cursor, and
              the crop the current plan.json would show; --raw gives the clean frame.
          preview <seconds> [--plan plan.json] [--out name.jpg]
              Render what the export will show at that time under the plan: the real
              zoomed crop, cursor and click ripples. Look at it to judge framing.
          validate [plan.json]
              Check the plan against the app's rules and print the derived timing of
              every zoom and step. Exit status 1 when anything had to be changed.
          path [from] [to] [--step 0.1] [--plan plan.json]
              Print the camera over time under the plan (t, zoom, centre, speed):
              where the follower looks, as numbers.

        Times are seconds from the start of the video. Files are written into the
        workspace and their paths printed.
        """

    static func run(_ arguments: [String]) async throws -> Int32 {
        guard let toolIndex = arguments.firstIndex(of: "--agent-tool") else { return 2 }
        var args = Array(arguments[(toolIndex + 1)...])
        func takeOption(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            let value = args[i + 1]
            args.removeSubrange(i...(i + 1))
            return value
        }
        func takeFlag(_ name: String) -> Bool {
            guard let i = args.firstIndex(of: name) else { return false }
            args.remove(at: i)
            return true
        }
        guard let recordingPath = takeOption("--recording"), let workspacePath = takeOption("--workspace") else {
            print(usage)
            return 2
        }
        let recording = Recording(folder: URL(fileURLWithPath: recordingPath))
        let workspace = URL(fileURLWithPath: workspacePath, isDirectory: true)
        let command = args.first ?? "help"
        if command == "help" || command == "--help" {
            print(usage)
            return 0
        }
        let meta = try recording.loadMeta()
        let duration = try await AVURLAsset(url: recording.masterURL).load(.duration).seconds
        let planner = ZoomPlanner(meta: meta)

        /// The plan the tools work from: the file named, else the workspace's
        /// plan.json, else the automatic plan from the click log. Rule
        /// violations are printed as notes so a preview never silently shows
        /// something other than what would apply.
        func loadPlan(_ path: String?, quiet: Bool = false) throws -> [ZoomSegment]? {
            let url = path.map { URL(fileURLWithPath: $0, relativeTo: workspace) }
                ?? workspace.appendingPathComponent("plan.json")
            guard let data = try? Data(contentsOf: url) else {
                if path != nil { throw ToolError.message("no plan at \(url.path)") }
                if !quiet { print("note: no plan.json here — using the automatic plan from the click log") }
                return planner.segments(events: meta.events, duration: duration)
            }
            let parsed = try AgentPlan.parse(data, duration: duration, meta: meta)
            if !quiet {
                for issue in parsed.issues { print("note: \(issue)") }
            }
            return parsed.segments
        }

        func time(_ raw: String?) throws -> Double {
            guard let raw, let t = Double(raw) else { throw ToolError.message("expected a time in seconds") }
            guard t >= 0, t <= duration else {
                throw ToolError.message(String(format: "time %.2f is outside the video (0–%.2fs)", t, duration))
            }
            return t
        }

        switch command {
        case "frame":
            let raw = takeFlag("--raw")
            let out = takeOption("--out")
            let t = try time(args.dropFirst().first)
            let segments = try loadPlan(nil, quiet: true) ?? []
            let name = out ?? String(format: "frame_t%05.2f%@.jpg", t, raw ? "_raw" : "")
            let url = workspace.appendingPathComponent(name)
            let image = try await extractFrame(masterURL: recording.masterURL, at: t)
            let camera = segments.isEmpty ? nil
                : ZoomPlanner.evaluate(planner.keyframes(from: segments, duration: duration), at: t)
            let annotated = raw ? scaled(image) : annotate(
                image, meta: meta, at: t, crop: camera, clicks: clicks(in: meta, near: t),
                cursor: FrameComposer.cursorPosition(samples: meta.samples, at: t).map { ($0.x, $0.y) },
                caption: caption(for: meta, at: t, extra: "annotated: grid in video pixels")
            )
            guard let annotated else { throw ToolError.message("could not draw the frame") }
            try writeJPEG(annotated, to: url)
            print(url.path)
            return 0

        case "preview":
            let planPath = takeOption("--plan")
            let out = takeOption("--out")
            let t = try time(args.dropFirst().first)
            guard let segments = try loadPlan(planPath) else {
                throw ToolError.message("no plan to preview")
            }
            let name = out ?? String(format: "preview_t%05.2f.jpg", t)
            let url = workspace.appendingPathComponent(name)
            let camera = try await renderPreview(
                recording: recording, meta: meta, segments: segments, duration: duration,
                cursorStyle: recording.loadPlan()?.cursorStyle ?? .classic, at: t, to: url
            )
            let visible = visibleRect(camera, meta: meta)
            print(url.path)
            print(String(format: "zoom %.2f× centred on (%.0f, %.0f) — visible area x %.0f–%.0f, y %.0f–%.0f",
                         camera.zoom, camera.center.x, camera.center.y,
                         visible.minX, visible.maxX, visible.minY, visible.maxY))
            return 0

        case "validate":
            let url = args.dropFirst().first.map { URL(fileURLWithPath: $0, relativeTo: workspace) }
                ?? workspace.appendingPathComponent("plan.json")
            let parsed: AgentPlan.Parsed
            if let data = try? Data(contentsOf: url) {
                do {
                    parsed = try AgentPlan.parse(data, duration: duration, meta: meta)
                } catch {
                    print("INVALID: \(error.localizedDescription)")
                    return 1
                }
            } else if args.count > 1 {
                throw ToolError.message("no plan at \(url.path)")
            } else {
                print("note: no plan.json here — describing the automatic plan from the click log")
                parsed = AgentPlan.Parsed(
                    segments: planner.segments(events: meta.events, duration: duration), issues: [], declared: 0
                )
            }
            print(AgentPlan.describe(parsed.segments, planner: planner, duration: duration))
            if parsed.issues.isEmpty {
                print("OK — \(parsed.segments.count) zoom(s), \(parsed.segments.reduce(0) { $0 + $1.steps.count }) step(s); the plan applies exactly as written.")
                return 0
            }
            print("\nADJUSTMENTS NEEDED — the app would change these on apply:")
            for issue in parsed.issues { print("- \(issue)") }
            return 1

        case "path":
            let planPath = takeOption("--plan")
            let stepRaw = takeOption("--step")
            let step = max(0.02, Double(stepRaw ?? "") ?? 0.1)
            let bounds = Array(args.dropFirst())
            let from = try time(bounds.first ?? "0")
            let to = try time(bounds.dropFirst().first ?? String(duration))
            guard let segments = try loadPlan(planPath) else { throw ToolError.message("no plan") }
            let keys = planner.keyframes(from: segments, duration: duration)
            print("t\tzoom\tcx\tcy\tspeed(px/s)")
            var previous: Camera?
            var t = from
            while t <= to + 1e-9 {
                let camera = ZoomPlanner.evaluate(keys, at: t)
                let speed = previous.map { hypot(camera.center.x - $0.center.x, camera.center.y - $0.center.y) / step } ?? 0
                print(String(format: "%.2f\t%.2f\t%.0f\t%.0f\t%.0f", t, camera.zoom, camera.center.x, camera.center.y, speed))
                previous = camera
                t += step
            }
            return 0

        default:
            print(usage)
            return 2
        }
    }

    enum ToolError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let text) = self { return text }
            return nil
        }
    }

    // MARK: - Frames for the briefing

    /// Remove the stills an earlier turn wrote (`frame_N.jpg`, `moment_*.jpg`)
    /// so the agent never studies a previous plan's framing as current. The
    /// stills the agent made itself (`frame_tNN.NN.jpg`, `preview_*.jpg`) stay.
    static func clearStills(in workspace: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: workspace.path)) ?? []
        for name in names where name.hasSuffix(".jpg") {
            let ours = name.hasPrefix("moment_")
                || (name.hasPrefix("frame_") && name.dropFirst("frame_".count).first?.isNumber == true)
            if ours { try? FileManager.default.removeItem(at: workspace.appendingPathComponent(name)) }
        }
    }

    /// The stills handed over with each turn: a wide establishing shot, each
    /// zoom's hold opening, click bursts no zoom covers, and each step once
    /// it has eased in — in that priority, capped at 12, annotated. Replaces
    /// the previous turn's set entirely.
    static func extractFrames(
        recording: Recording, meta: RecordingMeta, segments: [ZoomSegment], duration: Double,
        into workspace: URL
    ) async throws -> [AgentPlan.Frame] {
        clearStills(in: workspace)
        let planner = ZoomPlanner(meta: meta)
        var wanted: [(t: Double, label: String, priority: Int)] = [
            (min(0.5, duration / 2), "wide establishing shot", 0),
        ]
        for (i, seg) in segments.enumerated() {
            wanted.append((min(seg.start + 0.1, max(0, duration - 0.05)),
                           String(format: "zoom %d hold opens (%.2fs)", i + 1, seg.start), 1))
            for step in seg.steps.sorted(by: { $0.t < $1.t }) {
                let window = planner.stepWindow(step, in: seg, duration: duration)
                wanted.append((window.end, String(format: "zoom %d steps to %.1f× (%.2fs)", i + 1, step.zoom, window.end), 3))
            }
        }
        for cluster in planner.clickClusters(meta.events)
        where !segments.contains(where: { $0.start - 0.5 <= cluster.start && cluster.end <= $0.end + 0.5 }) {
            wanted.append((min(cluster.start + 0.05, max(0, duration - 0.05)),
                           String(format: "%d click(s) at %.2fs — no zoom covers them", cluster.count, cluster.start), 2))
        }
        let chosen = wanted
            .sorted { ($0.priority, $0.t) < ($1.priority, $1.t) }
            .prefix(12)
            .sorted { $0.t < $1.t }

        let keys = planner.keyframes(from: segments, duration: duration)
        var frames: [AgentPlan.Frame] = []
        for (index, item) in chosen.enumerated() {
            guard let image = try? await extractFrame(masterURL: recording.masterURL, at: item.t) else { continue }
            let camera = segments.isEmpty ? nil : ZoomPlanner.evaluate(keys, at: item.t)
            guard let annotated = annotate(
                image, meta: meta, at: item.t, crop: camera, clicks: clicks(in: meta, near: item.t),
                cursor: FrameComposer.cursorPosition(samples: meta.samples, at: item.t).map { ($0.x, $0.y) },
                caption: caption(for: meta, at: item.t, extra: item.label)
            ) else { continue }
            let name = "frame_\(index).jpg"
            try writeJPEG(annotated, to: workspace.appendingPathComponent(name))
            frames.append(AgentPlan.Frame(file: name, t: item.t, label: item.label))
        }
        return frames
    }

    // MARK: - Click analysis

    static func clicks(in meta: RecordingMeta, near t: Double, window: Double = 1.5) -> [MouseEvent] {
        meta.events.filter { ($0.kind == .leftDown || $0.kind == .rightDown) && abs($0.t - t) <= window }
    }

    // MARK: - Rendering

    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func makeGenerator(masterURL: URL) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: masterURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        return generator
    }

    /// The full-resolution master frame at `t`.
    static func extractFrame(masterURL: URL, at t: Double) async throws -> CGImage {
        let generator = makeGenerator(masterURL: masterURL)
        return try await generator.image(at: CMTime(seconds: max(0, t), preferredTimescale: 600)).image
    }

    /// The exported look at `t` under `segments`, through the real compositor
    /// (zoom crop, vector cursor, click ripples), written as a JPEG. The cursor
    /// style is the recording's, not the agent's to choose.
    @discardableResult
    static func renderPreview(
        recording: Recording, meta: RecordingMeta, segments: [ZoomSegment], duration: Double,
        cursorStyle: CursorStyle, at t: Double, to url: URL
    ) async throws -> Camera {
        let source = try await extractFrame(masterURL: recording.masterURL, at: t)
        let planner = ZoomPlanner(meta: meta)
        let keys = planner.keyframes(from: segments, duration: duration)
        let composer = FrameComposer(meta: meta, keys: keys, cursorStyle: cursorStyle)
        let composed = composer.compose(source: CIImage(cgImage: source), at: t)
        let context = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])
        guard let rendered = context.createCGImage(composed, from: composed.extent) else {
            throw ToolError.message("could not render the preview")
        }
        let camera = ZoomPlanner.evaluate(keys, at: t)
        let visible = visibleRect(camera, meta: meta)
        let caption = String(
            format: "preview  t=%.2fs  zoom %.2f×  centre (%.0f, %.0f)  visible x %.0f–%.0f  y %.0f–%.0f",
            t, camera.zoom, camera.center.x, camera.center.y,
            visible.minX, visible.maxX, visible.minY, visible.maxY
        )
        guard let image = annotate(rendered, meta: meta, at: t, crop: nil, clicks: [], cursor: nil,
                                   caption: caption, grid: false) else {
            throw ToolError.message("could not draw the preview")
        }
        try writeJPEG(image, to: url)
        return camera
    }

    /// The part of the master the camera shows, in video pixels.
    static func visibleRect(_ camera: Camera, meta: RecordingMeta) -> CGRect {
        let w = Double(meta.pixelWidth) / camera.zoom
        let h = Double(meta.pixelHeight) / camera.zoom
        return CGRect(x: camera.center.x - w / 2, y: camera.center.y - h / 2, width: w, height: h)
    }

    static func caption(for meta: RecordingMeta, at t: Double, extra: String) -> String {
        String(format: "t=%.2fs  %@  ·  video %d×%d px", t, extra, meta.pixelWidth, meta.pixelHeight)
    }

    /// Downscale to the agent image size, no annotation.
    static func scaled(_ image: CGImage) -> CGImage? {
        let scale = min(1, imageMaxEdge / Double(max(image.width, image.height)))
        let w = Int(Double(image.width) * scale)
        let h = Int(Double(image.height) * scale)
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Draw the frame at agent size with, in video-pixel terms: a labelled
    /// grid, rings on nearby clicks (with their times), the cursor, the crop
    /// the plan shows at that moment, and a caption. Everything an agent
    /// needs to turn "that button" into cx/cy it can trust.
    static func annotate(
        _ image: CGImage, meta: RecordingMeta, at t: Double, crop: Camera?, clicks: [MouseEvent],
        cursor: (x: Double, y: Double)?, caption: String, grid: Bool = true
    ) -> CGImage? {
        let videoW = Double(meta.pixelWidth)
        let videoH = Double(meta.pixelHeight)
        let scale = min(1, imageMaxEdge / max(Double(image.width), Double(image.height)))
        let w = Int(Double(image.width) * scale)
        let h = Int(Double(image.height) * scale)
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Work in top-left video coordinates from here on.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)  // image px → output px
        let v = Double(w) / videoW                                   // video px → output px
        func P(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * v, y: y * v) }

        if grid {
            let step: Double = videoW > 3000 ? 500 : (videoW > 1600 ? 200 : 100)
            ctx.setLineWidth(1)
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.35))
            for x in stride(from: step, to: videoW, by: step) {
                ctx.move(to: P(x, 0)); ctx.addLine(to: P(x, videoH))
            }
            for y in stride(from: step, to: videoH, by: step) {
                ctx.move(to: P(0, y)); ctx.addLine(to: P(videoW, y))
            }
            ctx.strokePath()
            ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25))
            for x in stride(from: step, to: videoW, by: step) {
                ctx.move(to: P(x + 1 / v, 0)); ctx.addLine(to: P(x + 1 / v, videoH))
            }
            for y in stride(from: step, to: videoH, by: step) {
                ctx.move(to: P(0, y + 1 / v)); ctx.addLine(to: P(videoW, y + 1 / v))
            }
            ctx.strokePath()
            for x in stride(from: step, to: videoW, by: step) {
                drawText("\(Int(x))", at: CGPoint(x: x * v + 2, y: 2), in: ctx)
            }
            for y in stride(from: step, to: videoH, by: step) {
                drawText("\(Int(y))", at: CGPoint(x: 2, y: y * v + 2), in: ctx)
            }
        }

        if let crop {
            let rect = visibleRect(crop, meta: meta)
            ctx.setLineWidth(2)
            ctx.setStrokeColor(CGColor(srgbRed: 0.2, green: 0.85, blue: 0.45, alpha: 0.95))
            ctx.stroke(CGRect(x: rect.minX * v, y: rect.minY * v, width: rect.width * v, height: rect.height * v))
            drawText(String(format: "plan crop %.2f× centre (%.0f, %.0f)", crop.zoom, crop.center.x, crop.center.y),
                     at: CGPoint(x: rect.minX * v + 4, y: rect.minY * v + 4), in: ctx,
                     background: CGColor(srgbRed: 0, green: 0.4, blue: 0.2, alpha: 0.8))
        }

        for click in clicks.sorted(by: { abs($0.t - t) < abs($1.t - t) }).reversed() {
            let nearest = clicks.min { abs($0.t - t) < abs($1.t - t) }.map { $0.t == click.t } ?? false
            let color = nearest
                ? CGColor(srgbRed: 1, green: 0.2, blue: 0.3, alpha: 0.95)
                : CGColor(srgbRed: 1, green: 0.6, blue: 0.1, alpha: 0.9)
            let r: Double = 12
            let c = P(click.x, click.y)
            ctx.setLineWidth(2)
            ctx.setStrokeColor(color)
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.move(to: CGPoint(x: c.x - 4, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + 4, y: c.y))
            ctx.move(to: CGPoint(x: c.x, y: c.y - 4)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + 4))
            ctx.strokePath()
            drawText(String(format: "%@ %.2fs (%.0f, %.0f)", click.kind == .rightDown ? "right-click" : "click",
                            click.t, click.x, click.y),
                     at: CGPoint(x: c.x + r + 3, y: c.y - 8), in: ctx, background: color)
        }

        if let cursor {
            let c = P(cursor.x, cursor.y)
            ctx.setFillColor(CGColor(srgbRed: 0.25, green: 0.55, blue: 1, alpha: 0.95))
            ctx.fillEllipse(in: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10))
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9))
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10))
        }

        drawText(caption, at: CGPoint(x: 6, y: Double(h) - 24), in: ctx, size: 12)
        return ctx.makeImage()
    }

    /// Small monospaced label with a dark pill, `at` = top-left in the
    /// flipped (top-left origin) context.
    private static func drawText(
        _ text: String, at point: CGPoint, in ctx: CGContext, size: CGFloat = 11,
        background: CGColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.65)
    ) {
        let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let pad: CGFloat = 3
        let box = CGRect(x: point.x, y: point.y, width: bounds.width + 2 * pad, height: bounds.height + 2 * pad)
        ctx.setFillColor(background)
        ctx.fill(box)
        ctx.saveGState()
        ctx.textMatrix = .identity
        // Un-flip just for the glyphs: origin at the box's bottom-left inset.
        ctx.translateBy(x: box.minX + pad, y: box.maxY - pad)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = CGPoint(x: 0, y: -bounds.minY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    static func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ToolError.message("could not create \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ToolError.message("could not write \(url.lastPathComponent)")
        }
    }
}
