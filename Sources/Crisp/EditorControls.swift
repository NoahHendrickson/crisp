import SwiftUI
import AVFoundation
import AppKit

// The editor's controls row: preview / crop-box tabs, New zoom / New pan,
// the "Start from" plan source, AI Polish, Compare and Export.
extension EditorView {
    // MARK: - Plan source ("Start from")

    /// Current plan, each export that carries a plan snapshot, then Auto.
    var planSourceItems: [DropdownItem] {
        let exports = recording.files.filter { !$0.isMaster }
        let checked = checkedPlanSource(exports: exports)
        var items = [
            DropdownItem(id: "current", label: "Current plan", checked: checked == .current,
                         detail: "\(zoomsLabel(segments.count)) · what Export with Zooms will render") {
                loadPlan(recording.loadPlanSegments() ?? autoSegments(), source: .current)
            },
        ]
        for file in exports.reversed() {
            guard let snapshot = file.planSnapshotURL,
                  let plan = Recording.loadPlanSegments(from: snapshot) else { continue }
            var detail = zoomsLabel(plan.count)
            if let date = file.modifiedAt {
                detail += " · \(date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"
            }
            items.append(DropdownItem(id: file.url.path, label: "\(file.title) (\(file.format))",
                                      checked: checked.exportURL == file.url, detail: detail) {
                loadPlan(plan, source: .export(file.url, loaded: plan))
            })
        }
        items.append(DropdownItem(id: "auto", label: "Auto (from clicks)", checked: checked.isAuto,
                                  detail: "Regenerate zooms from the click log") {
            try? FileManager.default.removeItem(at: recording.planURL)
            let auto = autoSegments()
            loadPlan(auto, source: .auto(loaded: auto))
        })
        return items
    }

    /// The last-picked source keeps its check only while the plan still
    /// matches what it loaded (and, for an export, while that export still
    /// exists); otherwise the working plan is simply "Current plan".
    func checkedPlanSource(exports: [RecordingFile]) -> PlanSource {
        switch planSource {
        case .current:
            return .current
        case .auto(let loaded):
            return loaded == segments ? planSource : .current
        case .export(let url, let loaded):
            return loaded == segments && exports.contains { $0.url == url } ? planSource : .current
        }
    }

    /// Swaps the plan in, keeping the previous one as the Compare baseline.
    func loadPlan(_ plan: [ZoomSegment], source: PlanSource) {
        compareBaseline = segments
        compareTarget = nil
        segments = plan
        planSource = source
        select(nil)
    }

    func zoomsLabel(_ n: Int) -> String {
        n == 1 ? "1 zoom" : "\(n) zooms"
    }

    func planner() -> ZoomPlanner {
        guard let meta else { return ZoomPlanner(width: 1, height: 1) }
        return ZoomPlanner(width: Double(meta.pixelWidth), height: Double(meta.pixelHeight))
    }

    func autoSegments() -> [ZoomSegment] {
        guard let meta else { return [] }
        return planner().segments(events: meta.events, duration: duration)
    }

    func makeComposition() -> AVMutableVideoComposition? {
        guard let meta else { return nil }
        let clipDuration = CMTime(seconds: max(duration, 0.1), preferredTimescale: 600)
        if comparing, let compareBaseline {
            let composer = CompareComposer(
                meta: meta,
                before: planner().keyframes(from: compareBaseline, duration: duration),
                after: planner().keyframes(from: compareTarget ?? segments, duration: duration)
            )
            return CameraCompositor.makeComposition(duration: clipDuration, composer: composer)
        }
        // In the crop-box view the camera stays at full frame so the box is
        // always visible; cursor and ripples still render.
        let full = Camera(
            zoom: 1,
            center: CGPoint(x: Double(meta.pixelWidth) / 2, y: Double(meta.pixelHeight) / 2)
        )
        let keys = viewMode == .box
            ? [ZoomPlanner.Keyframe(t: 0, camera: full)]
            : planner().keyframes(from: segments, duration: duration)
        let composer = FrameComposer(meta: meta, keys: keys)
        return CameraCompositor.makeComposition(duration: clipDuration, composer: composer)
    }

    // MARK: - Controls

    var isPlaying: Bool {
        player.timeControlStatus == .playing
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            if duration - currentTime < 0.05 { seek(to: 0) }
            player.play()
        }
    }

    /// Row between the preview and the timeline (Figma 76:13710): the
    /// preview / crop-box tabs, plan actions, then compare and export.
    var controls: some View {
        HStack(spacing: 8) {
            IconTabsPicker(
                items: Array(ViewMode.allCases),
                selection: $viewMode,
                icon: { $0 == .preview ? "image-duotone" : "bounding-box" },
                fallback: { $0 == .preview ? "photo" : "viewfinder" },
                label: { $0 == .preview
                    ? "Preview: play the zooms as they will export"
                    : "Crop box: edit where each zoom looks on the full frame" }
            )
            .disabled(aiChat.running)
            // Inside a zoom's hold, "New zoom" tightens that zoom from the
            // playhead on instead of starting an overlapping one.
            let inHold = holdSegmentIndex
            Button {
                if let index = inHold {
                    addZoomStepAtPlayhead(segIndex: index)
                } else {
                    addZoomAtPlayhead()
                }
            } label: {
                HStack(spacing: 6) {
                    Icon(name: "magnifying-glass-plus", size: 16, fallback: "plus.magnifyingglass")
                    Text(inHold == nil ? "New zoom" : "Zoom in further")
                }
            }
            .buttonStyle(.themed(.outline, size: .md, leadingIcon: true))
            .disabled(aiChat.running)
            .tooltip(inHold == nil
                  ? "Add a zoom at the playhead"
                  : "Zoom in further from the playhead on, staying inside this zoom")
            Button {
                if let index = inHold { addPanAtPlayhead(segIndex: index) }
            } label: {
                HStack(spacing: 6) {
                    Icon(name: "arrows-out-cardinal", size: 16, fallback: "arrow.up.and.down.and.arrow.left.and.right")
                    Text("New pan")
                }
            }
            .buttonStyle(.themed(.outline, size: .md, leadingIcon: true))
            .disabled(aiChat.running || inHold == nil)
            .tooltip(inHold == nil
                  ? "Move the playhead inside a zoom to add a pan there"
                  : "Glide the camera to a new spot from the playhead on, staying inside this zoom")
            DropdownButton(
                id: "editor.planSource", edge: .top, alignment: .leading,
                style: { _ in .themed(.outline, size: .md, trailingIcon: true) },
                items: { planSourceItems }
            ) { _ in
                HStack(spacing: 6) {
                    Text("Start from")
                    Icon(name: "caret-down", size: 16, fallback: "chevron.down")
                }
            }
            .disabled(aiChat.running)
            .tooltip("Load the zooms from the current plan, an earlier export, or regenerate them from the click log")
            Button {
                withAnimation { showAIPanel.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if aiChat.running {
                        ProgressView().controlSize(.mini)
                    }
                    Text("Polish with AI")
                }
            }
            .buttonStyle(.themed(.primary, size: .md, leadingIcon: aiChat.running))
            .tooltip("Open the AI Polish panel: hand the plan to Claude Code or Codex for editorial touch-up")
            Spacer()
            Button {
                setComparing(!comparing)
            } label: {
                HStack(spacing: 6) {
                    Icon(name: "rows", size: 16, fallback: "rectangle.split.1x2")
                    Text("Compare")
                }
            }
            .buttonStyle(.themed(comparing ? .primary : .outline, size: .md, leadingIcon: true))
            .disabled(!comparing && planDiff == nil)
            .tooltip(comparing
                  ? "Back to the normal preview"
                  : "Play the edited zooms before and after your changes, stacked top and bottom")
            if let fraction = model.exportProgress[folder] {
                ExportProgressControls(fraction: fraction, width: 280) {
                    model.cancelExport(recording)
                }
            } else {
                ExportSplitButton(title: "Export with Zooms", edge: .top) {
                    recording.savePlan(segments)
                    model.export(recording)
                }
                .disabled(aiChat.running)
            }
        }
    }

    func addZoomAtPlayhead() {
        guard let meta else { return }
        let start = min(currentTime, max(0, duration - 0.5))
        let end = min(start + 2.0, duration)
        // Center on wherever the cursor was at this moment, if we know.
        let p = FrameComposer.cursorPosition(samples: meta.samples, at: start)
        let config = ZoomPlanner.Config()
        let segment = ZoomSegment(
            start: start,
            end: end,
            zoom: config.zoomLevel,
            cx: p?.x ?? Double(meta.pixelWidth) / 2,
            cy: p?.y ?? Double(meta.pixelHeight) / 2
        )
        segments.append(segment)
        select(.segment(segment.id))
    }
}
