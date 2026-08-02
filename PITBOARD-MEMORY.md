# PitBoard — project memory (updated 2026-08-02)

Shared drawing canvas for Sean × Claude collaboration; prototype for an eventual
big-touchscreen "talk and modify drawings together" setup.

## Architecture

- **Board state**: `board.json` in private repo `Overtakersf1/pitboard-sync` (branch main).
  Schema: `{app:"pitboard", version:1, rev:N, updatedBy:"sean"|"claude", elements:[...]}`.
  Elements: stroke (points [[x,y,pressure]]), rect/ellipse/diamond (x,y,w,h,label),
  line/arrow (x1,y1,x2,y2), text (x,y,text,fontSize). color: "ink" = auto-contrast token, or #rrggbb.
  v2.7 additions on strokes: `alpha` (0-1 translucency; absent = opaque) and `ink`
  (source ink name: marker/watercolor/crayon/pencil — texture NOT rendered, only alpha).
  Beacon convention: ellipse with id prefix "beacon-", label "👀", color #ff6b6b =
  "Sean wants Claude's attention here" — check for these when reading the board.
  ⚠ SCHEMA-CHANGE HAZARD: Swift Codable STRIPS unknown fields on re-encode. Adding a
  field means old native builds scrub it from the whole board on their next push.
  Rollout order: web first (JS preserves unknown fields), then native, THEN start
  writing the new field.
- **Web app**: public repo `Overtakersf1/pitboard-app`, root `index.html`, served at
  https://overtakersf1.github.io/pitboard-app/ (GitHub Pages). Credentials entered once,
  kept in localStorage. Version badge next to logo (v2.6 as of this writing).
- **Native iPad app**: `pitboard-app/ios/PitBoard/` — SwiftUI + PencilKit, 7 Swift files.
  Sean's `PitBoard.xcodeproj` lives INSIDE his clone at `ios/` (moved there so the
  new-format Xcode project auto-syncs the sibling `PitBoard/` source folder).
  Update loop: **Integrate → Pull, then ⌘R**. Version label in ContentView
  ("native v0.1.11" currently) — BUMP IT ON EVERY CHANGE.

## Sync protocol (both clients implement this — don't regress it)

- Poll every 3s with ETag (304s are free). Push debounced 2s, **min 5s between pushes**
  (GitHub contents API bounces rapid same-file writes).
- **Stale-read guard**: never adopt remote state with rev <= local rev (GitHub reads are
  eventually consistent, especially right after your own push).
- Conflicts (409/422): 3-way merge by element id vs last-synced base; local wins if both
  changed; rev = max(local, remote)+1. Never inflate rev on failed attempts.
- Mid-poll local edits: merge, never clobber.
- **Claude's pushes MUST bump rev and set updatedBy:"claude"** or clients ignore them as stale.

## Claude's access path (sandbox specifics)

- GitHub REST API is BLOCKED by the sandbox proxy (403, credentials injected).
  **Plain git works** with Sean's fine-grained PAT:
  `git clone https://x-access-token:<TOKEN>@github.com/Overtakersf1/pitboard-sync.git`
  (clone may 502 transiently — retry). Token is scoped to pitboard-sync + pitboard-app,
  Contents read/write. Copy lives in `pitboard-token.txt` in Sean's iCloud
  "Ipad Interface" folder (readable via device bridge in future sessions).
- Sean's iCloud folder (connected to Cowork sessions):
  `/Users/sgleason/Library/Mobile Documents/com~apple~CloudDocs/Documents/Claude/Ipad Interface`
  (same folder as `/Users/sgleason/Documents/Claude/Ipad Interface` — Desktop & Documents sync on).
- To see the board: clone/pull pitboard-sync, render board.json via the web app in
  headless Playwright (executablePath /opt/pw-browsers/chromium), screenshot, Read.

## Hard-won learnings (don't relearn these)

1. **iPad Files/Quick Look runs NO JavaScript**, and iPad Safari won't open local files
   (drag-drop doesn't work). Serving via GitHub Pages was the fix.
2. **PencilKit color magic**: in dark mode it STORES light-mode colors (white ink stored
   as black) and inverts at display. Fix: keep dark UI, map near-black AND near-white
   captured colors to "ink" at commit.
3. **PencilKit width**: `PKStrokePoint.size` ≈ tool width, but visual ink renders
   **~0.68× narrower** than reported (measured from screenshots). CAL=0.68 applied at
   capture; renderer inverts per-point pressure so committed width == live width.
4. Render strokes as **single-pass ribbon fills**, not overlapping capped segments
   (AA self-compositing fattens lines). Pixel-snap bitmap layers to the physical grid.
5. **Tool picker follows first responder** — sheets steal it; reclaim on every
   updateUIView.
6. GitHub contents API: rapid writes → 409s; reads right after a push can be stale.
   Hence the 5s throttle and rev guard.
7. Debugging protocol that worked: version badges everywhere, controlled tests
   (fresh launch, zoom 1), console probes, and **pixel-measuring Sean's screenshots**
   beat five rounds of theory.
8. Both renderers draw strokes as single-pass ribbon fills (never segmented
   stroking) — required for clean alpha and to avoid AA self-fattening.
9. Sandbox shell: `pkill -f <name>` matches the calling shell's own command line
   if the name appears literally in it — construct patterns from variables, or
   kill in a separate command.

## State & roadmap

- Native v0.2.1: full object toolset — select/move (drag, double-tap to edit
  labels/text), erase-anything mode, shape tools with live preview, text tool
  (Scribble-capable), snapshot undo/redo (60 deep), look-here beacon (one-shot,
  drops beacon- ellipse). Object color palette in toolbar. Pan/zoom only in draw
  mode (v0.2.0 scope cut — revisit if it annoys Sean).
  Ink capture maps ink type → alpha: marker .55, watercolor .45, crayon .85,
  pencil .9. Texture (crayon grain etc.) is a documented limitation — solid ribbon
  silhouettes only; `ink` field is recorded for a possible future texture renderer.
- Board contains: demo flowchart, Sean's handwriting tests, Overtakers update-process
  flowchart (cleaned by Claude), various test shapes.
- **CI/CD is LIVE (2026-08-02)**: Apple Developer enrollment approved. Xcode Cloud
  workflow "Default" on pitboard-app builds on every push to main and delivers to
  TestFlight internal group "Pit Crew" (tester seangleason@yahoo.com). App Store
  Connect app name: "PitBoard Interface", bundle com.overtakers.PitBoard.
  Claude's push → ~15 min → update appears in TestFlight on the iPad. No cable, no Mac.
  Sean's .xcodeproj is committed in ios/ (his first push!). BoardRenderer is
  `nonisolated` (Swift 6 concurrency clean). App icon in asset catalog (PB gradient).
- Next options: **v0.2 native object tools** (shapes/text/select), Overtakers flow
  build-out, **Option C design doc** — canvas app calling the Claude API directly
  (the real wall-touchscreen architecture). Big-touchscreen decision: evidence strongly
  positive ("PRETTY GREAT WORKFLOW!!" on the board, rev 106).
- Sean's verdict on native pen feel: "RESPONSIVENESS IS WAY BETTER!!" (written on the board).
