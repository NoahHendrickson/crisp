import SwiftUI
import AVFoundation
import AppKit

// The editor's inspector: slider panels for the selected zoom or pan, and
// the actions that add pans / zoom-in steps inside a zoom.
extension EditorView {
    // MARK: - Inspector

    var selectedSegmentIndex: Int? {
        switch selection {
        case .segment(let id), .pan(segment: let id, pan: _):
            return segments.firstIndex { $0.id == id }
        case nil:
            return nil
        }
    }

    @ViewBuilder
    var inspector: some View {
        if case .pan(let segID, let panID) = selection,
           let segIndex = segments.firstIndex(where: { $0.id == segID }),
           let panIndex = segments[segIndex].pans.firstIndex(where: { $0.id == panID }),
           let meta {
            panInspector(segIndex: segIndex, panIndex: panIndex, meta: meta)
        } else if let index = selectedSegmentIndex, let meta {
            let seg = segments[index]
            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Start")
                        ThemedSlider(
                            value: Binding(
                                get: { segments[index].start },
                                set: { segments[index].start = min($0, segments[index].end - 0.2) }
                            ),
                            in: 0...duration
                        )
                        Text(timecode(seg.start))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    GridRow {
                        Text("End")
                        ThemedSlider(
                            value: Binding(
                                get: { segments[index].end },
                                set: { segments[index].end = max($0, segments[index].start + 0.2) }
                            ),
                            in: 0...duration
                        )
                        Text(timecode(seg.end))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    GridRow {
                        Text("Zoom")
                        ThemedSlider(
                            value: Binding(
                                get: { segments[index].zoom },
                                set: { segments[index].zoom = $0 }
                            ),
                            in: Self.zoomRange
                        )
                        Text(String(format: "%.1f×", seg.zoom))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    GridRow {
                        Text("Center X")
                        ThemedSlider(
                            value: Binding(
                                get: { segments[index].cx },
                                set: { segments[index].cx = $0 }
                            ),
                            in: 0...Double(meta.pixelWidth)
                        )
                        Text("\(Int(seg.cx))px")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    GridRow {
                        Text("Center Y")
                        ThemedSlider(
                            value: Binding(
                                get: { segments[index].cy },
                                set: { segments[index].cy = $0 }
                            ),
                            in: 0...Double(meta.pixelHeight)
                        )
                        Text("\(Int(seg.cy))px")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                HStack {
                    Button("Preview This Zoom") {
                        startLivePreview(from: max(0, seg.start - 1.2))
                    }
                    .buttonStyle(.themed(.outline, size: .xs))
                    .tooltip("Play this zoom with the real camera, starting just before it")
                    Button("Add Pan at Playhead") {
                        addPanAtPlayhead(segIndex: index)
                    }
                    .buttonStyle(.themed(.outline, size: .xs))
                    .tooltip("Insert a camera pan inside this zoom at the current playhead")
                    Button("Zoom In Further at Playhead") {
                        addZoomStepAtPlayhead(segIndex: index)
                    }
                    .buttonStyle(.themed(.outline, size: .xs))
                    .tooltip("Tighten the zoom from the playhead on, without zooming back out first")
                    Spacer()
                    Button("Remove Zoom", role: .destructive) {
                        segments.remove(at: index)
                        select(nil)
                    }
                    .buttonStyle(.themed(.destructive, size: .xs))
                    .tooltip("Delete this zoom and its pans")
                }
                .padding(.top, 4)
            } label: {
                Text("Selected Zoom")
                    .font(.callout.weight(.medium))
            }
        }
    }

    func panInspector(segIndex: Int, panIndex: Int, meta: RecordingMeta) -> some View {
        let seg = segments[segIndex]
        let pan = seg.pans[panIndex]
        return GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Starts at")
                    ThemedSlider(
                        value: Binding(
                            get: { segments[segIndex].pans[panIndex].t },
                            set: { segments[segIndex].pans[panIndex].t = $0 }
                        ),
                        in: seg.start...max(seg.start + 0.1, seg.end - 0.1)
                    )
                    Text(timecode(pan.t))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
                GridRow {
                    Text("Travel time")
                    ThemedSlider(
                        value: Binding(
                            get: { segments[segIndex].pans[panIndex].duration },
                            set: { segments[segIndex].pans[panIndex].duration = $0 }
                        ),
                        in: 0.15...1.5
                    )
                    Text(String(format: "%.2fs", pan.duration))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
                GridRow {
                    Text("Zoom")
                    ThemedSlider(
                        value: panZoomBinding(segIndex: segIndex, panIndex: panIndex),
                        in: Self.zoomRange
                    )
                    Text(String(format: "%.1f×", zoomLevel(in: seg, after: pan)))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
                GridRow {
                    Text("Pan to X")
                    ThemedSlider(
                        value: Binding(
                            get: { segments[segIndex].pans[panIndex].cx },
                            set: { segments[segIndex].pans[panIndex].cx = $0 }
                        ),
                        in: 0...Double(meta.pixelWidth)
                    )
                    Text("\(Int(pan.cx))px")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
                GridRow {
                    Text("Pan to Y")
                    ThemedSlider(
                        value: Binding(
                            get: { segments[segIndex].pans[panIndex].cy },
                            set: { segments[segIndex].pans[panIndex].cy = $0 }
                        ),
                        in: 0...Double(meta.pixelHeight)
                    )
                    Text("\(Int(pan.cy))px")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
            }
            HStack {
                Button("Preview This Pan") {
                    startLivePreview(from: max(0, pan.t - 1.0))
                }
                .buttonStyle(.themed(.outline, size: .xs))
                .tooltip("Play this pan with the real camera, starting just before it")
                Spacer()
                Button("Remove Pan", role: .destructive) {
                    segments[segIndex].pans.remove(at: panIndex)
                    select(.segment(seg.id))
                }
                .buttonStyle(.themed(.destructive, size: .xs))
                .tooltip("Delete this pan; the zoom stays")
            }
            .padding(.top, 4)
        } label: {
            Text("Selected \(pan.zoom == nil ? "Pan" : "Zoom-in") (in zoom \(timecode(seg.start))–\(timecode(seg.end)))")
                .font(.callout.weight(.medium))
        }
    }

    /// Switch to the preview tab (real camera) and play from `t`.
    func startLivePreview(from t: Double) {
        viewMode = .preview
        seek(to: t)
        player.play()
    }

    func addPanAtPlayhead(segIndex: Int) {
        guard let meta else { return }
        let seg = segments[segIndex]
        let t = min(max(currentTime, seg.start), max(seg.start, seg.end - 0.2))
        // Aim at wherever the cursor was shortly after the pan begins.
        let p = FrameComposer.cursorPosition(samples: meta.samples, at: t + 0.4)
        let pan = PanMove(
            t: t, duration: 0.5,
            cx: p?.x ?? Double(meta.pixelWidth) / 2,
            cy: p?.y ?? Double(meta.pixelHeight) / 2
        )
        segments[segIndex].pans.append(pan)
        select(.pan(segment: seg.id, pan: pan.id))
    }

    /// A pan at the playhead that also steps the zoom up half a level
    /// (capped at the range), aimed at the cursor like a plain pan.
    func addZoomStepAtPlayhead(segIndex: Int) {
        guard let meta else { return }
        let seg = segments[segIndex]
        let t = min(max(currentTime, seg.start), max(seg.start, seg.end - 0.2))
        let level = min(zoomLevel(in: seg, at: t) + 0.5, Self.zoomRange.upperBound)
        let p = FrameComposer.cursorPosition(samples: meta.samples, at: t + 0.4)
        let pan = PanMove(
            t: t, duration: 0.5,
            cx: p?.x ?? seg.cx,
            cy: p?.y ?? seg.cy,
            zoom: level
        )
        segments[segIndex].pans.append(pan)
        select(.pan(segment: seg.id, pan: pan.id))
    }
}
