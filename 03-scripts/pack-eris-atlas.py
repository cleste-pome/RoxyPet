#!/usr/bin/env python3
"""Pack separate transparent action sheets without discarding detached body parts.

Requires Pillow and numpy. Source sheets have two rows; the runtime has 11 rows.
All alpha components are assigned whole to a grid cell, including disconnected
legs, shoes, and fine hair. A grid line never cuts through a component.
"""
import argparse
import json
from pathlib import Path
import numpy as np
from PIL import Image

STATES = [('idle', 6), ('running-right', 8), ('running-left', 8),
          ('waving', 4), ('jumping', 6), ('failed', 8), ('waiting', 6),
          ('running', 6), ('review', 6), ('look-row-9', 8), ('look-row-10', 8)]
CELL = (384, 416)
BASELINE = 404


def split_sheet(image, count):
    """Run-length connected components, preserving every visible alpha component (alpha >= 16)."""
    rgba = np.array(image.convert('RGBA'))
    h, w = rgba.shape[:2]
    # Suppress only the nearly invisible PNG fringe, never isolated body parts.
    rgba[rgba[:, :, 3] < 16] = 0
    cols = count // 2
    parent, spans, previous = [], [], []

    def root(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for y in range(h):
        occupied = rgba[y, :, 3] > 0
        edges = np.flatnonzero(np.diff(np.r_[False, occupied, False]))
        current = []
        for left, right in zip(edges[::2], edges[1::2]):
            label = len(parent)
            parent.append(label)
            for pl, pr, pi in previous:
                if pr < left:
                    continue
                if pl > right:
                    break
                parent[root(pi)] = root(label)
            current.append((int(left), int(right), label))
            spans.append((y, int(left), int(right), label))
        previous = current
    bounds = {}
    for y, l, r, label in spans:
        key = root(label)
        if key not in bounds:
            bounds[key] = [l, y, r, y + 1, r - l]
        else:
            b = bounds[key]
            b[0], b[1], b[2], b[3] = min(b[0], l), min(b[1], y), max(b[2], r), max(b[3], y + 1)
            b[4] += r - l
    owners = {}
    for key, (l, t, r, b, area) in bounds.items():
        if area > 100 and (r-l > w/cols*1.45 or b-t > h*.65):
            raise ValueError(f'Connected neighbouring figures: {(l,t,r,b)}; repair source sheet')
        col = min(cols - 1, int((l+r)/2 / (w/cols)))
        row = min(1, int((t+b)/2 / (h/2)))
        owners[key] = row * cols + col
    groups = [np.zeros_like(rgba) for _ in range(count)]
    for y, l, r, label in spans:
        groups[owners[root(label)]][y, l:r] = rgba[y, l:r]
    result = []
    for i, pixels in enumerate(groups):
        sprite = Image.fromarray(pixels)
        bbox = sprite.getbbox()
        if bbox is None:
            raise ValueError(f'Empty source frame {i}')
        result.append((sprite.crop(bbox), bbox))
    assert sum(np.count_nonzero(np.array(s[0])[:, :, 3]) for s in result) == np.count_nonzero(rgba[:, :, 3])
    return result


def pack(source_dir, output_dir, partial=False):
    atlas = Image.new('RGBA', (CELL[0]*8, CELL[1]*11))
    report = {'cell': CELL, 'atlas': atlas.size, 'states': []}
    frame_root = source_dir.parent / 'frames'
    for row, (name, count) in enumerate(STATES):
        path = source_dir / f'{name}.png'
        if not path.exists() and partial:
            continue
        source = Image.open(path).convert('RGBA')
        pieces = split_sheet(source, count)
        lifts = [0, 24, 40, 20, 0, 0] if name == 'jumping' else [0]*count
        # One scale for the entire action, never separately stretch individual frames.
        scale = min(1.0, *(368/im.width for im, _ in pieces),
                    *((BASELINE-10-lift)/im.height for (im, _), lift in zip(pieces, lifts)))
        records = []
        folder = frame_root / name
        folder.mkdir(parents=True, exist_ok=True)
        for col, ((sprite, bbox), lift) in enumerate(zip(pieces, lifts)):
            size = (round(sprite.width*scale), round(sprite.height*scale))
            scaled = sprite.resize(size, Image.Resampling.LANCZOS)
            frame = Image.new('RGBA', CELL)
            xy = ((CELL[0]-size[0])//2, BASELINE-lift-size[1])
            frame.alpha_composite(scaled, xy)
            frame.save(folder / f'{col:02}.png')
            used = name != 'jumping' or col < 5
            if used:
                atlas.alpha_composite(frame, (col*CELL[0], row*CELL[1]))
            out_bbox = frame.getbbox()
            assert out_bbox[0] >= 4 and out_bbox[1] >= 4 and out_bbox[2] <= CELL[0]-4 and out_bbox[3] <= CELL[1]-4
            records.append({'frame': col, 'source_bbox': bbox, 'output_bbox': out_bbox,
                            'scale': scale, 'baseline': BASELINE-lift, 'runtime': used})
        report['states'].append({'name': name, 'source_size': source.size, 'frames': records})
    output_dir.mkdir(parents=True, exist_ok=True)
    atlas.save(output_dir / 'spritesheet.png')
    (output_dir / 'atlas-qa.json').write_text(json.dumps(report, indent=2)+'\n')
    print(f'{output_dir}: {len(report["states"])} states, {atlas.size}, no source upsampling')


def regression_check():
    image = Image.new('RGBA', (120, 120))
    # Two figures whose detached feet cross the nominal horizontal grid line.
    for y0 in (3, 67):
        for y in range(y0, y0+35):
            for x in range(40, 80): image.putpixel((x,y),(200,40,20,255))
        for y in range(y0+40, min(y0+52,120)):
            for x in (42,43,44,74,75,76): image.putpixel((x,y),(255,255,255,255))
    pieces = split_sheet(image, 2)
    assert len(pieces)==2 and all(p[0].height==52 for p in pieces)
    print('PASS: disconnected feet and both figures retained with exact alpha coverage')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source_dir', type=Path, nargs='?')
    parser.add_argument('output_dir', type=Path, nargs='?')
    parser.add_argument('--partial', action='store_true', help='QA only: skip ungenerated sheets')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        regression_check()
    else:
        if not args.source_dir or not args.output_dir: parser.error('source_dir and output_dir required')
        pack(args.source_dir, args.output_dir, args.partial)
