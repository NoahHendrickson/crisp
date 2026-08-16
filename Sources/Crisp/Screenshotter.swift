import Foundation
import ScreenCaptureKit
import CoreImage
import CoreMedia

/// High-bit-depth screenshots. macOS's native screenshots are 8-bit, which is
/// exactly where smooth gradients band; these capture at 10 bits via
/// ScreenCaptureKit and save as 16-bit PNG or 10-bit HEIC in Display P3.
enum ScreenshotFormat: String, CaseIterable, Identifiable {
    case png16 = "PNG (16-bit)"
    case heic10 = "HEIC (10-bit)"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .png16: return "png"
        case .heic10: return "heic"
        }
    }
}

enum Screenshotter {

    static func libraryFolder() -> URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        return pictures.appendingPathComponent("Crisp", isDirectory: true)
    }

    /// Capture the source and write it to ~/Pictures/Crisp. `ownWindows` (this
    /// app's windows) are excluded from display/region captures so Crisp
    /// doesn't appear in its own screenshots.
    static func capture(
        source: CaptureSource,
        format: ScreenshotFormat,
        excluding ownWindows: [SCWindow]
    ) async throws -> URL {
        let filter: SCContentFilter
        let config = SCStreamConfiguration()
        let sizePoints: CGSize

        switch source {
        case .display(let display):
            filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            sizePoints = filter.contentRect.size
        case .region(let display, let rect):
            filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            config.sourceRect = rect
            sizePoints = rect.size
        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
            sizePoints = window.frame.size
        }

        let scale = Double(filter.pointPixelScale)
        config.width = max(1, Int(sizePoints.width * scale))
        config.height = max(1, Int(sizePoints.height * scale))
        // The whole point: 10-bit capture, wide gamut, no cursor.
        config.pixelFormat = kCVPixelFormatType_ARGB2101010LEPacked
        config.colorSpaceName = CGColorSpace.displayP3
        config.showsCursor = false

        let sample = try await SCScreenshotManager.captureSampleBuffer(
            contentFilter: filter, configuration: config
        )
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
            throw ScreenshotError.noImage
        }
        let image = CIImage(cvPixelBuffer: pixelBuffer)

        let folder = libraryFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = folder.appendingPathComponent(
            "Crisp \(fmt.string(from: Date())).\(format.fileExtension)"
        )

        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = CIContext(options: [
            .workingFormat: CIFormat.RGBAh,
            .workingColorSpace: p3,
        ])
        switch format {
        case .png16:
            try context.writePNGRepresentation(of: image, to: url, format: .RGBA16, colorSpace: p3)
        case .heic10:
            try context.writeHEIF10Representation(of: image, to: url, colorSpace: p3, options: [:])
        }
        return url
    }

    enum ScreenshotError: LocalizedError {
        case noImage
        var errorDescription: String? { "The screenshot capture returned no image." }
    }
}
