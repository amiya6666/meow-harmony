from pathlib import Path
import argparse
import re

parser = argparse.ArgumentParser(description="Extract Meow functional logic and combine it with the plain reference UI.")
parser.add_argument("--source", required=True, help="Path to the source Player.ets from the full application")
args = parser.parse_args()

ROOT = Path(__file__).resolve().parent
SRC = Path(args.source).resolve()
DST = ROOT / "entry" / "src" / "main" / "ets" / "pages" / "Player.ets"
text = SRC.read_text(encoding="utf-8")

stable_marker = "@Component\nstruct StableHdsMiniDisc"
idx = text.find(stable_marker)
if idx < 0:
    stable_marker = "@Component\r\nstruct StableHdsMiniDisc"
    idx = text.find(stable_marker)
if idx < 0:
    raise SystemExit("StableHdsMiniDisc marker not found")
prefix = text[:idx].rstrip() + "\n\n"
prefix = prefix.replace("const BUILD_LABEL: string = 'v1.5.2 · build 117 · HDS 渐变与深色修复';", "const BUILD_LABEL: string = 'Meow Core · full core · plain UI';")
prefix = prefix.replace("import { HdsNavigation, HdsNavDestination, hdsMaterial } from '@kit.UIDesignKit';\n", "")
prefix = prefix.replace("import { HdsBarStyle, HdsTabs, HdsTabsController } from '@hms.hds.hdsBaseComponent';\n", "")

m = re.search(r"@Entry\s*@Component\s*struct\s+Player\s*\{", text)
if not m:
    raise SystemExit("Player struct not found")
open_pos = text.find("{", m.start())

# Find matching closing brace for Player, ignoring strings/comments.
def find_matching_brace(s: str, start: int) -> int:
    depth = 0
    quote = None
    esc = False
    block = False
    line = False
    i = start
    while i < len(s):
        c = s[i]
        n = s[i+1] if i + 1 < len(s) else ""
        if line:
            if c == "\n":
                line = False
            i += 1
            continue
        if block:
            if c == "*" and n == "/":
                block = False
                i += 2
            else:
                i += 1
            continue
        if quote:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == quote:
                quote = None
            i += 1
            continue
        if c == "/" and n == "/":
            line = True
            i += 2
            continue
        if c == "/" and n == "*":
            block = True
            i += 2
            continue
        if c in ("'", '"', '`'):
            quote = c
            i += 1
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ValueError("unmatched brace")

close_pos = find_matching_brace(text, open_pos)
body = text[open_pos + 1:close_pos]
lines = body.splitlines(keepends=True)

# Keep all top-level fields/methods except @Builder blocks and the production build() method.
depth = 1
quote = None
esc = False
block = False
skip_decorated_builder = False
skipping_method = False
kept = []

method_re = re.compile(r"^(?:async\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(")

def update_depth(line_text: str, d: int):
    global quote, esc, block
    line_comment = False
    i = 0
    while i < len(line_text):
        c = line_text[i]
        n = line_text[i+1] if i + 1 < len(line_text) else ""
        if line_comment:
            break
        if block:
            if c == "*" and n == "/":
                block = False
                i += 2
            else:
                i += 1
            continue
        if quote:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == quote:
                quote = None
            i += 1
            continue
        if c == "/" and n == "/":
            line_comment = True
            break
        if c == "/" and n == "*":
            block = True
            i += 2
            continue
        if c in ("'", '"', '`'):
            quote = c
            i += 1
            continue
        if c == "{":
            d += 1
        elif c == "}":
            d -= 1
        i += 1
    return d

for line in lines:
    depth_start = depth
    stripped = line.strip()
    if depth_start == 1 and not skipping_method:
        if stripped == "@Builder":
            skip_decorated_builder = True
            depth = update_depth(line, depth)
            continue
        mm = method_re.match(stripped)
        if mm and (skip_decorated_builder or mm.group(1) == "build"):
            skipping_method = True
            skip_decorated_builder = False
            depth = update_depth(line, depth)
            # one-line method just in case
            if depth == 1:
                skipping_method = False
            continue
        if skip_decorated_builder and stripped:
            # Defensive: builder signature should be here. Drop unexpected continuation too.
            depth = update_depth(line, depth)
            continue
        kept.append(line)
        depth = update_depth(line, depth)
    elif skipping_method:
        depth = update_depth(line, depth)
        if depth == 1:
            skipping_method = False
    else:
        kept.append(line)
        depth = update_depth(line, depth)

minimal_ui = (ROOT / "core_ui_fragment.txt").read_text(encoding="utf-8")
core_logic = "".join(kept).replace("  private hdsTabsController: HdsTabsController = new HdsTabsController();\n", "")

out = prefix + "@Entry\n@Component\nstruct Player {\n" + core_logic.rstrip() + "\n" + minimal_ui + "}\n"
DST.write_text(out, encoding="utf-8", newline="\n")
print(f"wrote {DST}")
print(f"lines: {len(out.splitlines())}")
