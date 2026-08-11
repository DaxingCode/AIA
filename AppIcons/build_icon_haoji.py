#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""好记AI 图标候选：上下分栏（字体加大版）。
上：好记AI   下：记账丨待办丨饮食丨健康
出 3 张大字号效果图 + 同款 120px 小尺寸预览（看真实图标清晰度）。
不直接改工程资产。
"""
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

S = 1024
OUT = os.path.dirname(os.path.abspath(__file__))
BLUE = (55, 138, 221)      # 378ADD
CYAN = (56, 189, 248)      # 38BDF8
WHITE = (255, 255, 255)
INK = (20, 60, 120)
STHEITI_M = "/System/Library/Fonts/STHeiti Medium.ttc"   # index1=Heiti SC(简) Medium
STHEITI_L = "/System/Library/Fonts/STHeiti Light.ttc"    # index1=Heiti SC(简) Light


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


def render(variant):
    img = Image.fromarray(vgrad(BLUE, CYAN), "RGBA")

    # v3：下半部加深蓝面板，分栏更明确
    if variant == "v3":
        pd = ImageDraw.Draw(img)
        pd.rectangle([0, 512, S, S], fill=INK + (54,))

    d = ImageDraw.Draw(img)

    # 上：好记AI（加大）
    f_top = ImageFont.truetype(STHEITI_M, 178, index=1)
    d.text((512, 366), "好记AI", font=f_top, fill=INK + (90,), anchor="mm")
    d.text((512, 356), "好记AI", font=f_top, fill=WHITE, anchor="mm")

    # 分隔线（白，低透明）
    d.line([(140, 512), (884, 512)], fill=(255, 255, 255, 95), width=3)

    # 下：四模块（加大）
    if variant == "v2":
        f_mod = ImageFont.truetype(STHEITI_L, 100, index=1)
        d.text((512, 632), "记账   待办", font=f_mod, fill=WHITE, anchor="mm")
        d.text((512, 742), "饮食   健康", font=f_mod, fill=WHITE, anchor="mm")
    else:
        f_mod = ImageFont.truetype(STHEITI_L, 84, index=1)
        d.text((512, 692), "记账丨待办丨饮食丨健康", font=f_mod, fill=WHITE, anchor="mm")

    mask = round_mask(234)
    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


for v in ["v1", "v2", "v3"]:
    im = render(v)
    fn = f"AppIcon_好记AI_{v}.png"
    im.save(os.path.join(OUT, fn))
    # 真实小尺寸预览（120px，看 app 图标实际清晰度）
    small = im.resize((120, 120), Image.LANCZOS)
    small.save(os.path.join(OUT, f"AppIcon_好记AI_{v}_small.png"))
    print("OK", fn, "+ small")
