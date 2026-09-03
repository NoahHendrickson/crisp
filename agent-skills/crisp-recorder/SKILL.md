---
name: crisp-recorder
description: Record a project demo, application window, browser tab, website, or web view with the Crisp macOS app. Use when the user asks to screen-record, capture a demo video, or make a Crisp recording; do not use for still screenshots or for editing a recording that already exists.
---

# Crisp Recorder

Use Crisp through native-app computer control. Crisp has no external command
for starting or stopping a capture; its `--agent-tool` interface only inspects
an existing recording for the AI editor.

## Prepare

1. Resolve the capture target and the actions the user wants demonstrated from
   their request. Ask only when the missing choice materially changes the
   recording.
2. Prepare the target before recording. Start the project's development server
   when needed, open the requested route, wait for it to settle, and size the
   target window appropriately. For a URL, prefer a visible Google Chrome tab
   because Crisp can select Chrome tabs by title and host.
3. Find an existing `Crisp` release app first. Fall back to `Crisp Dev`
   (`com.noey.crisp.dev`) or the current repo's `build/Crisp Dev.app`. Remember
   the exact build selected and use that same build for stopping.
4. Note the existing folders under `~/Movies/Crisp/` so the new artifact can be
   identified without relying only on its timestamp.

## Select the source

Open or activate Crisp and use accessibility labels rather than coordinates
whenever possible.

- Website or Chrome tab: choose **Window**, open **Select a window**, switch to
  **Chrome Tabs**, then choose the entry matching both the page title and host.
- Native project/app: choose **Window**, open **Select a window**, stay on
  **App Windows**, then choose the matching app and window title.
- Whole desktop: choose **Display** and the intended display.
- Region: choose **Region** only when the user requested a crop or a suitable
  window target is unavailable; region selection requires a visual drag.

If Crisp shows its Screen Recording permission card, stop and tell the user
that the selected Crisp build needs access in **System Settings > Privacy &
Security > Screen & System Audio Recording** and then a relaunch. Do not repeat
permission probes. Chrome-tab selection may separately require the user to
allow Crisp to control Google Chrome under **Privacy & Security > Automation**.

## Record

1. Click **Record** and verify that Crisp hides itself and that no error is
   shown. If the app stays visible, inspect its state before interacting with
   the target.
2. Perform only the requested demonstration in the chosen target. Keep actions
   deliberate and avoid exposing unrelated notifications, credentials, or
   private tabs.
3. To stop, reactivate the exact Crisp build (for example with macOS `open`),
   then use **Stop Recording** or the app-local `Command-R` shortcut. Never
   terminate the app while capture finalization is in flight.
4. Verify that Crisp returns to its idle **Record** state. Identify the newly
   created folder and confirm that both `master.mov` and `events.json` exist
   and that `master.mov` is non-empty.

## Deliver

Unless the user requested editing or a polished export, the completed artifact
is the new folder's `master.mov`. Return its absolute path and briefly state
which window or tab was recorded. Recordings live in
`~/Movies/Crisp/<recording name>/`.

If the user explicitly requests Crisp's animated zooms or a polished export,
open the new recording in Crisp's editor and use **Export with zooms** after
the capture is verified. Preserve the master; Crisp writes numbered exports
without overwriting earlier ones.
