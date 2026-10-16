#!/usr/bin/env python3
"""Render packaged sprite frames for README and visual QA (requires Pillow)."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / '05-images/eris'
OUT.mkdir(parents=True, exist_ok=True)
BG = '#f3eee5'

def frame(sheet, row, col):
    w,h=sheet.width//8,sheet.height//11
    return sheet.crop((col*w, row*h, (col+1)*w, (row+1)*h))

def display(im, size=(192,208)):
    out = Image.new('RGB', size, BG)
    im = im.resize(size, Image.Resampling.LANCZOS)
    out.paste(im, (0,0), im)
    return out

for variant in ('short', 'long'):
    sheet = Image.open(ROOT / f'02-assets/characters/eris-{variant}/spritesheet.png').convert('RGBA')
    frame(sheet,0,0).save(OUT / f'{variant}-standing.png')
    animations = {
        'idle': ([(0, c) for c in [0,1,2,3,4,5,0]], [1800,60,50,100,50,60,1000]),
        'run': ([(1, c) for c in range(8)], [120]*7+[220]),
        'wave': ([(3, c) for c in [0,1,2,3,2,1,0]], [140]*6+[600]),
        'jump': ([(4, c) for c in range(5)], [140]*4+[500]),
        'look': ([(9+d//8,d%8) for d in range(16)], [220]*16),
    }
    for name, (cells, durations) in animations.items():
        images=[display(frame(sheet,r,c)) for r,c in cells]
        images[0].save(OUT/f'{variant}-{name}.gif', save_all=True, append_images=images[1:], duration=durations, loop=0)
    # Render all cells at their runtime size on a light background, to reveal crop or alpha defects.
    qa=Image.new('RGB',(1536,2288),BG)
    preview = sheet.resize(qa.size, Image.Resampling.LANCZOS)
    qa.paste(preview,(0,0),preview)
    qa.save(OUT/f'{variant}-contact-sheet.jpg',quality=90)

canvas=Image.new('RGB',(990,580), BG)
draw=ImageDraw.Draw(canvas)
font=None
for path in ['/System/Library/Fonts/PingFang.ttc', '/System/Library/Fonts/STHeiti Light.ttc']:
    try:
        font=ImageFont.truetype(path,24);break
    except OSError:pass
font=font or ImageFont.load_default()
small=ImageFont.truetype(font.path,18) if hasattr(font,'path') else font
for i,(name,detail,path) in enumerate([
    ('洛琪希','魔法师',ROOT/'02-assets/spritesheet.png'),
    ('艾丽丝','短发 · 旅行装',ROOT/'02-assets/characters/eris-short/spritesheet.png'),
    ('艾丽丝','长发 · 连衣裙',ROOT/'02-assets/characters/eris-long/spritesheet.png')]):
    sheet=Image.open(path).convert('RGBA')
    sprite=frame(sheet,0,0).resize((288,312),Image.Resampling.LANCZOS)
    x=i*330+21
    canvas.paste(sprite,(x,100),sprite)
    draw.text((i*330+165,455),name,font=font,fill='#302a2a',anchor='mm')
    draw.text((i*330+165,493),detail,font=small,fill='#746a65',anchor='mm')
draw.text((495,42),'RoxyPet · 桌面伙伴',font=font,fill='#302a2a',anchor='mm')
canvas.save(OUT/'characters.png')
print('Rendered static comparison and ten animation previews.')
