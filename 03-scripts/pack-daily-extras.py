#!/usr/bin/env python3
"""Pack generated 4x3 everyday action sheets; preserve all base atlases."""
from pathlib import Path
import hashlib, importlib.util, json
from PIL import Image
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('splitter',ROOT/'03-scripts/pack-eris-atlas.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
art=ROOT/'06-art-source/daily-actions/2026-10-30'
for c in ['roxy-nohat','sylphie-adult','sylphie-chibi']:
 base=ROOT/'02-assets/characters'/c/'spritesheet.png';before=hashlib.sha256(base.read_bytes()).hexdigest()
 source=art/c/'source.png';im=Image.open(source).convert('RGBA');pieces=m.split_sheet(im,12,rows=3)
 scale=min(1.,*[368/x.width for x,_ in pieces],*[394/x.height for x,_ in pieces])
 atlas=Image.new('RGBA',(3072,1248));manifest={'version':1,'columns':8,'rows':3,'cellWidth':384,'cellHeight':416,'actions':[]}
 qa={'tool':'built-in image_gen','source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'base_sha256':before,'frames':[]}
 preview=ROOT/'05-images/daily-actions'/c;preview.mkdir(parents=True,exist_ok=True)
 for row,(id,title) in enumerate([('daily-rest','整理衣袖'),('daily-focus','托腮思考'),('daily-greet','点头致意')]):
  frames=[]
  for col in range(4):
   sprite,bounds=pieces[row*4+col];scaled=sprite.resize((round(sprite.width*scale),round(sprite.height*scale)),Image.Resampling.LANCZOS)
   frame=Image.new('RGBA',(384,416));frame.alpha_composite(scaled,((384-scaled.width)//2,404-scaled.height));box=frame.getbbox()
   assert box and box[0]>=4 and box[1]>=4 and box[2]<=380 and box[3]<=412
   atlas.alpha_composite(frame,(col*384,row*416));out=art/c/'frames'/id;out.mkdir(parents=True,exist_ok=True);frame.save(out/f'{col:02}.png')
   qa['frames'].append({'action':id,'col':col,'source_bbox':bounds,'output_bbox':box,'scale':scale})
   bg=Image.new('RGB',(384,416),'#f3eee5');bg.paste(frame,(0,0),frame);frames.append(bg)
  frames[0].save(preview/(id+'.gif'),save_all=True,append_images=frames[1:],duration=350,loop=0)
  manifest['actions'].append({'id':id,'title':title,'row':row,'frameCount':4,'frameDuration':.35})
 output=base.parent/'actions';output.mkdir(exist_ok=True)
 atlas.save(output/'spritesheet.png');(output/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n');(output/'atlas-qa.json').write_text(json.dumps(qa,indent=2)+'\n')
 light=Image.new('RGB',atlas.size,'#f3eee5');light.paste(atlas,(0,0),atlas);light.crop((0,0,1536,1248)).resize((768,624)).save(preview/'contact.jpg')
 assert hashlib.sha256(base.read_bytes()).hexdigest()==before
 print('PASS',c,'3 independent actions / 12 full frames; base unchanged')
