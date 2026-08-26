# Hybrid shadcn/Base UI plan for Crisp

Status: Proposed  
Scope: Introduce a React UI surface that can consume the future component library while preserving Crisp's native capture, rendering, permissions, filesystem, lifecycle, and Zoom Editor implementation.

## Outcome

Crisp will gain a locally bundled Vite/React interface built with shadcn components on Base UI. Swift remains the source of truth and the only layer allowed to use ScreenCaptureKit, AVFoundation, AppKit, the filesystem, and application lifecycle APIs.

The first production slice will replace only the recordings list in the main window. After that pilot is stable, the recorder controls can move incrementally. The Zoom Editor and its `AVPlayerLayer` stay native until a separate migration decision is justified.

```text
Future component library / local shadcn components
                         |
                  WebUI (React/Vite)
                         |
        versioned JSON commands and state events
                         |
             WKWebView host + Swift bridge
                         |
                    AppModel
                         |
 ScreenCaptureKit / AVFoundation / Core Image / filesystem
```

## Decisions and assumptions

- Use pnpm, Vite, React, TypeScript, Tailwind CSS v4, shadcn, and Base UI.
- Make the primitive choice explicit with `-b base`, even though Base UI is currently shadcn's default.
- Add the app under `WebUI/`; do not turn the Swift repository into a JavaScript monorepo unless the component library is later moved into this repository.
- Add `WebUI/src/ui/index.ts` as a stable adapter. Initially it may re-export local shadcn components. When the library is published, it will re-export `<ui-package>` instead. Do not invent the package name before it is known.
- Prefer a versioned npm package for Crisp's centrally upgraded runtime dependency. An optional shadcn registry may also distribute source to other consumers. A shadcn registry is a development-time source distribution mechanism, not a runtime service.
- Build all web assets locally and package them into the app. Production Crisp must not require a dev server, CDN, registry, or network connection to render its UI.
- Copy `WebUI/dist/` into `Contents/Resources/WebUI/` in `scripts/bundle.sh` before signing, then load it through `Bundle.main.resourceURL`. This matches Crisp's handwritten app assembly. Do not add `Bundle.module` unless the project deliberately adopts SwiftPM resource packaging and also copies the generated resource bundle into the hand-built app.
- Use `WKWebsiteDataStore.nonPersistent()` initially. Keep durable preferences in Swift/UserDefaults, where Crisp already stores them.
- Keep the existing SwiftUI UI behind a development feature switch until the pilot passes its acceptance checks.
- Treat recordings-list migration as the first milestone. Source thumbnails are a later milestone because `CGImage` transport and the two-second preview cadence require performance testing.

## Non-goals

- Rewriting capture, screenshot, rendering, zoom planning, AI direction, export, permission handling, or termination behavior in JavaScript.
- Moving the Zoom Editor or its native video preview during the initial rollout.
- Exposing arbitrary filesystem paths, shell commands, Swift selectors, or generic native method invocation to the web page.
- Loading production UI code from localhost or the public internet.
- Publishing the component library before its package name and distribution contract are supplied.

## Phase 0 — Documentation and contract lock

### What to implement

1. Record the architectural decision above in this plan and keep the following APIs as the allowed implementation surface.
2. Before implementation, inspect the actual component-library repository or package and fill in:
   - package name and source location;
   - npm package, shadcn registry, or dual-distribution choice;
   - React and Base UI peer dependency ranges;
   - CSS entry point, theme variables, fonts, icons, and dark-mode contract;
   - whether components are compiled or source-distributed;
   - how local development works before publication.
3. Confirm that the component library works in a plain client-only Vite application with `rsc: false` and no Next.js-only imports.
4. Freeze bridge schema version `1` before implementing the first Swift or TypeScript command handler.

### Allowed APIs

Native host and bridge:

- `NSViewRepresentable`, `makeCoordinator()`, `makeNSView(context:)`, `updateNSView(_:context:)`, and `dismantleNSView(_:coordinator:)`
- `WKWebView`, `WKWebViewConfiguration`, and `WKUserContentController`
- `WKScriptMessageHandlerWithReply`
- `addScriptMessageHandler(_:contentWorld:name:)` and `removeScriptMessageHandler(forName:contentWorld:)`
- `WKContentWorld.page`
- `loadFileURL(_:allowingReadAccessTo:)`
- `callAsyncJavaScript(_:arguments:in:contentWorld:)`
- `WKNavigationDelegate`
- `WKWebsiteDataStore.nonPersistent()`
- `WKWebView.isInspectable` for the Dev bundle only
- Optional, after a measured thumbnail spike: `WKURLSchemeHandler`, `WKURLSchemeTask`, and `setURLSchemeHandler(_:forURLScheme:)`

Web UI and distribution:

- shadcn CLI: `init`, `add`, `build`, `registry validate`, `list`, `search`, and `view`
- `components.json`, `registry.json`, and registry-item schemas
- `@base-ui/react` subpath imports
- Base UI `render`, `className`, documented state `data-*` attributes, and portal parts
- `CSPProvider` if the final document applies a strict nonce-based policy

### Documentation references

- Apple: [NSViewRepresentable](https://developer.apple.com/documentation/swiftui/nsviewrepresentable), [WKWebView](https://developer.apple.com/documentation/webkit/wkwebview), [local file loading](https://developer.apple.com/documentation/webkit/wkwebview/loadfileurl%28_%3Aallowingreadaccessto%3A%29), [WKScriptMessageHandlerWithReply](https://developer.apple.com/documentation/webkit/wkscriptmessagehandlerwithreply), [WKNavigationDelegate](https://developer.apple.com/documentation/webkit/wknavigationdelegate), and [WKURLSchemeHandler](https://developer.apple.com/documentation/webkit/wkurlschemehandler)
- shadcn: [Vite installation](https://ui.shadcn.com/docs/installation/vite), [CLI](https://ui.shadcn.com/docs/cli), [components.json](https://ui.shadcn.com/docs/components-json), [monorepo](https://ui.shadcn.com/docs/monorepo), and [registry getting started](https://ui.shadcn.com/docs/registry/getting-started)
- Base UI: [quick start](https://base-ui.com/react/overview/quick-start), [composition](https://base-ui.com/react/handbook/composition), and [CSPProvider](https://base-ui.com/react/utils/csp-provider)
- Crisp lifecycle and windows: `Sources/Crisp/CrispApp.swift:18-58`
- Crisp native state/actions: `Sources/Crisp/AppModel.swift:5-464`

### Verification checklist

- [ ] The real component-library metadata replaces every `<ui-package>` placeholder before package integration.
- [ ] A minimal Vite consumer renders one library button, dialog/popover, and menu without Next.js or server dependencies.
- [ ] The selected Base UI and React versions are stable releases, not canaries.
- [ ] Bridge schema version `1`, command names, response shape, and state-event name are written down before implementation.

### Anti-pattern guards

- Do not use the obsolete `@base-ui-components/react` package; use `@base-ui/react`.
- Do not copy Radix's `asChild` API into Base UI code; Base UI composition uses `render`.
- Do not invent a `base` key in `components.json`; select Base UI through the supported CLI flag or preset.
- Do not treat a shadcn registry as a production runtime dependency.
- Do not begin the bridge with unversioned dictionaries or ad hoc command strings.

## Phase 1 — Bootstrap the isolated WebUI consumer

### What to implement

1. Copy the official shadcn Vite setup into a new `WebUI/` project and select Base UI explicitly:

   ```sh
   pnpm dlx shadcn@latest init -t vite -b base
   ```

2. Commit a pinned `packageManager` value and `WebUI/pnpm-lock.yaml`.
3. Configure Vite with `base: "./"` so `index.html`, hashed assets, dynamic imports, and CSS resolve beneath a local file URL.
4. Set `rsc: false`, TypeScript aliases, CSS variables, and a current shadcn style in `WebUI/components.json` using the documented schema.
5. Add Tailwind v4 through `@tailwindcss/vite` and `@import "tailwindcss"`.
6. Add `WebUI/src/ui/index.ts`. All Crisp web features must import shared controls from this adapter rather than importing the unpublished package throughout the app.
7. Copy Base UI's portal-root setup into the app stylesheet:

   ```css
   #root {
     isolation: isolate;
   }
   ```

8. Add a static application shell with a loading state, error boundary, light/dark token preview, and a mock recordings list. Do not connect it to native state yet.
9. Add scripts for `lint`, `test`, `typecheck`, and `build`; add `node_modules/` and `WebUI/dist/` to `.gitignore` unless the component-library release process later requires a committed artifact.

### Files

- New: `WebUI/package.json`, `WebUI/pnpm-lock.yaml`, `WebUI/components.json`
- New: `WebUI/vite.config.ts`, `WebUI/tsconfig*.json`, `WebUI/index.html`
- New: `WebUI/src/main.tsx`, `WebUI/src/App.tsx`, `WebUI/src/styles/globals.css`
- New: `WebUI/src/ui/index.ts`
- New: `WebUI/src/**/*.test.tsx`
- Update: `.gitignore`, `README.md`

### Documentation references

- Copy the project and alias configuration from [shadcn Vite — Existing Project](https://ui.shadcn.com/docs/installation/vite#existing-project).
- Copy valid fields from [components.json](https://ui.shadcn.com/docs/components-json); do not infer additional keys.
- Copy the root stacking-context rule from [Base UI Quick Start — Portals](https://base-ui.com/react/overview/quick-start#set-up).

### Verification checklist

- [ ] `pnpm --dir WebUI install --frozen-lockfile` succeeds from a clean checkout.
- [ ] `pnpm --dir WebUI lint` succeeds.
- [ ] `pnpm --dir WebUI typecheck` succeeds.
- [ ] `pnpm --dir WebUI test` succeeds.
- [ ] `pnpm --dir WebUI build` creates `WebUI/dist/index.html` and hashed local assets.
- [ ] Opening the built `index.html` locally renders without a network connection or absolute `/assets/...` requests.
- [ ] A Base UI popup renders over the shell and traps/restores focus correctly.

### Anti-pattern guards

- Do not import React or component code from a CDN.
- Do not use the deprecated shadcn `default` style.
- Do not scatter direct component-library imports around feature code; use the adapter.
- Do not add server routes, React Server Components, or framework-specific APIs to this client-only surface.

## Phase 2 — Prove local WebKit loading and packaging

### What to implement

1. Copy the `NSViewRepresentable` structure from `PlayerLayerView` in `Sources/Crisp/EditorView.swift:8-42` into a new `WebAppView`.
2. Construct the complete `WKWebViewConfiguration` before initializing `WKWebView`:
   - nonpersistent website data store;
   - user content controller;
   - navigation delegate;
   - Dev-bundle-only `isInspectable` behavior.
3. Add a `WebAssetLocator` that resolves `Contents/Resources/WebUI/index.html` beneath `Bundle.main.resourceURL`.
4. Load the entry point with `loadFileURL(_:allowingReadAccessTo:)` and grant read access only to `Contents/Resources/WebUI/`.
5. Add a Dev-only explicit environment override for a Vite development URL. Release builds must ignore or reject it.
6. Update `scripts/bundle.sh` to:
   - run the pinned WebUI build script;
   - fail when `dist/index.html` is absent;
   - copy `WebUI/dist/` to `Contents/Resources/WebUI/`;
   - finish all copying before the existing signing step.
7. Add a development-only feature switch that can show the web shell while preserving `ContentView` as the default fallback.
8. Log asset lookup and navigation failures through `AppModel.log`.

### Files

- New: `Sources/Crisp/WebUI/WebAppView.swift`
- New: `Sources/Crisp/WebUI/WebAssetLocator.swift`
- Update: `Sources/Crisp/ContentView.swift` or `Sources/Crisp/CrispApp.swift`
- Update: `scripts/bundle.sh`, `README.md`

### Documentation references

- Copy the native host lifecycle from `Sources/Crisp/EditorView.swift:8-42` and the coordinator/cleanup hooks from [NSViewRepresentable](https://developer.apple.com/documentation/swiftui/nsviewrepresentable).
- Copy the least-privilege loading call from [loadFileURL(_:allowingReadAccessTo:)](https://developer.apple.com/documentation/webkit/wkwebview/loadfileurl%28_%3Aallowingreadaccessto%3A%29).
- Preserve app names, bundle identifiers, and signing order from `scripts/bundle.sh:16-78`.

### Verification checklist

- [ ] `swift build` succeeds.
- [ ] `./scripts/bundle.sh` succeeds after a clean WebUI build.
- [ ] `build/Crisp Dev.app/Contents/Resources/WebUI/index.html` exists.
- [ ] `codesign --verify --deep --strict "build/Crisp Dev.app"` succeeds.
- [ ] The bundled app renders the web shell with networking disabled.
- [ ] Missing/corrupt web assets show the native fallback and produce a useful Crisp log entry.
- [ ] Crisp Dev is inspectable; release Crisp is not.
- [ ] Navigation outside the local web root is denied.

### Anti-pattern guards

- Do not grant `loadFileURL` access to the app bundle, home directory, or `/`.
- Do not mutate `WKWebViewConfiguration` after creating the web view.
- Do not copy web resources after code signing.
- Do not use `#if DEBUG` alone for inspectability; both current bundle variants use a release Swift build.
- Do not commit `node_modules/` or accidentally rely on untracked `dist/` during release.

## Phase 3 — Add a typed, least-privilege bridge

### What to implement

1. Add Codable bridge DTOs rather than serializing `AppModel`, `SCDisplay`, `SCWindow`, `CGImage`, `URL`, `CGRect`, or Swift enums directly.
2. Use a single `WKScriptMessageHandlerWithReply` named `crisp`, registered in `WKContentWorld.page` before web-view construction.
3. Define the request contract:

   ```json
   {
     "version": 1,
     "id": "request-id",
     "command": "app.ready",
     "payload": {}
   }
   ```

4. Define success/error replies consistently:

   ```json
   { "ok": true, "value": {} }
   { "ok": false, "error": { "code": "invalid-command", "message": "..." } }
   ```

5. Implement an explicit command enum and switch. Phase 3 initially allows only:
   - `app.ready`
   - `library.snapshot`
6. Validate main-frame origin, version, command, payload types, and bounds. Hop to `MainActor` before reading or mutating `AppModel`.
7. Call the reply handler exactly once on every success and failure path.
8. On `app.ready`, return the initial state and mark the page ready for events.
9. Send later state through `callAsyncJavaScript(_:arguments:in:contentWorld:)` using an argument dictionary, dispatching `crisp:native-state`. Never interpolate JSON into JavaScript source.
10. Remove the registered handler, delegates, subscriptions, and references in representable teardown.
11. Add a TypeScript bridge client with runtime validation, a mock implementation for browser tests, and a clear “native bridge unavailable” state.
12. Add a Swift test target in `Package.swift` for envelope decoding, command allowlisting, response encoding, ID lookup, and navigation-policy decisions.

### Files

- New: `Sources/Crisp/WebUI/WebBridge.swift`
- New: `Sources/Crisp/WebUI/WebBridgeModels.swift`
- New: `Sources/Crisp/WebUI/WebNavigationPolicy.swift`
- New: `WebUI/src/native/bridge.ts`, `contracts.ts`, `mockBridge.ts`
- New: `Tests/CrispTests/WebBridgeTests.swift`
- Update: `Package.swift`

### Documentation references

- Copy the Promise/reply pattern from [WKScriptMessageHandlerWithReply](https://developer.apple.com/documentation/webkit/wkscriptmessagehandlerwithreply).
- Copy the argument-passing approach from `WKWebView.callAsyncJavaScript` under [WKWebView — Executing JavaScript](https://developer.apple.com/documentation/webkit/wkwebview).
- Follow Crisp's versioned Codable compatibility pattern in `Sources/Crisp/Models.swift:37-104`.
- Route native work through the existing `@MainActor` model in `Sources/Crisp/AppModel.swift:5-464`.

### Verification checklist

- [ ] Swift tests reject unknown versions, commands, malformed payloads, subframe messages, and unknown recording IDs.
- [ ] Swift tests prove each handler path replies once.
- [ ] Frontend tests cover success, native error, malformed response, timeout/web-process reload, and unavailable bridge states.
- [ ] Reloading the page repeats `app.ready` and receives a fresh snapshot.
- [ ] State sent before readiness is queued/coalesced rather than lost.
- [ ] No bridge API accepts a raw path, URL, JavaScript string, shell command, or native method name.

### Anti-pattern guards

- Do not expose a generic `invoke(methodName, args)` bridge.
- Do not use unrestricted `evaluateJavaScript` or interpolate user-controlled JSON into scripts.
- Do not return `Data`, `CGImage`, `SCDisplay`, or domain structs directly through WebKit.
- Do not register the same handler twice or fail to remove it during teardown.
- Do not register the React-facing handler solely in a content world the page cannot access.

## Phase 4 — Ship the recordings-list pilot

### What to implement

1. Replace only `recordingsList` at `Sources/Crisp/ContentView.swift:416-429` with `WebRecordingsList` behind the feature switch. Keep the recorder panel, source controls, permissions, screenshots, and zoom settings native.
2. Map each current `Recording` to a small DTO:
   - opaque ID resolved against `model.recordings`;
   - display name;
   - `hasExport`;
   - export progress when active.
3. Add allowlisted commands:
   - `library.refresh`
   - `recording.openEditor`
   - `recording.export`
   - `recording.reveal`
   - `recording.trash`
4. Resolve every recording command against the current in-memory recording list. Never accept a folder path from JavaScript.
5. Route export, reveal, and trash to the existing methods in `AppModel.swift:435-467`.
6. Pass a native `openEditor(URL)` closure from the SwiftUI environment for the existing typed editor window behavior in `ContentView.swift:432-459`.
7. Preserve recoverable deletion through `FileManager.trashItem`; show a Base UI confirmation dialog before issuing `recording.trash`.
8. Subscribe to `recordings` and `exportProgress` changes and coalesce native state events.
9. Match the existing empty state, export progress, “Edit Zooms,” “Export with Zooms,” reveal, and trash behavior.

### Documentation references

- Copy the current behavior from `Sources/Crisp/ContentView.swift:414-478` rather than redesigning the feature during migration.
- Reuse `AppModel.export`, `reveal`, and `delete` from `Sources/Crisp/AppModel.swift:435-467`.
- Follow Base UI's documented dialog/menu composition and `render` API rather than Radix `asChild` patterns.

### Verification checklist

- [ ] Empty and populated libraries match the native feature behavior.
- [ ] Export progress updates without polling from React.
- [ ] Edit Zooms opens the existing native `WindowGroup<URL>`.
- [ ] Reveal opens Finder through native code.
- [ ] Trash requires confirmation and moves the directory to Trash rather than deleting permanently.
- [ ] An ID for a removed recording is rejected safely.
- [ ] The native fallback continues to work after a web-content-process failure.
- [ ] VoiceOver labels, keyboard traversal, Escape behavior, focus restoration, dark mode, and Retina rendering pass manually on macOS 14 and the current development OS.

### Anti-pattern guards

- Do not send file URLs or filesystem paths to the page.
- Do not add React polling for export progress or library state.
- Do not duplicate renderer or filesystem code in TypeScript.
- Do not migrate the native editor as part of this phase.

## Phase 5 — Harden packaging, security, and recovery

### What to implement

1. Make `scripts/bundle.sh` fail closed when WebUI install/build/output verification fails.
2. Add a restrictive navigation policy:
   - allow only the main frame's bundled entry point and descendants beneath the web asset root;
   - cancel other in-webview navigation;
   - open explicitly allowed `https` links through `NSWorkspace` only after validation;
   - reject subframe bridge messages.
3. Add web-content-process recovery: show a native error/fallback, recreate the web view, repeat `app.ready`, and request a fresh snapshot.
4. Add an asset/bridge smoke check to the normal test flow without invoking ScreenCaptureKit permissions.
5. Document local frontend bootstrap, development server usage, bundled testing, and release behavior in `README.md`.
6. Add CI only if the repository adopts CI; the required job order is frozen dependency install, frontend checks, Swift checks, bundle assembly, resource assertion, and code-sign verification where signing is available.

### Verification checklist

- [ ] A clean checkout can install pinned dependencies and produce a signed Dev app.
- [ ] The released zip contains `Contents/Resources/WebUI/index.html` and all referenced assets.
- [ ] `swift build && .build/debug/Crisp --selftest` still passes.
- [ ] `pnpm --dir WebUI lint`, `typecheck`, `test`, and `build` pass.
- [ ] `codesign --verify --deep --strict "build/Crisp Dev.app"` passes.
- [ ] The app launches and renders offline.
- [ ] Navigation to `file:///`, an external file, `javascript:`, and an unapproved `https` URL is denied.
- [ ] Killing/reloading web content cannot duplicate handlers or native commands.
- [ ] Crisp still finalizes an active recording during termination through `AppDelegate.applicationShouldTerminate`.

### Anti-pattern guards

- Do not weaken ScreenCaptureKit's existing permission-gated refresh loop.
- Do not make the optional quota-spending `CRISP_AI_SELFTEST=1` leg part of routine verification.
- Do not broaden file-read access to solve missing-asset bugs.
- Do not silently fall back to a remote URL in production.

## Phase 6 — Migrate the remaining main-window controls incrementally

Do not start this phase until the recordings-list pilot has shipped without bridge, focus, accessibility, or packaging regressions.

### What to implement

1. Move small-state controls first:
   - zoom settings and reset;
   - codec and screenshot format;
   - permission card and toast/status messaging.
2. Move record/stop and screenshot commands next, routing only to existing `AppModel` methods.
3. Preserve `model.refresh()` when the host appears, the native ⌘R command, app hiding after recording starts, and relaunch/termination behavior.
4. Keep source selection and thumbnails native until the thumbnail spike is complete.
5. Run the thumbnail spike with representative numbers of displays and windows:
   - measure base64 prototype payload size, allocation, decode time, and two-second update cost;
   - compare a narrow `WKURLSchemeHandler` keyed by opaque current-snapshot IDs;
   - retain a native SwiftUI source-picker island if neither web transport meets the performance target.
6. If a custom scheme wins, register it before web-view construction and implement the required response → data → finish ordering. Reject expired or unknown IDs.
7. Remove each SwiftUI section only after its web equivalent passes parity checks; retain a whole-window fallback until the entire main window is stable.

### Verification checklist

- [ ] Permission prompts do not repeat or spam while unauthorized.
- [ ] Start/stop finalizes valid masters and preserves application hiding/reactivation.
- [ ] ⌘R still starts/stops recording from the main window.
- [ ] Screenshot format, codec, zoom values, and reset persist through native UserDefaults.
- [ ] Source previews update at the existing cadence without memory growth or visible UI stalls.
- [ ] Thumbnail transport does not expose arbitrary files or stale IDs.
- [ ] Main-window minimum sizing remains equivalent to `560×680`, unless a deliberate design change is approved.

### Anti-pattern guards

- Do not let JavaScript own capture polling or permission probes.
- Do not place full-resolution or repeatedly refreshed base64 thumbnails in the general state snapshot.
- Do not replace native UserDefaults with persistent browser storage without a separate migration plan.
- Do not move ScreenCaptureKit or AppKit types into the web contract.

## Phase 7 — Connect and publish the component library

### What to implement

1. Once the real library is available, validate it in the isolated Vite consumer before changing Crisp imports.
2. Replace the implementation of `WebUI/src/ui/index.ts` with exports from `<ui-package>`; keep feature imports unchanged.
3. For the preferred npm route:
   - publish deterministic package artifacts, types, and CSS;
   - declare documented React/Base UI compatibility;
   - pin Crisp to a released version through `pnpm-lock.yaml`;
   - test production tree shaking and CSS inclusion in the bundled WebUI.
4. If source distribution is also desired, copy the official shadcn registry schemas:
   - `registry:ui` for primitives;
   - `registry:block` for composed features;
   - `registry:theme` for tokens;
   - `registry:base` for the complete design-system setup.
5. Validate the registry before publication:

   ```sh
   pnpm dlx shadcn@latest build
   pnpm dlx shadcn@latest registry validate owner/repo
   pnpm dlx shadcn@latest add owner/repo/button --dry-run
   ```

6. Keep registry access and package installation in development/release tooling. The shipped app remains self-contained.
7. If the native editor should visually match the library, publish a platform-neutral token artifact and create a separately reviewed Swift token-generation step. Do not attempt to reuse React components in SwiftUI.

### Documentation references

- Copy registry fields and item types from [registry getting started](https://ui.shadcn.com/docs/registry/getting-started), [registry item schema](https://ui.shadcn.com/docs/registry/registry-item-json), and [registry examples](https://ui.shadcn.com/docs/registry/examples).
- Copy public GitHub validation from [GitHub registries](https://ui.shadcn.com/docs/registry/github); use [registry namespaces](https://ui.shadcn.com/docs/registry/namespace) for authenticated/private distribution.

### Verification checklist

- [ ] Crisp builds with the published package from a clean lockfile install.
- [ ] No Crisp feature imports the package outside `WebUI/src/ui/index.ts` unless deliberately approved.
- [ ] The WebUI bundle contains required styles and no duplicate React runtime.
- [ ] The app still renders offline after dependencies are installed and bundled.
- [ ] Registry validation and dry-run installation pass if a registry is published.
- [ ] Registry credentials are absent from the repository and built app.

### Anti-pattern guards

- Do not publish unresolved registry `include` catalogs as hosted output.
- Do not omit `dependencies` or `registryDependencies` from registry items.
- Do not use direct GitHub URLs for a private registry; use the documented authenticated namespace flow.
- Do not ship credentials, registry URLs required at runtime, or canary Base UI builds.

## Phase 8 — Editor decision gate

The default decision is to keep `EditorView` native. It uses `AVPlayerLayer`, `AVVideoComposition`, time observers, zoom-plan autosave, and an existing workaround for a SwiftUI `VideoPlayer` crash.

Only create a separate editor migration plan if the main-window rollout proves that WebKit materially improves the product and the following questions have measured answers:

- Can native preview and web controls share focus, resizing, keyboard shortcuts, and drag gestures reliably?
- Is the timeline better implemented as a web control around a native player, or should it remain fully native?
- Can zoom-plan updates remain type-safe and avoid duplicating editor state in Swift and React?
- Does the result preserve playback/composition performance and accessibility on the minimum supported macOS?

Until then, share design tokens with the editor if desired, but do not replace `Sources/Crisp/EditorView.swift`.

## Final verification and cutover

Run the complete matrix from a clean checkout:

```sh
pnpm --dir WebUI install --frozen-lockfile
pnpm --dir WebUI lint
pnpm --dir WebUI typecheck
pnpm --dir WebUI test
pnpm --dir WebUI build
swift test
swift build
swift build && .build/debug/Crisp --selftest
./scripts/bundle.sh
test -f "build/Crisp Dev.app/Contents/Resources/WebUI/index.html"
codesign --verify --deep --strict "build/Crisp Dev.app"
open "build/Crisp Dev.app"
```

Manual acceptance matrix:

- fresh install with no Screen Recording permission;
- permission granted, revoked, and re-granted;
- no recordings, one recording, and a large library;
- export success, progress, repeat export, and export failure;
- editor launch, Finder reveal, confirmed trash, and stale-ID rejection;
- record/stop, quit while recording, screenshot, relaunch, and Dev/release side-by-side behavior;
- light/dark appearance, Retina/non-Retina display, keyboard-only use, VoiceOver, focus restoration, menus/popovers/dialogs, and web-content reload;
- minimum supported macOS 14 and the current development OS;
- offline launch of the signed application.

Before removing the feature switch, grep/review for known bad patterns:

```sh
rg -n 'evaluateJavaScript|invoke\(|methodName|@base-ui-components/react|asChild|http://|https://' Sources/Crisp/WebUI WebUI
rg -n 'file://|/Users/|allowingReadAccessTo' Sources/Crisp/WebUI
```

Every match must be justified. Remove the fallback only after two consecutive releases complete the acceptance matrix without bridge, packaging, permission, accessibility, or recovery regressions.

## Definition of done

- Crisp consumes the published component library, or the adapter is ready for a one-file switch when it is published.
- The recordings-list pilot is production-ready and the remaining main-window migration is explicitly accepted or deferred.
- All production web assets are local, signed with the app, and available offline.
- The bridge is versioned, typed, allowlisted, main-frame-only, tested, and limited to native-issued opaque IDs.
- Swift remains the sole authority for capture, rendering, permissions, lifecycle, filesystem operations, and persistent settings.
- The existing headless render self-test and signed-app workflow still pass.
- The Zoom Editor remains stable and native unless a separately approved plan supersedes this decision.
