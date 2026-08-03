#!/usr/bin/env python3
"""PitBoard board helpers — load/save with the sync invariants handled.

save_board() bumps rev by exactly +1 and sets updatedBy="claude": clients use a
monotonic-rev stale-read guard, so an unbumped rev means your edit is IGNORED.
Loading/saving via plain dicts (never typed models) preserves fields this code
predates — field-stripping has corrupted boards before.

CLI: python3 board_utils.py show <board.json>   # inventory of elements
"""
import json
import random
import string
import sys


def load_board(path):
    with open(path) as f:
        return json.load(f)


def save_board(path, board, who="claude"):
    board["rev"] = int(board.get("rev", 0)) + 1
    board["updatedBy"] = who
    with open(path, "w") as f:
        json.dump(board, f)
    size = len(json.dumps(board))
    if size > 900_000:
        print(f"WARNING: board is {size} bytes — clients break past ~1MB", file=sys.stderr)


def new_id(prefix="claude-"):
    return prefix + "".join(random.choices(string.ascii_lowercase + string.digits, k=7))


def bbox(el):
    t = el.get("type")
    if t == "stroke":
        xs = [p[0] for p in el.get("points", [])]
        ys = [p[1] for p in el.get("points", [])]
        return (min(xs), min(ys), max(xs), max(ys)) if xs else (0, 0, 0, 0)
    if t in ("line", "arrow"):
        return (min(el["x1"], el["x2"]), min(el["y1"], el["y2"]),
                max(el["x1"], el["x2"]), max(el["y1"], el["y2"]))
    x, y = el.get("x", 0), el.get("y", 0)
    return (x, y, x + el.get("w", 200), y + el.get("h", 24))


def show(path):
    d = load_board(path)
    print(f"rev {d.get('rev')} · updatedBy {d.get('updatedBy')} · {len(d['elements'])} elements")
    beacons = [e for e in d["elements"] if str(e.get("id", "")).startswith("beacon-")]
    for b in beacons:
        print(f"  BEACON 👀 at ({b.get('x')}, {b.get('y')}) — render this region first!")
    from collections import Counter
    print(" ", dict(Counter(e["type"] for e in d["elements"])))
    for e in d["elements"]:
        if e["type"] == "text":
            print(f"  text ({round(e['x'])},{round(e['y'])}): {e['text'][:70]!r}")
        elif e.get("label"):
            print(f"  {e['type']} ({round(e.get('x',0))},{round(e.get('y',0))}): label={e['label']!r}")


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "show":
        show(sys.argv[2])
    else:
        print(__doc__)
