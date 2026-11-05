"""Builds server/static/emoji.js from Unicode's emoji-test.txt (https://unicode.org/Public/emoji/latest/emoji-test.txt):
   python3 scripts/make-emoji.py emoji-test.txt server/static/emoji.js"""
import re, sys
MAX = (15, 0)
groups, cur = [], None
for line in open(sys.argv[1], encoding="utf-8"):
    m = re.match(r"# group: (.+)", line)
    if m:
        cur = None if m.group(1).strip() == "Component" else (m.group(1).strip(), [])
        if cur:
            groups.append(cur)
        continue
    m = re.match(r"([0-9A-F ]+?)\s*; fully-qualified\s*# (\S+) E(\d+)\.(\d+) (.+)", line)
    if not m or cur is None:
        continue
    cps = [int(x, 16) for x in m.group(1).split()]
    if any(0x1F3FB <= c <= 0x1F3FF for c in cps):
        continue  # skin tones: the default only
    if (int(m.group(3)), int(m.group(4))) > MAX:
        continue
    name = m.group(5).strip()
    assert "|" not in name and "\\" not in name and '"' not in name, name
    cur[1].append(f"{''.join(map(chr, cps))} {name}")

out = [f"""// Every emoji the reaction picker offers (X49), in Unicode's groups: each
// entry is the emoji, a space, and its name (for searching), entries split by
// "|". From Unicode's emoji-test.txt: fully-qualified, Emoji {MAX[0]}.{MAX[1]} and older
// (so phones and computers from the last few years draw them all), skin tones
// left at the default. Loaded only when the picker first opens. What counts as
// a reaction is isReaction (crypto.js), not this list: one picked in another
// app shows whether or not it's here.
export const EMOJI_GROUPS = ["""]
for name, items in groups:
    out.append(f'  ["{name}", "{"|".join(items)}"],')
out.append("];\n")
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(out))
print(sum(len(i) for _, i in groups), "emoji in", len(groups), "groups")
