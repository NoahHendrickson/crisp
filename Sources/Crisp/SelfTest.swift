import Foundation
import AVFoundation
import CoreGraphics
import CoreImage

/// Headless pipeline check (`Crisp --selftest`): synthesizes a short gradient
/// master with fake click events, runs the real zoom-export renderer on it, and
/// verifies the output. Exercises the 10-bit HEVC decode → Core Image →
/// 10-bit HEVC encode path without needing screen-recording permission.
enum SelfTest {

    static func runBlocking() {
        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?
        Task.detached {
            do {
                try await run()
            } catch {
                failure = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let failure {
            FileHandle.standardError.write(Data("SELFTEST FAILED: \(failure)\n".utf8))
            exit(1)
        }
        print("SELFTEST PASSED")
        exit(0)
    }

    static func run() async throws {
        // The folder name carries every shell metacharacter a recording name
        // can (only "/" and ":" are refused), so the agent's `./crisp` wrapper
        // is exercised against a hostile path.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("crisp-selftest-\(ProcessInfo.processInfo.processIdentifier) it's \"$(echo pwned)\" `x`", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let keep = ProcessInfo.processInfo.environment["CRISP_SELFTEST_KEEP"] == "1"
        defer {
            if keep {
                print("selftest: kept output at \(folder.path)")
            } else {
                try? FileManager.default.removeItem(at: folder)
            }
        }

        try checkCursorKind()
        try checkCursorStyle()
        print("selftest: cursor kind decode + hold ok")

        let recording = Recording(folder: folder)
        let width = 1280
        let height = 800
        let duration = 2.0
        let sourceFPS = 30.0

        try writeSyntheticMaster(
            to: recording.masterURL, width: width, height: height,
            duration: duration, fps: sourceFPS
        )
        try writeSyntheticEvents(
            to: recording.eventsURL, width: width, height: height, duration: duration
        )
        do {
            let meta = try recording.loadMeta()
            guard meta.samples.contains(where: { $0.kind == .pointer }),
                  meta.samples.contains(where: { $0.kind == nil }) else {
                throw SelfTestError.cursor("synthetic events missing pointer span or arrow ticks")
            }
        }

        print("selftest: master written, exporting with zooms...")
        let renderer = Renderer()
        let exportURL = try await renderer.export(recording: recording) { fraction in
            print(String(format: "selftest: export %3.0f%%", fraction * 100))
        }
        guard exportURL.lastPathComponent == "export.mov" else {
            throw SelfTestError.badExportName(exportURL.lastPathComponent)
        }

        // Verify the export.
        let asset = AVURLAsset(url: exportURL)
        let exportedDuration = try await asset.load(.duration).seconds
        guard abs(exportedDuration - duration) < 0.25 else {
            throw SelfTestError.badDuration(exportedDuration)
        }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw SelfTestError.noTrack
        }
        let size = try await track.load(.naturalSize)
        guard Int(size.width) == width, Int(size.height) == height else {
            throw SelfTestError.badSize(size)
        }
        let bytes = try FileManager.default.attributesOfItem(atPath: exportURL.path)[.size] as? Int ?? 0
        print("selftest: export ok — \(Int(size.width))×\(Int(size.height)), \(String(format: "%.2f", exportedDuration))s, \(bytes / 1024) KB")

        // Second pass: export again through an edited plan.json (the editor path).
        recording.savePlan([
            ZoomSegment(start: 0.4, end: 1.4, zoom: 2.2, steps: [ZoomStep(t: 0.8, zoom: 2.6)])
        ], cursorStyle: .bubbly)
        // Re-exporting (as MP4/H.264) must not overwrite the first export: it
        // should land in a numbered sibling file.
        let planURL = try await Renderer().export(recording: recording, format: .mp4H264) { _ in }
        guard planURL.lastPathComponent == "export 2.mp4",
              FileManager.default.fileExists(atPath: exportURL.path),
              recording.exportURLs == [exportURL, planURL] else {
            throw SelfTestError.badExportName(planURL.lastPathComponent)
        }
        // Each export carries a snapshot of the plan that produced it,
        // cursor style included.
        let snapshot = Recording.loadPlan(from: Recording.planSnapshotURL(for: planURL))
        guard snapshot?.segments.count == 1, snapshot?.cursorStyle == .bubbly else {
            throw SelfTestError.badExportName("missing or incomplete plan snapshot for \(planURL.lastPathComponent)")
        }
        let planAsset = AVURLAsset(url: planURL)
        let planDuration = try await planAsset.load(.duration).seconds
        guard abs(planDuration - duration) < 0.25 else {
            throw SelfTestError.badDuration(planDuration)
        }
        guard let planTrack = try await planAsset.loadTracks(withMediaType: .video).first,
              let desc = try await planTrack.load(.formatDescriptions).first,
              CMFormatDescriptionGetMediaSubType(desc) == kCMVideoCodecType_H264 else {
            throw SelfTestError.noTrack
        }
        print("selftest: edited-plan export ok — \(planURL.lastPathComponent), \(String(format: "%.2f", planDuration))s")
        let hevcURL = try await Renderer().export(recording: recording, format: .mp4HEVC) { _ in }
        guard hevcURL.lastPathComponent == "export 3.mp4",
              let hevcTrack = try await AVURLAsset(url: hevcURL).loadTracks(withMediaType: .video).first,
              let hevcDesc = try await hevcTrack.load(.formatDescriptions).first,
              CMFormatDescriptionGetMediaSubType(hevcDesc) == kCMVideoCodecType_HEVC else {
            throw SelfTestError.badExportName(hevcURL.lastPathComponent)
        }
        print("selftest: mp4/hevc export ok — \(hevcURL.lastPathComponent)")

        try checkCompare(meta: try recording.loadMeta(), width: width, height: height, duration: duration)

        try checkStaleChildren(meta: try recording.loadMeta())
        print("selftest: compare diff + stacked composer ok")

        try await checkAgentTools(recording: recording, meta: try recording.loadMeta(), duration: duration)
        print("selftest: agent tools ok — validation, annotated frames, preview render, briefing")

        // Optional online leg: exercise the real AI editor loop (spends a small
        // amount of the user's agent-CLI quota, so only on request).
        if ProcessInfo.processInfo.environment["CRISP_AI_SELFTEST"] == "1" {
            let providers = await AIDirector.detectProviders()
            let wanted = ProcessInfo.processInfo.environment["CRISP_AI_PROVIDER"]?.lowercased()
            guard let provider = providers.first(where: { $0.kind.rawValue.lowercased() == wanted })
                    ?? providers.first(where: { $0.kind == .claude }) ?? providers.first else {
                throw SelfTestError.noAIProvider
            }
            let model = ProcessInfo.processInfo.environment["CRISP_AI_MODEL"]
            let effort = ProcessInfo.processInfo.environment["CRISP_AI_EFFORT"]
            let tag = [model, effort].compactMap { $0 }.joined(separator: ", ")
            print("selftest: AI editor via \(provider.kind.rawValue)\(tag.isEmpty ? "" : " (\(tag))")… CLI default: \(provider.defaultModel?.id ?? "?") / \(provider.defaultEffort ?? "?"); models offered: \(provider.models.map { "\($0.id)[\($0.efforts.joined(separator: "/"))]" }.joined(separator: ", "))")
            let meta = try recording.loadMeta()
            let planner = ZoomPlanner(width: Double(width), height: Double(height))
            let auto = planner.segments(events: meta.events, duration: duration)
            let session = try AIDirector.Session(
                provider: provider, model: model, effort: effort,
                recording: recording, meta: meta, duration: duration
            )
            var restarted = false
            let report: (AIEvent) -> Void = { event in
                switch event {
                case .activity(.sessionRestarted, _):
                    restarted = true
                    print("selftest:   · started a new session")
                case .activity(let kind, let detail): print("selftest:   · \(kind) \(detail)")
                case .text(let t): print("selftest:   \(t.prefix(200))")
                }
            }
            let outcome = try await session.send(
                note: "test run — keep it minimal", segments: auto, onEvent: report
            )
            let polished = outcome.plan
            print("selftest: AI editor ok — \(auto.count) → \(polished.count) segments; adjustments: \(outcome.adjustments)")
            for seg in polished {
                print(String(format: "  zoom %.2f–%.2fs @%.1fx steps:%d", seg.start, seg.end, seg.zoom, seg.steps.count))
            }
            // Second turn must resume the same provider session and honor the note.
            print("selftest: AI follow-up turn…")
            let followUp = try await session.send(
                note: "drop every step and keep at most one zoom", segments: polished, onEvent: report
            ).plan
            let steps = followUp.reduce(0) { $0 + $1.steps.count }
            guard !restarted else { throw SelfTestError.aiResumeFailed }
            guard followUp.count <= 1, steps == 0 else { throw SelfTestError.aiIgnoredNote(segments: followUp.count, steps: steps) }
            print("selftest: AI follow-up ok — \(polished.count) → \(followUp.count) segments, steps: \(steps), resumed")
        }
    }

    /// The offline half of the AI editor: a plan with deliberate rule breaks must
    /// come back normalised with one message per break and its ids intact;
    /// the annotated stills, a preview through the real compositor and the
    /// workspace briefing must all be written.
    private static func checkAgentTools(recording: Recording, meta: RecordingMeta, duration: Double) async throws {
        let keepID = UUID()
        let stepID = UUID()
        let plan = """
        {"segments": [
          {"id": "\(keepID.uuidString)", "start": 0.20, "end": 1.20, "zoom": 3.8,
           "zoomIn": 1.50, "zoomOut": 0.05,
           "steps": [{"id": "\(stepID.uuidString)", "t": 0.60, "zoom": 5.0},
                     {"t": 0.10, "zoom": 2.0}, {"t": 1.15, "zoom": 2.0}]},
          {"start": 1.25, "end": 1.40, "zoom": 1.8, "steps": []},
          {"start": 1.30, "end": 5.00, "pins": [{"x": 9000, "y": 100}]}
        ]}
        """
        let parsed = try AgentPlan.parse(Data(plan.utf8), duration: duration, meta: meta)
        guard parsed.declared == 3 else { throw SelfTestError.agentTools("declared \(parsed.declared)") }
        guard parsed.segments.first?.id == keepID, parsed.segments.first?.steps.contains(where: { $0.id == stepID }) == true else {
            throw SelfTestError.agentTools("ids not preserved")
        }
        guard parsed.segments[0].zoom == 3.0, parsed.segments[0].steps.first(where: { $0.id == stepID })?.zoom == 3.0 else {
            throw SelfTestError.agentTools("zoom not clamped")
        }
        // The early step pulled to the hold start; the late one dropped.
        guard let first = parsed.segments.first, first.steps.count == 2,
              first.steps.contains(where: { $0.t == 0.2 }) else {
            throw SelfTestError.agentTools("steps not normalised: \(parsed.segments.first?.steps ?? [])")
        }
        // Too-short zoom dropped, overlapping zoom pushed after it, end clamped to the video.
        guard parsed.segments.count == 2, parsed.segments[1].start >= parsed.segments[0].end + 0.2,
              parsed.segments[1].end <= duration else {
            throw SelfTestError.agentTools("ordering not enforced: \(parsed.segments.map { ($0.start, $0.end) })")
        }
        guard parsed.segments.last?.pins.first?.point == CGPoint(x: Double(meta.pixelWidth), y: 100) else {
            throw SelfTestError.agentTools("pin not kept/clamped: \(String(describing: parsed.segments.last?.pins))")
        }
        guard parsed.segments.first?.zoomIn == 1.5, parsed.segments.first?.zoomOut == 0.1 else {
            throw SelfTestError.agentTools("ease lengths not kept/clamped: \(String(describing: parsed.segments.first?.zoomIn)) / \(String(describing: parsed.segments.first?.zoomOut))")
        }
        let expectedIssues = ["outside 1.2–3.0", "begins before the hold opens", "begins after the hold ends",
                              "shorter than 0.30s", "starts before the previous zoom", "is outside the video",
                              "pin (", "zoomOut"]
        for needle in expectedIssues where !parsed.issues.contains(where: { $0.contains(needle) }) {
            throw SelfTestError.agentTools("no issue mentioning '\(needle)' in \(parsed.issues)")
        }
        do {
            _ = try AgentPlan.parse(Data("{\"segments\": [{\"start\": 1}]}".utf8), duration: duration, meta: meta)
            throw SelfTestError.agentTools("malformed plan accepted")
        } catch AgentPlan.ParseError.invalid(let detail) {
            guard detail.contains("end") else { throw SelfTestError.agentTools("decode message unhelpful: \(detail)") }
        }

        let workspace = recording.folder.appendingPathComponent("agent-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try AgentTools.installWorkspace(in: workspace, recording: recording)
        for name in ["CLAUDE.md", "AGENTS.md", "crisp"] where !FileManager.default.isReadableFile(atPath: workspace.appendingPathComponent(name).path) {
            throw SelfTestError.agentTools("briefing file \(name) missing")
        }
        guard FileManager.default.isExecutableFile(atPath: workspace.appendingPathComponent("crisp").path) else {
            throw SelfTestError.agentTools("./crisp not executable")
        }
        // Run the wrapper for real: it re-enters this binary with the
        // recording's metacharacter-laden path, which must arrive intact.
        let crisp = Process()
        crisp.executableURL = workspace.appendingPathComponent("crisp")
        crisp.arguments = ["validate"]
        crisp.currentDirectoryURL = workspace
        let pipe = Pipe()
        crisp.standardOutput = pipe
        crisp.standardError = pipe
        try crisp.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        crisp.waitUntilExit()
        guard crisp.terminationStatus == 0, output.contains("OK —") else {
            throw SelfTestError.agentTools("./crisp validate failed (exit \(crisp.terminationStatus)): \(output.suffix(300))")
        }
        let frames = try await AgentTools.extractFrames(
            recording: recording, meta: meta, segments: parsed.segments, duration: duration, into: workspace
        )
        guard frames.count >= 2 else { throw SelfTestError.agentTools("only \(frames.count) frames") }
        for frame in frames {
            let size = (try? workspace.appendingPathComponent(frame.file).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size > 10_000 else { throw SelfTestError.agentTools("frame \(frame.file) is \(size) bytes") }
        }
        let previewURL = workspace.appendingPathComponent("preview.jpg")
        let camera = try await AgentTools.renderPreview(
            recording: recording, meta: meta, segments: parsed.segments, duration: duration,
            cursorStyle: .classic, at: 0.7, to: previewURL
        )
        guard camera.zoom > 1.5 else { throw SelfTestError.agentTools("preview camera not zoomed: \(camera.zoom)") }
        let previewSize = (try? previewURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard previewSize > 10_000 else { throw SelfTestError.agentTools("preview is \(previewSize) bytes") }
        let context = try AgentPlan.encodeContext(meta: meta, duration: duration, segments: parsed.segments, frames: frames)
        guard let obj = try JSONSerialization.jsonObject(with: context) as? [String: Any],
              obj["clickClusters"] != nil, obj["currentPlanTiming"] != nil, obj["cursorPath"] != nil else {
            throw SelfTestError.agentTools("context.json missing sections")
        }
    }

    /// A moving box over a slow diagonal gradient — the gradient is exactly the
    /// content that shows banding if the pipeline drops bit depth.
    private static func writeSyntheticMaster(
        to url: URL, width: Int, height: Int, duration: Double, fps: Double
    ) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings = CaptureEngine.videoSettings(codec: .hevc10, width: width, height: height, fps: fps)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? SelfTestError.writerFailed }
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(duration * fps)
        for i in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
            }
            guard let pool = adaptor.pixelBufferPool else { throw SelfTestError.writerFailed }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let pixelBuffer else { throw SelfTestError.writerFailed }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(pixelBuffer),
                width: width, height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            )!
            let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                colors: [
                    CGColor(srgbRed: 0.05, green: 0.05, blue: 0.25, alpha: 1),
                    CGColor(srgbRed: 0.10, green: 0.35, blue: 0.55, alpha: 1),
                ] as CFArray,
                locations: [0, 1]
            )!
            ctx.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: width, y: height),
                options: []
            )
            let u = Double(i) / Double(frameCount)
            ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.55, blue: 0.15, alpha: 1))
            ctx.fill(CGRect(x: 100 + u * 600, y: 300, width: 160, height: 120))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            let pts = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))
            guard adaptor.append(pixelBuffer, withPresentationTime: pts) else {
                throw writer.error ?? SelfTestError.writerFailed
            }
        }

        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if let error = writer.error { throw error }
    }

    private static func writeSyntheticEvents(
        to url: URL, width: Int, height: Int, duration: Double
    ) throws {
        // Two clicks: one early near the moving box, one later elsewhere.
        let events = [
            MouseEvent(t: 0.5, kind: .leftDown, x: 300, y: 380),
            MouseEvent(t: 0.6, kind: .leftUp, x: 300, y: 380),
            MouseEvent(t: 1.4, kind: .leftDown, x: 900, y: 200),
            MouseEvent(t: 1.5, kind: .leftUp, x: 900, y: 200),
        ]
        // Cursor drifts across the frame; a middle span is a pointer so export
        // actually draws the hand (smoke, not pixel-diff).
        let samples = stride(from: 0.0, through: duration, by: 1.0 / 60.0).map { t in
            CursorSample(
                t: t,
                x: 200 + (t / duration) * 800,
                y: 350 + (t / duration) * -140,
                kind: (t >= 0.6 && t < 1.2) ? .pointer : nil
            )
        }
        let meta = RecordingMeta(
            displayID: 1,
            pixelWidth: width,
            pixelHeight: height,
            scaleFactor: 2,
            fps: 60,
            codec: MasterCodec.hevc10.rawValue,
            startedAt: Date(),
            sessionStartHostSeconds: 0,
            events: events,
            samples: samples
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meta).write(to: url)
    }

    /// Decode-without-kind stays arrow; kind is held (not interpolated) across a gap.
    private static func checkCursorKind() throws {
        let decoded = try JSONDecoder().decode(
            CursorSample.self, from: Data(#"{"t":1,"x":10,"y":20}"#.utf8)
        )
        guard decoded.kind == nil else {
            throw SelfTestError.cursor("missing kind decoded as \(String(describing: decoded.kind))")
        }
        guard let fromMissing = FrameComposer.cursorPosition(samples: [decoded], at: 1),
              fromMissing.kind == .arrow else {
            throw SelfTestError.cursor("missing kind did not resolve to arrow")
        }

        let arrowJSON = try JSONEncoder().encode(CursorSample(t: 1, x: 2, y: 3))
        let arrowObj = try JSONSerialization.jsonObject(with: arrowJSON) as? [String: Any]
        guard arrowObj?["kind"] == nil else {
            throw SelfTestError.cursor("arrow sample encoded a kind field")
        }

        let samples = [
            CursorSample(t: 0, x: 0, y: 0, kind: .pointer),
            CursorSample(t: 1, x: 100, y: 0),
        ]
        guard let mid = FrameComposer.cursorPosition(samples: samples, at: 0.4),
              mid.kind == .pointer, abs(mid.x - 40) < 0.01 else {
            throw SelfTestError.cursor("kind not held across interpolated gap (got \(String(describing: FrameComposer.cursorPosition(samples: samples, at: 0.4))))")
        }
        guard let after = FrameComposer.cursorPosition(samples: samples, at: 1),
              after.kind == .arrow else {
            throw SelfTestError.cursor("kind at last sample was not arrow")
        }
    }

    /// Plans without a cursor style decode as classic and encode without the
    /// key; every style draws all three cursor kinds.
    private static func checkCursorStyle() throws {
        let legacy = try JSONDecoder().decode(ZoomPlan.self, from: Data(#"{"version":1,"segments":[]}"#.utf8))
        guard legacy.cursorStyle == nil else {
            throw SelfTestError.cursor("legacy plan decoded a cursor style")
        }
        let classic = try JSONEncoder().encode(ZoomPlan(segments: []))
        let classicObj = try JSONSerialization.jsonObject(with: classic) as? [String: Any]
        guard classicObj?["cursorStyle"] == nil else {
            throw SelfTestError.cursor("classic plan encoded a cursorStyle field")
        }
        let bubbly = try JSONEncoder().encode(ZoomPlan(segments: [], cursorStyle: .bubbly))
        guard try JSONDecoder().decode(ZoomPlan.self, from: bubbly).cursorStyle == .bubbly else {
            throw SelfTestError.cursor("bubbly cursor style did not round-trip")
        }
        for style in CursorStyle.allCases {
            let kinds = FrameComposer.cursorKinds(drawnBy: style)
            guard kinds == Set([.arrow, .pointer, .iBeam]) else {
                throw SelfTestError.cursor("\(style) draws \(kinds), not every cursor kind")
            }
        }
    }

    /// A step or pin left past a hold's end (the zoom was shortened under
    /// it) must not leak into the camera: the hold keeps its own level and
    /// the zoom-out is framed as if the pin weren't there.
    private static func checkStaleChildren(meta: RecordingMeta) throws {
        let planner = ZoomPlanner(meta: meta)
        let duration = 3.0
        let clean = ZoomSegment(start: 0.4, end: 1.0, zoom: 1.5)
        var stale = clean
        stale.steps = [ZoomStep(t: 1.5, zoom: 3.0)]
        stale.pins = [PinWindow(x: 100, y: 100, from: 1.5)]
        guard planner.holdSteps(for: stale, duration: duration).isEmpty,
              planner.pinWindows(for: stale, duration: duration).isEmpty else {
            throw SelfTestError.compare("a step or pin past the hold end still has a window")
        }
        let staleKeys = planner.keyframes(from: [stale], duration: duration)
        let cleanKeys = planner.keyframes(from: [clean], duration: duration)
        for t in stride(from: 0.0, through: duration, by: 0.1) {
            let a = ZoomPlanner.evaluate(staleKeys, at: t)
            let b = ZoomPlanner.evaluate(cleanKeys, at: t)
            guard abs(a.zoom - b.zoom) < 1e-6, abs(a.center.x - b.center.x) < 0.5, abs(a.center.y - b.center.y) < 0.5 else {
                throw SelfTestError.compare(String(format: "stale step/pin changed the camera at %.1fs: %.2f× (%.0f, %.0f) vs %.2f× (%.0f, %.0f)", t, a.zoom, a.center.x, a.center.y, b.zoom, b.center.x, b.center.y))
            }
        }
    }

    /// The editor's compare mode: plan diffing (by id and, for AI replies, by
    /// overlap) and the stacked before/after composer.
    private static func checkCompare(meta: RecordingMeta, width: Int, height: Int, duration: Double) throws {
        let planner = ZoomPlanner(width: Double(width), height: Double(height))
        func diff(_ before: [ZoomSegment], _ after: [ZoomSegment]) -> PlanDiff {
            PlanDiff(before: before, after: after, planner: planner, duration: duration)
        }
        let a = ZoomSegment(start: 0.4, end: 1.4, zoom: 2.2, steps: [ZoomStep(t: 0.8, zoom: 2.6)])
        guard diff([a], [a]).isEmpty else { throw SelfTestError.compare("identical plans differ") }

        var moved = a
        moved.zoom = 1.6
        let byID = diff([a], [moved])
        guard byID.changed == [a.id], byID.removed.isEmpty, byID.ranges.count == 1 else {
            throw SelfTestError.compare("hand edit not detected")
        }
        let span = planner.motionSpan(for: a, duration: duration)
        guard byID.ranges[0] == PlanDiff.Range(start: span.moveStart, end: span.outEnd) else {
            throw SelfTestError.compare("range \(byID.ranges[0]) != motion span")
        }
        // Custom ease lengths stretch the ramps without moving the hold.
        let mid = ZoomSegment(start: 4.0, end: 6.0, zoom: 1.8)
        let base = planner.motionSpan(for: mid, duration: 10)
        var slow = mid
        slow.zoomIn = 1.4
        slow.zoomOut = 1.6
        let stretched = planner.motionSpan(for: slow, duration: 10)
        guard abs(stretched.arrive - base.arrive) < 0.001, abs(stretched.end - base.end) < 0.001 else {
            throw SelfTestError.compare("custom ease moved the hold (\(stretched.arrive) / \(stretched.end))")
        }
        guard stretched.moveStart < base.moveStart - 0.5, stretched.outEnd > base.outEnd + 0.5 else {
            throw SelfTestError.compare("custom ease did not stretch ramps: \(stretched) vs \(base)")
        }
        let defaults = planner.motionSpan(
            for: ZoomSegment(start: 4.0, end: 6.0, zoom: 1.8), duration: 10
        )
        guard defaults.moveStart == base.moveStart, defaults.outEnd == base.outEnd else {
            throw SelfTestError.compare("nil ease lengths changed default motion span")
        }

        // AI replies come back with fresh ids and two-decimal rounding.
        var rounded = a
        rounded.id = UUID()
        rounded.zoom = 2.204
        guard diff([a], [rounded]).isEmpty else { throw SelfTestError.compare("re-id'd plan reported as changed") }
        var longer = rounded
        longer.end = 1.7
        let byOverlap = diff([a], [longer])
        guard byOverlap.changed == [longer.id], byOverlap.removed.isEmpty else {
            throw SelfTestError.compare("AI edit not paired by overlap")
        }
        let dropped = diff([a], [])
        guard dropped.changed.isEmpty, dropped.removed.map(\.id) == [a.id], dropped.ranges.count == 1 else {
            throw SelfTestError.compare("removed zoom not reported")
        }

        let composer = CompareComposer(
            meta: meta,
            before: planner.keyframes(from: [a], duration: duration),
            after: planner.keyframes(from: [moved], duration: duration),
            cursorStyle: .bubbly
        )
        let source = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let stacked = composer.compose(source: source, at: 1.0)
        let expected = CGRect(x: 0, y: 0, width: Double(width), height: Double(height) * 2 + CompareComposer.gap)
        guard stacked.extent == expected else {
            throw SelfTestError.compare("stacked extent \(stacked.extent) != \(expected)")
        }
    }

    enum SelfTestError: Error {
        case cursor(String)
        case compare(String)
        case writerFailed
        case noTrack
        case badDuration(Double)
        case badSize(CGSize)
        case badExportName(String)
        case noAIProvider
        case aiResumeFailed
        case aiIgnoredNote(segments: Int, steps: Int)
        case agentTools(String)
    }
}
