# Crisp agent guide

## Project

Crisp is a native macOS screen recorder. It captures displays, app windows,
Chrome tabs, or regions with ScreenCaptureKit, logs cursor activity, and exports
polished videos with animated zooms.

## Build and verify

- Build source changes with `swift build`.
- Run the headless pipeline test with
  `swift build && .build/debug/Crisp --selftest`.
- Build the signed development app with `./scripts/bundle.sh`; prefer an
  already-built app when testing recording because rebuilding can change the
  macOS Screen Recording permission identity.
- Treat `~/Movies/Crisp/` and `~/Pictures/Crisp/` as user data. Never remove or
  overwrite recordings as part of a test.

## Recording behavior

- Screen Recording permission belongs to the exact app identity. Do not loop
  permission probes or repeatedly relaunch after a denial.
- Crisp hides itself after recording starts. Prefer the bundled `crispctl stop`
  command, which reaches the hidden app and waits for finalization. When using
  the GUI, reactivate the same app build before its Stop Recording button.
- Always stop a live recording cleanly. Quitting invokes asynchronous
  finalization so `master.mov` receives its movie metadata.
- Chrome-tab capture activates the requested tab and records its whole Chrome
  window. Other app targets use the App Windows picker.
- The bundled `crispctl` executable is the capture control API. `--agent-tool`
  is a separate interface for inspecting and editing an existing recording.

## Agent-made demos

When a user asks to record a project, app, browser tab, or web view, use the
`crisp-recorder` skill when it is available. Its maintained source is
`agent-skills/crisp-recorder/SKILL.md`; read and follow it directly if the host
does not discover local skills automatically.
