import SwiftUI

/// Editable crop rectangle drawn over the full-frame preview: shows where a
/// selected zoom (or pan) will land. Drag the box to re-center, drag a corner
/// to change the zoom level. Coordinates are master-video pixels; the view
/// maps them into the letterboxed video rect of the player.
struct ZoomFrameOverlay: View {
    let pixelWidth: Double
    let pixelHeight: Double
    let zoomRange: ClosedRange<Double>
    /// The zoom level is shared between a segment and its pans, so pans edit
    /// the center only.
    let zoomEditable: Bool
    /// False when the box only mirrors the camera at the playhead (e.g. the
    /// playhead is outside the selected zoom): no drag, no corner handles.
    var editable: Bool = true
    @Binding var cx: Double
    @Binding var cy: Double
    @Binding var zoom: Double

    @State private var dragStart: (cx: Double, cy: Double)?
    @State private var resizeStartZoom: Double?

    private let handleSize: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let video = videoRect(in: geo.size)
            let scale = video.width / pixelWidth
            let box = cropRect(video: video, scale: scale)

            ZStack(alignment: .topLeading) {
                // Dim everything outside the crop.
                Path { p in
                    p.addRect(video)
                    p.addRoundedRect(in: box, cornerSize: CGSize(width: 4, height: 4))
                }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: 4)
                    .stroke(Theme.primary, lineWidth: 2)
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
                    .allowsHitTesting(false)

                Text(String(format: "%.1f×", zoom))
                    .font(Theme.font(.label12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.primary, in: RoundedRectangle(cornerRadius: 4))
                    .offset(x: box.minX + 6, y: box.minY + 6)
                    .allowsHitTesting(false)

                // Move: drag anywhere inside the box.
                if editable {
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .frame(width: box.width, height: box.height)
                        .offset(x: box.minX, y: box.minY)
                        .gesture(moveGesture(scale: scale))
                }

                if editable && zoomEditable {
                    ForEach(Corner.allCases, id: \.self) { corner in
                        Circle()
                            .fill(Color.white)
                            .overlay(Circle().stroke(Theme.primary, lineWidth: 2))
                            .frame(width: handleSize, height: handleSize)
                            .contentShape(Circle().scale(2.5))
                            .offset(
                                x: corner.point(in: box).x - handleSize / 2,
                                y: corner.point(in: box).y - handleSize / 2
                            )
                            .gesture(resizeGesture(corner: corner, video: video, scale: scale))
                    }
                }
            }
        }
    }

    // MARK: - Geometry

    /// The player uses `.resizeAspect`, so the video sits letterboxed in the view.
    private func videoRect(in size: CGSize) -> CGRect {
        guard pixelWidth > 0, pixelHeight > 0, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(size.width / pixelWidth, size.height / pixelHeight)
        let w = pixelWidth * scale
        let h = pixelHeight * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func cropRect(video: CGRect, scale: CGFloat) -> CGRect {
        let c = clampedCenter(cx: cx, cy: cy, zoom: zoom)
        let w = pixelWidth / zoom * scale
        let h = pixelHeight / zoom * scale
        return CGRect(
            x: video.minX + c.x * scale - w / 2,
            y: video.minY + c.y * scale - h / 2,
            width: w, height: h
        )
    }

    /// Mirrors ZoomPlanner.clampedCenter so the box never leaves the frame.
    private func clampedCenter(cx: Double, cy: Double, zoom: Double) -> CGPoint {
        let halfW = pixelWidth / zoom / 2
        let halfH = pixelHeight / zoom / 2
        return CGPoint(
            x: min(max(cx, halfW), pixelWidth - halfW),
            y: min(max(cy, halfH), pixelHeight - halfH)
        )
    }

    // MARK: - Gestures

    private func moveGesture(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStart == nil {
                    let c = clampedCenter(cx: cx, cy: cy, zoom: zoom)
                    dragStart = (Double(c.x), Double(c.y))
                }
                guard let start = dragStart else { return }
                let c = clampedCenter(
                    cx: start.cx + value.translation.width / scale,
                    cy: start.cy + value.translation.height / scale,
                    zoom: zoom
                )
                cx = c.x
                cy = c.y
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Dragging a corner scales the box about its center; the box's aspect
    /// ratio is fixed by the video, so only the zoom level changes.
    private func resizeGesture(corner: Corner, video: CGRect, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if resizeStartZoom == nil { resizeStartZoom = zoom }
                let c = clampedCenter(cx: cx, cy: cy, zoom: resizeStartZoom ?? zoom)
                let centerView = CGPoint(x: video.minX + c.x * scale, y: video.minY + c.y * scale)
                // Pointer distance from the center along x and y → candidate half sizes.
                let halfW = abs(value.location.x - centerView.x)
                let halfH = abs(value.location.y - centerView.y)
                let zoomFromW = video.width / max(2 * halfW, 1)
                let zoomFromH = video.height / max(2 * halfH, 1)
                // Honor whichever axis the pointer has pulled furthest.
                let proposed = min(zoomFromW, zoomFromH)
                zoom = min(max(proposed, zoomRange.lowerBound), zoomRange.upperBound)
                let clamped = clampedCenter(cx: c.x, cy: c.y, zoom: zoom)
                cx = clamped.x
                cy = clamped.y
            }
            .onEnded { _ in resizeStartZoom = nil }
    }

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        func point(in r: CGRect) -> CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: r.minX, y: r.minY)
            case .topRight: return CGPoint(x: r.maxX, y: r.minY)
            case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
            case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
            }
        }
    }
}
