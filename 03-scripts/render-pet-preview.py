#!/usr/bin/env python3
"""Render any configured character's animation previews. Requires Pillow."""
import argparse
import json
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
BG = '#f3eee5'
ANIMATIONS = {
    'idle': ([(0,c) for c in [0,1,2,3,4,5,0]], [1800,60,50,100,50,60,1000]),
    'run': ([(1,c) for c in range(8)], [120]*8),
    'run-left': ([(2,c) for c in range(8)], [120]*8),
    'wave': ([(3,c) for c in [0,1,2,3,2,1,0]], [140]*6+[600]),
    'jump': ([(4,c) for c in range(5)], [140]*4+[500]),
    'failed': ([(5,c) for c in range(8)], [180]*7+[600]),
    'waiting': ([(6,c) for c in range(6)], [220]*5+[600]),
    'work': ([(7,c) for c in range(6)], [120]*5+[1220]),
    'review': ([(8,c) for c in range(6)], [200]*5+[600]),
    'look': ([(9+d//8,d%8) for d in range(16)], [220]*16),
}


def frame(sheet, row, col):
    w,h = sheet.width//8, sheet.height//11
    return sheet.crop((col*w,row*h,(col+1)*w,(row+1)*h))


def composite(im, size):
    out = Image.new('RGB',size,BG)
    im = im.resize(size,Image.Resampling.LANCZOS)
    out.paste(im,(0,0),im)
    return out


def render(character_id, output):
    folder = ROOT/'02-assets/characters'/character_id
    profile = json.loads((folder/'character.json').read_text())
    sheet = Image.open(folder/profile['atlas']).convert('RGBA')
    output.mkdir(parents=True,exist_ok=True)
    frame(sheet,0,0).save(output/'standing.png')
    for name,(cells,durations) in ANIMATIONS.items():
        # 288x312 physical pixels represents the 144x156 point window on Retina.
        images = [composite(frame(sheet,r,c),(288,312)) for r,c in cells]
        images[0].save(output/f'{name}.gif',save_all=True,append_images=images[1:],
                       duration=durations,loop=0)
    composite(sheet,(1536,2288)).save(output/'contact-sheet.jpg',quality=94)
    identities = ['roxy', 'roxy-nohat', 'eris-short', 'eris-long', 'sylphie-adult', 'sylphie-chibi']
    identities = [i for i in identities if (ROOT/'02-assets/characters'/i/'spritesheet.png').exists()]
    if character_id not in identities: identities.append(character_id)
    canvas = Image.new('RGB',(330*len(identities),440),BG)
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.load_default()
    for path in ['/System/Library/Fonts/PingFang.ttc', '/System/Library/Fonts/STHeiti Light.ttc']:
        try:
            font = ImageFont.truetype(path,22)
            break
        except OSError:
            continue
    for i,identity in enumerate(identities):
        directory = ROOT/'02-assets/characters'/identity
        info = json.loads((directory/'character.json').read_text())
        image = Image.open(directory/info['atlas']).convert('RGBA')
        sprite = frame(image,0,0).resize((288,312),Image.Resampling.LANCZOS)
        canvas.paste(sprite,(i*330+21,24),sprite)
        draw.text((i*330+165,365),info['name'],font=font,fill='#302a2a',anchor='mm')
        draw.text((i*330+165,402),info['appearance'],font=font,fill='#746a65',anchor='mm')
    canvas.save(output/'comparison.png')
    print(f'Rendered {profile["name"]}: {len(ANIMATIONS)} animations, contact sheet, Retina comparison')


if __name__=='__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('character_id')
    parser.add_argument('output',type=Path)
    args = parser.parse_args()
    render(args.character_id,args.output)
