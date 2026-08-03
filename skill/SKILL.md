---
name: pitboard
description: >
  Read, render, and edit PitBoard — Sean's shared whiteboard system (GitHub-synced
  JSON boards drawn on from his iPad and by Claude). Use this skill whenever Sean
  mentions PitBoard, "the board", "the whiteboard", a board by name (Main,
  Scratchpad, "idea space", or any other), asks you to "look at the board",
  "check what I drew", "add that to the board", "clean up my sketch", or wants to
  collaborate on diagrams, flowcharts, or design ideas on a shared canvas — even
  if he doesn't say "PitBoard" explicitly. Also use it when Overtakers website
  design work or any project would benefit from sketching/diagramming together.
---

# PitBoard — Sean × Claude shared whiteboard

PitBoard is a live shared canvas: Sean draws on his iPad (native app or
https://overtakersf1.github.io/pitboard-app/), Claude reads and edits the same
boards from the sandbox, and a small in-app AI applies voice/typed commands.
All state syncs through GitHub. Your job when this skill triggers: read boards,
render them to actually LOOK at them, and make edits that appear on Sean's
screen within seconds.

## Access

Boards live in the **private repo `Overtakersf1/pitboard-sync`** (branch `main`).

1. Token (fine-grained, contents R/W on pitboard-sync + pitboard-app only —
   SECRET: never echo it into responses, commit it anywhere, or copy it into
   other files; this skill copy must never be shared outside Sean's account):

   (Sean's installed copy embeds the token here; this public copy does not.)

   Fallbacks if it's been rotated: `pitboard-token.txt` in Sean's iCloud folder
   `.../Documents/Claude/Ipad Interface/` (device bridge), or ask Sean. If no
   token works, say so plainly and continue the session — never treat missing
   PitBoard access as a fatal error.
2. In cloud sandboxes the GitHub REST API is usually intercepted by a proxy —
   **use plain git instead**, which passes through:

   ```bash
   git clone "https://x-access-token:${TOKEN}@github.com/Overtakersf1/pitboard-sync.git" pb
   ```

   Clones/pushes can 502 transiently — retry 2–3 times before concluding failure.

## Repo layout

- `board.json` — the **Main** board (legacy path, still primary)
- `boards/<slug>.json` — every other board ("pit-board-idea-space" ↔ "pit board idea space")
- `images/<id>.jpg` — image element binaries (immutable; never modify or delete)

When Sean says "the board" ambiguously, check which boards changed recently
(`git log`) or ask; when told a board name, slugify it (lowercase, dashes).

## Board schema

```json
{"app":"pitboard","version":1,"rev":N,"updatedBy":"sean"|"claude","elements":[...]}
```

Element types (fields beyond `id`, `type`, `color`, `size`):

- `stroke`: `points` [[x,y,pressure0-1]...], optional `alpha` (0-1), `ink` (marker/crayon/…)
- `rect` / `ellipse` / `diamond`: `x,y,w,h`, optional `label` (renders centered)
- `line` / `arrow`: `x1,y1,x2,y2` (arrowhead at x2,y2)
- `text`: `x,y,text,fontSize`
- `image`: `x,y,w,h,src` (repo path) — you may move/resize; **never create one or change src**

Canvas is 3000×2000, y grows downward. `color` is `"ink"` (auto-contrast
default) or hex; palette: `#4da3ff` blue, `#ffb454` amber, `#ff6b6b` red,
`#51d88a` green, `#b78cff` violet.

## Reading and rendering

Parse the JSON for structure, but **render before interpreting drawings** —
handwriting and sketches only make sense visually. Use `scripts/render_board.js`
(Playwright + the PitBoard web renderer):

```bash
# one-time: clone the public app repo next to your board clone for index.html
git clone --depth 1 https://github.com/Overtakersf1/pitboard-app.git app
node scripts/render_board.js app/index.html pb/board.json out.png [x0 y0 x1 y1 zoom]
```

Then Read the PNG. Zoom into regions (bbox args) when reading handwriting.
**Beacons**: an ellipse with id prefix `beacon-`, label `👀`, color `#ff6b6b`
means "Sean wants your attention HERE" — always check for beacons first and
render that region.

## Editing — the rules that keep sync working

Edit with `scripts/board_utils.py` or follow its pattern exactly:

1. `git pull` immediately before editing (Sean may have just drawn).
2. Load with `json.load`, mutate the dict, dump — **never rebuild elements from
   a typed model**: unknown fields must survive round-trips (field-stripping has
   corrupted boards before).
3. **Bump `rev` by exactly +1 and set `updatedBy: "claude"`** — clients ignore
   pushes with a stale rev (that's the stale-read guard; don't defeat it).
4. New element ids: short unique strings; prefix meaningfully (`claude-…`).
5. Commit and push; on rejection, `git pull --rebase` and retry (2–3 attempts).
6. Keep `board.json` under ~1 MB (the clients' API ceiling). Big content →
   crop/summarize, or images (which live outside the board anyway).

Sean's clients poll every 3 s — a pushed edit appears on his iPad almost
immediately. His unpushed work is protected by a 3-way merge, so concurrent
edits are safe; still, prefer *adding* elements over rewriting his.

## Conventions (Sean expects these)

- Reply to Sean's handwritten messages **on the board**, as green (`#51d88a`)
  text near his writing, signed "— Claude".
- When asked to "clean up" a sketch: replace his rough strokes with proper
  shapes/arrows/labels in the same region, keep everything unrelated untouched,
  and leave a small green note that you did.
- Respect his content: move/annotate rather than delete unless asked.
- New boards: create `boards/<slug>.json` with `{app,version:1,rev:1,
  updatedBy:"claude",elements:[...]}` — clients list boards by directory.

## Worked example

Sean: "look at the idea space board and add a box for the caching layer"

```bash
git -C pb pull
python3 scripts/board_utils.py show pb/boards/pit-board-idea-space.json   # inventory
node scripts/render_board.js app/index.html pb/boards/pit-board-idea-space.json look.png
# Read look.png, find the architecture diagram and empty space near it
python3 - <<'EOF'
import sys; sys.path.insert(0, 'scripts')
from board_utils import load_board, save_board
d = load_board('pb/boards/pit-board-idea-space.json')
d['elements'].append({"id":"claude-cache1","type":"rect","x":995,"y":700,
    "w":330,"h":64,"label":"Cache layer","color":"#b78cff","size":3})
save_board('pb/boards/pit-board-idea-space.json', d)   # bumps rev, sets updatedBy
EOF
git -C pb commit -am "pitboard: add cache layer box" && git -C pb push
```

Render again after pushing if precision matters — verify your elements landed
where you intended before telling Sean it's done.
