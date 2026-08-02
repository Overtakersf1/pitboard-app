# PitBoard — native iPad app (v0.1)

Native SwiftUI + PencilKit client for the shared Sean × Claude board.
Same JSON schema, same GitHub relay, same merge protocol as the web app —
this is just a lower-latency pen surface on the same pipeline.

## What v0.1 does

- Apple-native ink: PencilKit capture (~9 ms with Pencil), system tool picker,
  real palm rejection. Finished strokes convert into the shared board JSON.
- Renders everything on the board (your strokes, Claude's shapes/text/arrows).
- Full sync engine: 3 s polling with ETags, 5 s push batching, stale-read
  guard, 3-way merge. Status dot: green / amber / red, tap it for settings.
- Token lives in the iOS Keychain (enter once).
- Pinch to zoom, two-finger pan. Hand button toggles finger draw vs pencil-only.

## v0.1 limitations (by design, web app still covers these)

- No shape/text creation tools yet (Claude adds those from his side on request).
- Undo button removes the last committed element; the PencilKit eraser only
  affects ink not yet committed (strokes commit ~0.6 s after pen-up).

## Build steps (~10 minutes, one time)

1. **Xcode → File → New → Project… → iOS → App.**
   - Product Name: `PitBoard`
   - Interface: **SwiftUI**, Language: **Swift**
   - Organization Identifier: e.g. `com.overtakers`
   - Uncheck tests. Create it anywhere (e.g. ~/Developer).
2. In the new project, delete the generated `ContentView.swift` and
   `PitBoardApp.swift` (Move to Trash).
3. Drag all six files from this folder (`ios/PitBoard/*.swift`) into the
   project navigator's PitBoard group. Check **"Copy items if needed"** and
   make sure the PitBoard **target is ticked**.
4. Project settings → General:
   - Deployment: iOS **16.0**+, check **iPad** (uncheck iPhone if you like).
   - Signing & Capabilities: select your **Team** (your Apple ID / dev account).
5. Project settings → Build Settings → search "language version" →
   set **Swift Language Version = Swift 5** (avoids strict-concurrency noise
   on first build).
6. Plug in the iPad, pick it as the run destination, press **Run** (⌘R).
   - First time: on the iPad, Settings → General → VPN & Device Management →
     trust your developer certificate, then Run again.
7. In the app, paste the GitHub token when the settings sheet appears →
   **Connect & sync**. Green dot = live.

## If the build errors

Paste the exact compiler errors back to Claude in the chat — first-build
fixes are expected and usually take one round trip.
