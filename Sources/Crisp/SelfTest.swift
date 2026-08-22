import Foundation
import AVFoundation
import CoreGraphics

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
        try await renderer.export(recording: recording) { fraction in
            print(String(format: "selftest: export %3.0f%%", fraction * 100))
        }

        // Verify the export.
        let asset = AVURLAsset(url: recording.exportURL)
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
        let bytes = try FileManager.default.attributesOfItem(atPath: recording.exportURL.path)[.size] as? Int ?? 0
        print("selftest: export ok — \(Int(size.width))×\(Int(size.height)), \(String(format: "%.2f", exportedDuration))s, \(bytes / 1024) KB")

        // Second pass: export again through an edited plan.json (the editor path).
        recording.savePlan([
            ZoomSegment(
                start: 0.4, end: 1.4, zoom: 2.2, cx: 300, cy: 380,
                pans: [PanMove(t: 0.8, duration: 0.4, cx: 900, cy: 300)]
            )
        ])
        try await Renderer().export(recording: recording) { _ in }
        let planAsset = AVURLAsset(url: recording.exportURL)
        let planDuration = try await planAsset.load(.duration).seconds
        guard abs(planDuration - duration) < 0.25 else {
            throw SelfTestError.badDuration(planDuration)
        }
        print("selftest: edited-plan export ok — \(String(format: "%.2f", planDuration))s")

        // Optional online leg: exercise the real AI-polish loop (spends a small
        // amount of the user's agent-CLI quota, so only on request).
        if ProcessInfo.processInfo.environment["CRISP_AI_SELFTEST"] == "1" {
            let providers = await AIDirector.detectProviders()
            let wanted = ProcessInfo.processInfo.environment["CRISP_AI_PROVIDER"]?.lowercased()
            guard let provider = providers.first(where: { $0.kind.rawValue.lowercased() == wanted })
                    ?? providers.first(where: { $0.kind == .claude }) ?? providers.first else {
                throw SelfTestError.noAIProvider
            }
            print("selftest: AI polish via \(provider.kind.rawValue)…")
            let meta = try recording.loadMeta()
            let planner = ZoomPlanner(width: Double(width), height: Double(height))
            let auto = planner.segments(events: meta.events, duration: duration)
            let session = try AIDirector.Session(
                provider: provider, recording: recording, meta: meta, duration: duration
            )
            let polished = try await session.send(
                note: "test run — keep it minimal", segments: auto
            ) { event in
                switch event {
                case .activity(let a): print("selftest:   · \(a)")
                case .text(let t): print("selftest:   \(t.prefix(200))")
                }
            }
            print("selftest: AI polish ok — \(auto.count) → \(polished.count) segments")
            for seg in polished {
                print(String(format: "  zoom %.2f–%.2fs @%.1fx center(%.0f,%.0f) pans:%d",
                             seg.start, seg.end, seg.zoom, seg.cx, seg.cy, seg.pans.count))
            }
            // Second turn resumes the same provider session.
            print("selftest: AI follow-up turn…")
            let followUp = try await session.send(
                note: "drop every pan and keep at most one zoom", segments: polished
            ) { event in
                switch event {
                case .activity(let a): print("selftest:   · \(a)")
                case .text(let t): print("selftest:   \(t.prefix(200))")
                }
            }
            print("selftest: AI follow-up ok — \(polished.count) → \(followUp.count) segments, pans: \(followUp.reduce(0) { $0 + $1.pans.count })")
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

    enum SelfTestError: Error {
        case writerFailed
        case noTrack
        case badDuration(Double)
        case badSize(CGSize)
        case noAIProvider
    }
}
