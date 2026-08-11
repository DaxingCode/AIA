#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""好记AI 图标 v4：下栏改为整句文案「自动记账记待办 / 管理饮食和健康」。
只出这一张，不动 v1/v2/v3。
"""
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFont

S = 1024
OUT = os.path.dirname(os.path.abspath(__file__))
GREEN_TOP    = (52, 199, 89)    # 34C759 苹果系统绿（顶）
GREEN_BOTTOM = (26, 174, 84)    # 1AAE54 苹果绿（底，略深）
WHITE = (255, 255, 255)
INK = (20, 60, 120)
STHEITI_M = "/System/Library/Fonts/STHeiti Medium.ttc"
STHEITI_L = "/System/Library/Fonts/STHeiti Light.ttc"


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


img = Image.fromarray(vgrad(GREEN_TOP, GREEN_BOTTOM), "RGBA")
d = ImageDraw.Draw(img)

# 上：好记AI（放大版）。好记 与 AI 拆开、按基线(anchor=ls)对齐，
# 避免中英文混排时 AI 视觉偏上。
f_top = ImageFont.truetype(STHEITI_M, 300, index=1)
w_haoji = d.textlength("好记", font=f_top)
w_ai = d.textlength("AI", font=f_top)
total_w = w_haoji + w_ai
x_start = 512 - total_w / 2
base_y = 439  # 好记 基线（整块垂直中心≈356）
AI_DROP = 14   # AI 相对「好记」基线再下沉的像素
# 投影
d.text((x_start, base_y + 10), "好记", font=f_top, fill=INK + (90,), anchor="ls")
d.text((x_start + w_haoji, base_y + AI_DROP + 10), "AI", font=f_top, fill=INK + (90,), anchor="ls")
# 主体白字
d.text((x_start, base_y), "好记", font=f_top, fill=WHITE, anchor="ls")
d.text((x_start + w_haoji, base_y + AI_DROP), "AI", font=f_top, fill=WHITE, anchor="ls")

# 分隔线
d.line([(140, 512), (884, 512)], fill=(255, 255, 255, 95), width=3)

# 下：两整句（8 字一行，font 放大以适配宽度，行间距拉开避免撞行）
f_mod = ImageFont.truetype(STHEITI_L, 120, index=1)
d.text((512, 622), "自动记账记待办", font=f_mod, fill=WHITE, anchor="mm")
d.text((512, 782), "管理饮食和健康", font=f_mod, fill=WHITE, anchor="mm")

mask = round_mask(234)
out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
out.paste(img, (0, 0), mask)

fn = "AppIcon_好记AI_v4.png"
out.save(os.path.join(OUT, fn))
# 120px 小尺寸预览
out.resize((120, 120), Image.LANCZOS).save(
    os.path.join(OUT, "AppIcon_好记AI_v4_small.png")
)
print("OK", fn, "+ small")
