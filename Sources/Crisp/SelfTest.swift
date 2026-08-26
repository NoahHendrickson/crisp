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
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("crisp-selftest-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
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
            ZoomSegment(
                start: 0.4, end: 1.4, zoom: 2.2, cx: 300, cy: 380,
                pans: [PanMove(t: 0.8, duration: 0.4, cx: 900, cy: 300)]
            )
        ])
        // Re-exporting (as MP4/H.264) must not overwrite the first export: it
        // should land in a numbered sibling file.
        let planURL = try await Renderer().export(recording: recording, format: .mp4H264) { _ in }
        guard planURL.lastPathComponent == "export 2.mp4",
              FileManager.default.fileExists(atPath: exportURL.path),
              recording.exportURLs == [exportURL, planURL] else {
            throw SelfTestError.badExportName(planURL.lastPathComponent)
        }
        // Each export carries a snapshot of the plan that produced it.
        guard Recording.loadPlanSegments(from: Recording.planSnapshotURL(for: planURL))?.count == 1,
              recording.files.map(\.title) == ["Original", "Export", "Export 2"],
              recording.files.last?.zoomCount == 1 else {
            throw SelfTestError.badExportName("missing plan snapshot for \(planURL.lastPathComponent)")
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
        print("selftest: compare diff + stacked composer ok")

        // Optional online leg: exercise the real AI-polish loop (spends a small
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
            print("selftest: AI polish via \(provider.kind.rawValue)\(tag.isEmpty ? "" : " (\(tag))")… CLI default: \(provider.defaultModel?.id ?? "?") / \(provider.defaultEffort ?? "?"); models offered: \(provider.models.map { "\($0.id)[\($0.efforts.joined(separator: "/"))]" }.joined(separator: ", "))")
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
            let polished = try await session.send(
                note: "test run — keep it minimal", segments: auto, onEvent: report
            )
            print("selftest: AI polish ok — \(auto.count) → \(polished.count) segments")
            for seg in polished {
                print(String(format: "  zoom %.2f–%.2fs @%.1fx center(%.0f,%.0f) pans:%d",
                             seg.start, seg.end, seg.zoom, seg.cx, seg.cy, seg.pans.count))
            }
            // Second turn must resume the same provider session and honor the note.
            print("selftest: AI follow-up turn…")
            let followUp = try await session.send(
                note: "drop every pan and keep at most one zoom", segments: polished, onEvent: report
            )
            let pans = followUp.reduce(0) { $0 + $1.pans.count }
            guard !restarted else { throw SelfTestError.aiResumeFailed }
            guard followUp.count <= 1, pans == 0 else { throw SelfTestError.aiIgnoredNote(segments: followUp.count, pans: pans) }
            print("selftest: AI follow-up ok — \(polished.count) → \(followUp.count) segments, pans: \(pans), resumed")
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
        // Cursor drifts across the frame.
        let samples = stride(from: 0.0, through: duration, by: 1.0 / 60.0).map { t in
            CursorSample(
                t: t,
                x: 200 + (t / duration) * 800,
                y: 350 + (t / duration) * -140
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

    /// The editor's compare mode: plan diffing (by id and, for AI replies, by
    /// overlap) and the stacked before/after composer.
    private static func checkCompare(meta: RecordingMeta, width: Int, height: Int, duration: Double) throws {
        let planner = ZoomPlanner(width: Double(width), height: Double(height))
        func diff(_ before: [ZoomSegment], _ after: [ZoomSegment]) -> PlanDiff {
            PlanDiff(before: before, after: after, planner: planner, duration: duration)
        }
        let a = ZoomSegment(start: 0.4, end: 1.4, zoom: 2.2, cx: 300, cy: 380,
                            pans: [PanMove(t: 0.8, duration: 0.4, cx: 900, cy: 300)])
        guard diff([a], [a]).isEmpty else { throw SelfTestError.compare("identical plans differ") }

        var moved = a
        moved.cx = 600
        let byID = diff([a], [moved])
        guard byID.changed == [a.id], byID.removed.isEmpty, byID.ranges.count == 1 else {
            throw SelfTestError.compare("hand edit not detected")
        }
        let span = planner.motionSpan(for: a, duration: duration)
        guard byID.ranges[0] == PlanDiff.Range(start: span.moveStart, end: span.outEnd) else {
            throw SelfTestError.compare("range \(byID.ranges[0]) != motion span")
        }

        // AI replies come back with fresh ids and two-decimal rounding.
        var rounded = a
        rounded.id = UUID()
        rounded.cx = 300.004
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
            after: planner.keyframes(from: [moved], duration: duration)
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
        case compare(String)
        case writerFailed
        case noTrack
        case badDuration(Double)
        case badSize(CGSize)
        case badExportName(String)
        case noAIProvider
        case aiResumeFailed
        case aiIgnoredNote(segments: Int, pans: Int)
    }
}
