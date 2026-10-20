#!/usr/bin/env python3
"""生成「校园网一键连接」app 图标 -> 与本脚本同目录的 app.icns

需要 Pillow:  python3 -m pip install pillow
"""
import math, os, shutil
from PIL import Image, ImageDraw, ImageFilter

S = 4096          # 超采样画布
OUT = os.path.dirname(os.path.abspath(__file__))
os.makedirs(OUT, exist_ok=True)

# ---------- 背景：圆角矩形 + 竖向渐变 ----------
def rounded_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m

# 深大标准色「荔枝红」PANTONE 208C / C10 M97 Y37 K43 ≈ #861f41
# 上浅下深做一点渐变，避免大色块在桌面上发闷
top = (154, 42, 77)      # #9a2a4d
bot = (92, 18, 48)       # #5c1230
grad = Image.new("RGB", (S, S))
gd = ImageDraw.Draw(grad)
for y in range(S):
    t = y / (S - 1)
    t = t ** 0.85
    gd.line([(0, y), (S, y)], fill=tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)))

content_size = 3300                 # 内容区（留边距给桌面观感）
off = (S - content_size) // 2
radius = int(content_size * 0.225)  # macOS 圆角比例

body = grad.crop((off, off, off + content_size, off + content_size))
mask = rounded_mask(content_size, radius)

canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# 柔和投影
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shadow.paste(Image.new("RGBA", (content_size, content_size), (0, 0, 0, 90)), (off, off + 40), mask)
canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(60)))

body_rgba = body.convert("RGBA")
body_rgba.putalpha(mask)
canvas.paste(body_rgba, (off, off), body_rgba)

d = ImageDraw.Draw(canvas)

# 顶部高光
hl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
hd = ImageDraw.Draw(hl)
hd.ellipse([off - 900, off - 1900, off + content_size + 900, off + 1300],
           fill=(255, 205, 215, 30))
hl = hl.filter(ImageFilter.GaussianBlur(200))
full_mask = Image.new("L", (S, S), 0)
full_mask.paste(mask, (off, off))
hl.putalpha(Image.composite(hl.getchannel("A"), Image.new("L", (S, S), 0), full_mask))
canvas = Image.alpha_composite(canvas, hl)
d = ImageDraw.Draw(canvas)

# ---------- WiFi 符号 ----------
cx = S / 2
cy = off + content_size * 0.665          # 圆弧圆心（符号变大后相应上移，保持视觉居中）

def thick_arc(draw, cx, cy, r, w, a0, a1, fill):
    """沿弧线密集布点画圆，得到带圆头的粗弧"""
    sweep = math.radians(a1 - a0)
    n = max(2, int(r * sweep / 3))
    for i in range(n + 1):
        a = math.radians(a0) + sweep * i / n
        x = cx + r * math.cos(a)
        y = cy + r * math.sin(a)
        draw.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=fill)

rings = [(0.375, 0.056), (0.245, 0.056), (0.115, 0.056)]   # (半径比, 线宽比) 外->内
# 线宽保持 0.056 不变，把三条弧整体往外推开：半径间隔 0.130 → 净空隙 0.074，
# 原来只有 0.044。靠"符号变大"换空间，而不是把线削细。
for rr, ww in rings:
    thick_arc(d, cx, cy, content_size * rr, content_size * ww, 228, 312, (255, 255, 255, 255))

# 中心圆点
dot = content_size * 0.042
d.ellipse([cx - dot, cy - dot, cx + dot, cy + dot], fill=(255, 255, 255, 255))

master = canvas.resize((1024, 1024), Image.LANCZOS)
master.save(f"{OUT}/icon_1024.png")

# ---------- 生成 .iconset ----------
iconset = f"{OUT}/app.iconset"
shutil.rmtree(iconset, ignore_errors=True)
os.makedirs(iconset)
for sz in [16, 32, 64, 128, 256, 512]:
    master.resize((sz, sz), Image.LANCZOS).save(f"{iconset}/icon_{sz}x{sz}.png")
    master.resize((sz * 2, sz * 2), Image.LANCZOS).save(f"{iconset}/icon_{sz}x{sz}@2x.png")
print("iconset done:", len(os.listdir(iconset)), "files")
