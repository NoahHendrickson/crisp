import SwiftUI
import AVFoundation
import AppKit

// The editor's toolbar (Figma 93:1064), above the timeline: preview /
// crop-box tabs, the zoom level and pin viewport groups that edit the
// moment under the playhead, an overflow menu, then — behind a hairline —
// the AI editor, Send timestamp to chat, and Compare. Everything is one
// 32pt row; an export in progress shows on the right.
extension EditorView {
    // MARK: - Plan

    /// Swaps the plan in, keeping the previous one as the Compare baseline.
    func loadPlan(_ plan: [ZoomSegment]) {
        compareBaseline = segments
        compareTarget = nil
        segments = plan
    }

    /// Throw away the edited plan and regenerate the zooms from the click
    /// log; the edited plan stays available as the Compare baseline.
    func resetZoomsToDefault() {
        try? FileManager.default.removeItem(at: recording.planURL)
        loadPlan(autoSegments())
    }

    func planner() -> ZoomPlanner {
        guard let meta else { return ZoomPlanner(width: 1, height: 1) }
        return ZoomPlanner(meta: meta)
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

    // MARK: - Transport

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

    // MARK: - Toolbar

    var controls: some View {
        let level = playheadLevel
        return HStack(spacing: 8) {
            IconTabsPicker(
                items: Array(ViewMode.allCases),
                selection: $viewMode,
                icon: { $0 == .preview ? "image-duotone" : "bounding-box" },
                fallback: { $0 == .preview ? "photo" : "viewfinder" },
                label: { $0 == .preview
                    ? "Preview: play the zooms as they will export"
                    : "Crop box: see where the camera looks on the full frame; drag a pinned box to move it, its corners to change the level" }
            )
            .disabled(aiChat.running)
            LevelStepper(level: level.value, range: Self.zoomRange)
                .disabled(!level.editable || aiChat.running)
                .tooltip(levelHelp)
            pinControl
                .disabled(aiChat.running)
            moreMenu
                .disabled(aiChat.running)
            toolbarDivider
            Button {
                withAnimation { showAIPanel.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if aiChat.running { ProgressView().controlSize(.mini) }
                    Text("AI editor")
                }
            }
            .buttonStyle(.themed(showAIPanel ? .primary : .outline, size: .md))
            .tooltip(showAIPanel
                  ? "Hide the AI editor"
                  : "Open the AI editor: hand the plan to Claude Code or Codex for an editorial pass")
            Button {
                aiAttachedTime = currentTime
                if !showAIPanel { withAnimation { showAIPanel = true } }
            } label: {
                Text("Send timestamp to chat")
            }
            .buttonStyle(.themed(.outline, size: .md))
            .disabled(aiChat.running)
            .tooltip("Attach the playhead's moment (\(timecodeShort(currentTime))) to your next note so the agent knows exactly where you mean")
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
            Spacer(minLength: 0)
            if let fraction = model.exportProgress[folder] {
                ExportProgressControls(fraction: fraction, width: 200) {
                    model.cancelExport(recording)
                }
            }
        }
        .frame(height: ControlSizeToken.md.height)
    }

    /// The overflow menu (⋮): the plan-level actions that don't need a
    /// button of their own.
    var moreMenu: some View {
        DropdownButton(
            id: "editor.more",
            style: { _ in .themed(.outline, size: .md, iconOnly: true) },
            items: { moreItems() }
        ) { _ in
            Icon(name: "dots-three-outline-vertical", size: 16, fallback: "ellipsis")
        }
        .tooltip("More: add or remove a zoom, reset all, export")
    }

    func moreItems() -> [DropdownItem] {
        var items: [DropdownItem] = []
        if let i = holdIndexAtPlayhead {
            items.append(DropdownItem(id: "remove", label: "Remove this zoom") {
                guard segments.indices.contains(i) else { return }
                segments.remove(at: i)
            })
        } else {
            items.append(DropdownItem(id: "add", label: "Add a zoom here",
                                      detail: "A 2s zoom at the playhead; the camera follows the cursor") {
                addZoom(at: currentTime)
            })
        }
        items.append(DropdownItem(id: "reset", label: "Reset all zooms",
                                  detail: "Regenerate from the click log; Compare keeps your edits") {
            resetZoomsToDefault()
        })
        if model.exportProgress[folder] == nil {
            items.append(DropdownItem(id: "export", label: "Export with zooms",
                                      detail: "\(model.exportFormat.rawValue), saved next to the master") {
                recording.savePlan(segments)
                model.export(recording)
            })
        }
        return items
    }

    /// Hairline between toolbar clusters (Figma 93:1066).
    var toolbarDivider: some View {
        Rectangle()
            .fill(Theme.input)
            .frame(width: 1, height: 24)
            .padding(.horizontal, 4)
    }

    /// A 2s zoom whose hold begins at `t`; the follower frames it.
    func addZoom(at t: Double) {
        let start = min(t, max(0, duration - 0.5))
        let end = min(start + 2.0, duration)
        segments.append(ZoomSegment(start: start, end: end, zoom: ZoomPlanner.Config().zoomLevel))
    }
}
