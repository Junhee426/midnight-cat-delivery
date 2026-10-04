#!/usr/bin/env python3
"""Rebuild assets/fonts/ui_font.ttf as a subset of NanumGothic Bold (SIL OFL 1.1).

Keeps printable ASCII, common punctuation and every non-ASCII character used in
scripts/*.gd, so the web build stays small. Re-run after adding new UI text:

    pip install fonttools
    python3 tools/subset_font.py /path/to/NanumGothic-Bold.ttf

Source font: https://github.com/google/fonts/tree/main/ofl/nanumgothic
The smoke test fails if any UI character is missing from the subset.
"""
import pathlib
import sys

from fontTools import subset

root = pathlib.Path(__file__).resolve().parent.parent
src = sys.argv[1] if len(sys.argv) > 1 else "NanumGothic-Bold.ttf"
chars = {chr(c) for c in range(32, 127)} | set("·…→←↑↓“”‘’—–•ㆍ")
for path in sorted((root / "scripts").rglob("*.gd")):
    chars |= {ch for ch in path.read_text(encoding="utf-8") if ord(ch) > 127}
opts = subset.Options()
opts.layout_features = ["*"]
opts.name_IDs = ["*"]
opts.notdef_outline = True
font = subset.load_font(src, opts)
sub = subset.Subsetter(opts)
sub.populate(text="".join(sorted(chars)))
sub.subset(font)
out = root / "assets" / "fonts" / "ui_font.ttf"
subset.save_font(font, str(out), opts)
print(f"{out.relative_to(root)}: {len(chars)} chars, {out.stat().st_size} bytes")
