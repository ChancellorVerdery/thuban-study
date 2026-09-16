#!/usr/bin/env python3
"""Generates Assets.xcassets/Icons/<id>.imageset from docs/icons.md (template SVGs, stroke #000000)."""
import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOC = os.path.join(ROOT, "docs", "icons.md")
OUT = os.path.join(ROOT, "ThubanStudy", "Resources", "Assets.xcassets", "Icons")

doc = open(DOC, encoding="utf-8").read()
blocks = re.findall(r"## ([a-z0-9-]+)\n.*?\n(<svg.*?</svg>)", doc, re.S)
assert len(blocks) == 12, len(blocks)

os.makedirs(OUT, exist_ok=True)
with open(os.path.join(OUT, "Contents.json"), "w") as f:
    json.dump({"info": {"author": "xcode", "version": 1}, "properties": {"provides-namespace": False}}, f, indent=2)

for name, svg in blocks:
    svg = svg.replace('stroke="currentColor"', 'stroke="#000000"')
    svg = svg.replace("<svg ", '<svg width="24" height="24" ', 1)
    d = os.path.join(OUT, name + ".imageset")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, name + ".svg"), "w", encoding="utf-8") as f:
        f.write(svg + "\n")
    with open(os.path.join(d, "Contents.json"), "w") as f:
        json.dump(
            {
                "images": [{"filename": name + ".svg", "idiom": "universal"}],
                "info": {"author": "xcode", "version": 1},
                "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"},
            },
            f,
            indent=2,
        )
    print(name)
