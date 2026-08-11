#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""识记AI 图标/Logo：将「记」换成繁体「記」，并对比方方正正字体候选。
输出多张 variant PNG 供挑选（不直接改工程资产）。
"""
import os
import math
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

S = 1024
OUT = os.path.dirname(os.path.abspath(__file__))
BLUE = (55, 138, 221)      # 378ADD
CYAN = (56, 189, 248)      # 38BDF8
WHITE = (255, 255, 255)
INK_SHADOW = (20, 60, 120)

HIRA = "/System/Library/Fonts/Hiragino Sans GB.ttc"
STHEITI_M = "/System/Library/Fonts/STHeiti Medium.ttc"   # index0=Heiti TC(繁) Medium
STHEITI_L = "/System/Library/Fonts/STHeiti Light.ttc"    # index0=Heiti TC(繁) Light


def vgrad(top, bottom, h=S):
    t = np.array(top, float); b = np.array(bottom, float)
    f = np.linspace(0, 1, h)[:, None]
    arr = t[None, :] * (1 - f) + b[None, :] * f
    arr = np.repeat(arr[:, None, :], S, axis=1)
    arr = np.concatenate([arr, np.full((S, S, 1), 255, dtype=np.uint8)], axis=2)
    return arr.astype(np.uint8)


def round_mask(radius):
    m = Image.new("L", (S, S), 0); d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, S - 1, S - 1], radius=radius, fill=255)
    return m


def sparkle(draw, cx, cy, r, color):
    pts = []
    for i in range(8):
        ang = math.pi / 2 * i / 2 - math.pi / 2
        rad = r if i % 2 == 0 else r * 0.34
        pts.append((cx + rad * math.cos(ang), cy + rad * math.sin(ang)))
    draw.polygon(pts, fill=color)


def render_icon(ji_path, ji_idx, ji_size=620):
    img = Image.fromarray(vgrad(BLUE, CYAN), "RGBA")
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0)); gd = ImageDraw.Draw(glow)
    gd.ellipse([120, 60, S - 120, 520], fill=(255, 255, 255, 38))
    glow = glow.filter(ImageFilter.GaussianBlur(120))
    img = Image.alpha_composite(img, glow)

    font = ImageFont.truetype(ji_path, ji_size, index=ji_idx)
    sd = ImageDraw.Draw(img)
    sd.text((S // 2, S // 2 + 10), "記", font=font, fill=INK_SHADOW + (90,), anchor="mm")
    d = ImageDraw.Draw(img)
    d.text((S // 2, S // 2), "記", font=font, fill=WHITE, anchor="mm")

    sparkle(d, 700, 290, 32, WHITE)
    f_ai = ImageFont.truetype(HIRA, 100, index=2)   # AI 用 Hiragino W6 粗体
    d.text((832, 226), "AI", font=f_ai, fill=WHITE, anchor="mm")

    mask = round_mask(234)
    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def render_logo(ji_path, ji_idx):
    W, H = 1536, 512
    canvas = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    icon = render_icon(ji_path, ji_idx).resize((384, 384), Image.LANCZOS)
    canvas.paste(icon, (64, 64), icon)

    d = ImageDraw.Draw(canvas)
    f_cn = ImageFont.truetype(ji_path, 232, index=ji_idx)   # 識記 用同字面
    f_en = ImageFont.truetype(HIRA, 232, index=2)           # AI 用 Hiragino W6
    d.text((520, 256), "識記", font=f_cn, fill=(23, 42, 78), anchor="lm")
    w = d.textlength("識記", font=f_cn)
    d.text((520 + w + 18, 256), "AI", font=f_en, fill=BLUE, anchor="lm")
    return canvas


# 三款图标候选 + 一款 logo 预览（均用繁体「記」）
icon_variants = [
    ("stheiti_medium", STHEITI_M, 0, "华文黑体·中黑（推荐·偏方正）"),
    ("stheiti_light",  STHEITI_L, 0, "华文黑体·细黑（偏方正·更轻）"),
    ("hiragino_w6",     HIRA,     2, "现有 Hiragino 加粗（基线对比）"),
]

for name, path, idx, label in icon_variants:
    im = render_icon(path, idx)
    fn = f"AppIcon_記_{name}.png"
    im.save(os.path.join(OUT, fn))
    print("OK", fn, "—", label)

# logo 预览用推荐的华文黑体·中黑
logo = render_logo(STHEITI_M, 0)
logo.save(os.path.join(OUT, "Logo_記_stheiti_medium.png"))
print("OK Logo_記_stheiti_medium.png — logo 预览（識記AI）")
