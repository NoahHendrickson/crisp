---
name: crisp-recorder
description: Record a project demo, application window, browser tab, website, or web view with the Crisp macOS app. Use when the user asks to screen-record, capture a demo video, or make a Crisp recording; do not use for still screenshots or for editing a recording that already exists.
---

# Crisp Recorder

Use Crisp's MCP recording tools when they are available and computer control
only for the demonstration inside the target. The tools talk to the signed
Crisp app, so Screen Recording permission and clean movie finalization stay
with the app. Fall back to the bundled local control CLI when Crisp MCP tools
are not connected.

The MCP server and `crispctl` each bind to the Crisp app bundle they ship in.
Use only those tools to control recording during a session: never click, key,
or raise Crisp's own window with computer use, and never mix builds. Status,
start, and stop all describe that one app; a recording started by hand or in
another Crisp build is invisible to it.

## MCP workflow

1. Call `list_sources` when the exact target is uncertain. Prefer its exact
   `source_id`; a unique `chrome_url`, `window`, or `display` selector also
   works.
2. Call `start_recording` and require a successful result whose status is
   `recording` before demonstrating anything.
3. Perform the requested actions with pointer-based computer use, as described
   under "Drive the demonstration with the real pointer". Keep them deliberate
   and avoid unrelated notifications, credentials, or private tabs.
4. Always call `stop_recording`. Require an `idle` result with `master` and
   `events` paths, then confirm both files exist and `master.mov` is non-empty.
   Use `get_recording_status` for diagnosis and never start a second recording
   while one is active.

The rest of this skill documents preparation, permissions, delivery, and the
CLI fallback in detail.

## Drive the demonstration with the real pointer

Crisp does not capture the on-screen cursor. It logs the system pointer's
position and clicks while recording, re-renders the cursor at export, and
plans its automatic zooms from those logged clicks. Anything that acts on the
target without moving the pointer leaves no trace: accessibility actions
(element-id clicks, AXPress), DOM or DevTools automation (Playwright, CDP,
browser-session tabs), AppleScript, and keyboard-only flows. A recording made
that way has no cursor and no zooms, and its editor shows nothing to zoom on.

- Move the mouse to each control and click at its screen coordinates. Leave
  about a second between actions so each click gets its own zoom, and type
  only after clicking the field.
- Keep the pointer inside the recorded window or display for the whole take.
  Samples outside the source are dropped.
- Keep the target frontmost and unobstructed on one display. Crisp hides its
  own window when recording starts, so nothing else needs to move.
- Pointer-free "background" automation cannot produce a polished clip. If the
  user asks for a hands-off recording, say that it will be a plain capture
  without cursor or zooms before starting, and let them choose.

## Prepare

1. Resolve the capture target and the actions the user wants demonstrated from
   their request. Ask only when the missing choice materially changes the
   recording.
2. Prepare the target before recording. Start the project's development server
   when needed, open the requested route, wait for it to settle, and size the
   target window appropriately. For a URL, prefer a visible Google Chrome tab
   because Crisp can select Chrome tabs by title and host. A Chrome tab source
   activates that tab and crops the recording to the page area of its window
   when Crisp has Accessibility access; otherwise it records the whole window,
   tab strip and toolbar included, and `list_sources` (or `crispctl sources`)
   warns about it. Relay that warning instead of improvising a crop.
3. Find the CLI in this order: `crispctl` on `PATH`,
   `/Applications/Crisp.app/Contents/MacOS/crispctl`, then the current repo's
   `build/Crisp Dev.app/Contents/MacOS/crispctl`. Use the same executable for
   every command in the session. The command launches its containing app.
4. Note the existing folders under `~/Movies/Crisp/` so the new artifact can be
   identified without relying only on its timestamp.

## Select and start with the CLI fallback

Run `crispctl sources --json` (substitute the resolved executable when it is not
on `PATH`). Choose the exact `id` when possible, then start with:

```sh
crispctl start --source 'chrome:WINDOW_ID:TAB_ID' --json
```

Convenience selectors are available when they match exactly one source:

- Website or Chrome tab: `crispctl start --chrome-url 'URL-or-unique-text' --json`
- Native app: `crispctl start --window 'app-or-title' --json`
- Display: `crispctl start --display 'name-or-ID' --json`

Use `--source` if a convenience selector reports ambiguity. Add
`--codec hevc10|prores422|prores4444` only when requested. Region selection is
GUI-only; use the accessible **Region** flow when the user specifically needs a
crop.

If Crisp shows its Screen Recording permission card, stop and tell the user
that the selected Crisp build needs access in **System Settings > Privacy &
Security > Screen & System Audio Recording** and then a relaunch. Do not repeat
permission probes. Chrome-tab selection may separately require the user to
allow Crisp to control Google Chrome under **Privacy & Security > Automation**.

## Demonstrate and stop

1. Require a successful start response whose status is `recording`; retain the
   returned folder path.
2. Perform only the requested demonstration in the chosen target. Keep actions
   deliberate and avoid exposing unrelated notifications, credentials, or
   private tabs.
3. Run `crispctl stop --json`. Do not quit Crisp or use process signals. A
   successful response must report `idle` and return `master` and `events`
   paths after finalization.
4. Confirm both files exist and `master.mov` is non-empty. Use
   `crispctl status --json` for diagnosis; never issue a second start while status
   is `recording`.

## Deliver

Unless the user requested editing or a polished export, the completed artifact
is the new folder's `master.mov`. Return its absolute path and briefly state
which window or tab was recorded. Recordings live in
`~/Movies/Crisp/<recording name>/`.

If the user explicitly requests Crisp's animated zooms or a polished export,
open the new recording in Crisp's editor and use **Export with zooms** after
the capture is verified. Preserve the master; Crisp writes numbered exports
without overwriting earlier ones.

If the bundled CLI is unavailable because the installed app predates it, fall
back to Crisp's accessible GUI controls for selecting the source and starting
and stopping. Explain that the app should be updated before promising
deterministic CLI control.
