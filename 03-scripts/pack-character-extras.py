#!/usr/bin/env python3
"""Pack optional character clips beside the existing atlas; never rewrite base assets."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
CELL = (384, 416)
BASELINE = 406
MAGE_SPECS = [
    ("staff-idle", "持杖待机", 8, 0.5),
    ("staff-channel", "蓄力咏唱", 8, 0.18),
    ("water-cast", "施放水球术", 8, 0.15),
    ("staff-salute", "法杖致意", 6, 0.18),
]
SWORD_SPECS = [
    ("sword-idle", "持剑待机", 8, 0.4),
    ("sword-practice", "练剑挥斩", 8, 0.14),
    ("sword-salute", "剑礼致意", 6, 0.18),
]


def font(size):
    for path in ["/System/Library/Fonts/PingFang.ttc", "/System/Library/Fonts/STHeiti Light.ttc"]:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            pass
    return ImageFont.load_default()


def pack(source, output, preview, kind="mage", storm_source=None):
    specs = list(MAGE_SPECS if kind == "mage" else SWORD_SPECS)
    if storm_source:
        if kind != "mage":
            raise ValueError("Cumulonimbus belongs to the mage sidecar")
        specs.append(("cumulonimbus", "豪雷积雨云", 8, 0.28))
    elif (output / "manifest.json").exists():
        existing = json.loads((output / "manifest.json").read_text())
        if any(a["id"] == "cumulonimbus" for a in existing["actions"]):
            raise ValueError("Use --storm-source to preserve the existing Cumulonimbus action")
    profile = json.loads((output.parent / "character.json").read_text())
    heading = profile["name"] + " · " + profile["appearance"] + (" · 法杖动作" if kind == "mage" else " · 剑术动作")
    baseline = BASELINE if kind == "mage" else 404
    spec = importlib.util.spec_from_file_location("existing_sprite_packer", ROOT / "03-scripts/pack-eris-atlas.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    # The caller must supply an independent actions folder, never an appearance's base folder.
    if output.name != "actions":
        raise ValueError("Output must be an actions/ sidecar directory")
    base = output.parent / "spritesheet.png"
    original_hash = hashlib.sha256(base.read_bytes()).hexdigest() if base.exists() else None
    previous_rows = None
    if kind == "mage" and storm_source and (output / "spritesheet.png").exists():
        previous_rows = Image.open(output / "spritesheet.png").convert("RGBA").crop((0, 0, CELL[0] * 8, CELL[1] * 4))
    atlas = Image.new("RGBA", (CELL[0] * 8, CELL[1] * len(specs)))
    manifest = {"version": 1, "columns": 8, "rows": len(specs),
                "cellWidth": CELL[0], "cellHeight": CELL[1], "actions": []}
    qa = {"scope": "additive sidecar only", "cell": CELL, "atlas": atlas.size,
          "baseline": baseline, "actions": []}
    clips = []
    for row, (name, title, count, duration) in enumerate(specs):
        path = storm_source if name == "cumulonimbus" else source / (name + ".png")
        image = Image.open(path).convert("RGBA")
        pieces = module.split_sheet(image, count)
        scale = min(1.0, *(368 / sprite.width for sprite, _ in pieces),
                    *((baseline - 10) / sprite.height for sprite, _ in pieces))
        records, frames = [], []
        frame_dir = (storm_source.parent.parent if name == "cumulonimbus" else source.parent) / "frames" / name
        frame_dir.mkdir(parents=True, exist_ok=True)
        for col, (sprite, bounds) in enumerate(pieces):
            size = (round(sprite.width * scale), round(sprite.height * scale))
            scaled = sprite.resize(size, Image.Resampling.LANCZOS)
            frame = Image.new("RGBA", CELL)
            xy = ((CELL[0] - size[0]) // 2, baseline - size[1])
            if name == "cumulonimbus":
                # Keep the authored camera/foot baseline fixed while the cloud expands.
                # Centering each changing effect bbox would make the character slide.
                source_center = (col % 4 + 0.5) * image.width / 4
                source_baseline = max(b[3] for _, b in pieces[(col // 4) * 4:(col // 4 + 1) * 4])
                xy = (round(CELL[0] / 2 + (bounds[0] - source_center) * scale),
                      round(baseline + (bounds[1] - source_baseline) * scale))
            frame.alpha_composite(scaled, xy)
            box = frame.getbbox()
            assert box and box[0] >= 4 and box[1] >= 4 and box[2] <= CELL[0] - 4 and box[3] <= CELL[1] - 4
            frame.save(frame_dir / ("%02d.png" % col))
            atlas.alpha_composite(frame, (col * CELL[0], row * CELL[1]))
            frames.append(frame)
            records.append({"frame": col, "source_bbox": bounds, "output_bbox": box, "scale": scale})
        manifest["actions"].append({"id": name, "title": title, "row": row,
                                    "frameCount": count, "frameDuration": duration})
        qa["actions"].append({"id": name, "source_size": image.size,
                              "source_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                              "frames": records})
        clips.append((name, title, frames, duration))
    output.mkdir(parents=True, exist_ok=True)
    if previous_rows is not None:
        assert atlas.crop((0, 0, CELL[0] * 8, CELL[1] * 4)).tobytes() == previous_rows.tobytes(), "Earlier mage action pixels changed"
    atlas.save(output / "spritesheet.png")
    (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    (output / "atlas-qa.json").write_text(json.dumps(qa, ensure_ascii=False, indent=2) + "\n")
    if original_hash is not None:
        assert hashlib.sha256(base.read_bytes()).hexdigest() == original_hash, "Base atlas changed"
    preview.mkdir(parents=True, exist_ok=True)
    bg = "#f3eee5"
    for name, _, frames, duration in clips:
        images = []
        for frame in frames:
            image = Image.new("RGB", (288, 312), bg)
            sprite = frame.resize(image.size, Image.Resampling.LANCZOS)
            image.paste(sprite, (0, 0), sprite)
            images.append(image)
        images[0].save(preview / (name + ".gif"), save_all=True, append_images=images[1:],
                       duration=round(duration * 1000), loop=0)
    contact = Image.new("RGB", atlas.size, bg)
    contact.paste(atlas, (0, 0), atlas)
    contact.resize((atlas.width // 2, atlas.height // 2), Image.Resampling.LANCZOS).save(preview / "contact-sheet.jpg", quality=95)
    montage = []
    columns = 2 if len(clips) == 4 else 3
    canvas_size = (columns * 320, ((len(clips) + columns - 1) // columns) * 360 + 70)
    title_font, label_font = font(27), font(23)
    for index in range(48):
        canvas = Image.new("RGB", canvas_size, bg)
        draw = ImageDraw.Draw(canvas)
        draw.text((canvas_size[0] // 2, 25), heading, font=title_font, fill="#302a2a", anchor="mm")
        for n, (_, title, frames, duration) in enumerate(clips):
            which = int((index * 0.1) / duration) % len(frames)
            sprite = frames[which].resize((288, 312), Image.Resampling.LANCZOS)
            x, y = (n % columns) * 320 + 16, (n // columns) * 360 + 52
            canvas.paste(sprite, (x, y), sprite)
            draw.text(((n % columns) * 320 + 160, y + 328), title, font=label_font, fill="#554c44", anchor="mm")
        montage.append(canvas)
    montage[0].save(preview / "new-actions.png")
    montage[0].save(preview / "new-actions.gif", save_all=True, append_images=montage[1:],
                    duration=100, loop=0, optimize=True)
    print("PASS: %d extra clips, %d safe frames, %dx%d RGBA; base atlas unchanged" %
          (len(specs), sum(s[2] for s in specs), atlas.width, atlas.height))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("preview", type=Path)
    parser.add_argument("--kind", choices=["mage", "sword"], default="mage")
    parser.add_argument("--storm-source", type=Path, help="Append the separately generated eight-frame Cumulonimbus sheet")
    args = parser.parse_args()
    pack(args.source, args.output, args.preview, args.kind, args.storm_source)

