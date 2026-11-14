"""Generate Puffle's vector-derived Play graphics. Screenshots are rendered from app widgets separately."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import os, math
ROOT=Path(__file__).resolve().parent.parent
OUT=ROOT/'play-console-assets'
OUT.mkdir(exist_ok=True)
def font(n,bold=False):
 for p in [os.getenv('PLAY_FONT',''), '/usr/share/fonts/truetype/dejavu/DejaVuSans'+('-Bold' if bold else '')+'.ttf', 'C:/Windows/Fonts/arial'+('bd' if bold else '')+'.ttf']:
  if p and Path(p).exists(): return ImageFont.truetype(p,n)
 return ImageFont.load_default()
def icon(n):
 im=Image.new('RGB',(n,n)); px=im.load()
 for y in range(n):
  for x in range(n):
   t=(x+y)/(2*(n-1)); px[x,y]=tuple(round(a+(b-a)*t) for a,b in zip((19,157,148),(17,69,95)))
 d=ImageDraw.Draw(im); q=lambda b:tuple(round(v*n/108) for v in b)
 d.rounded_rectangle(q((26,47,82,73)),radius=13*n/108,fill='white')
 d.ellipse(q((34,32,66,64)),fill='white'); d.ellipse(q((53,40,77,64)),fill='white')
 d.polygon([(49*n/108,46*n/108),(49*n/108,65*n/108),(65*n/108,55.5*n/108)],fill=(19,119,129))
 return im
icon(512).save(OUT/'app_icon_512.png'); icon(1024).save(OUT/'app_icon_1024.png')
svg='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108"><defs><linearGradient id="g" x2="1" y2="1"><stop stop-color="#139d94"/><stop offset="1" stop-color="#11455f"/></linearGradient></defs><path fill="url(#g)" d="M0 0h108v108H0z"/><g fill="white"><rect x="26" y="47" width="56" height="26" rx="13"/><circle cx="50" cy="48" r="16"/><circle cx="65" cy="52" r="12"/></g><path fill="#137781" d="M49 46v19l16-9.5z"/></svg>'
(OUT/'app_icon_source.svg').write_text(svg)
im=Image.new('RGB',(1024,500)); d=ImageDraw.Draw(im)
for y in range(500):
 for x in range(1024):
  t=(x+y)/1524; im.putpixel((x,y),tuple(round(a+(b-a)*t) for a,b in zip((8,21,29),(17,69,78))))
d=ImageDraw.Draw(im)
d.text((58,55),'PUFFLE',font=font(14,True),fill='#71e3d0',stroke_width=0)
d.text((54,115),'Your cloud.',font=font(60,True),fill='white')
d.text((54,192),'Your channels.',font=font(60,True),fill='white')
d.text((58,296),'Private storage. Videos you love.',font=font(22),fill='#b8d0d6')
d.text((58,343),'All in one place.',font=font(22),fill='#b8d0d6')
im.paste(icon(256),(720,119)); im.save(OUT/'feature_graphic_1024x500.png')
# Clearly synthetic, non-personal sample artwork for real app widget screenshots.
CAPTURE=ROOT/'mobile'/'store-capture'; CAPTURE.mkdir(exist_ok=True)
for i,c in enumerate(['#257f88','#c58b42','#7d6298','#4b8b65','#4479a1','#ab6666']):
 art=Image.new('RGB',(480,720),c); a=ImageDraw.Draw(art)
 a.ellipse((-110,300,470,880),fill='#183740'); a.ellipse((140,-90,600,370),fill='#ffffff18' if False else '#afd7ca')
 a.rounded_rectangle((42,230,338,510),radius=28,outline='#ffffff',width=5)
 a.polygon([(166,310),(166,430),(258,370)],fill='white')
 art.save(CAPTURE/f'poster_{i}.png')
