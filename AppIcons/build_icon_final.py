#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成「识记AI」应用图标与 Logo（记 字标 + 苹果绿渐变）。
输出：
  AppIcon_识记AI.png        1024 主图（含 AI 火花）
  AppIcon_识记AI_plain.png  1024 主图（无火花，极简）
  Logo_识记AI_horizontal.png 图标 + 识记AI 字样 横向 lockup (1536x512)
  Logo_识记AI.svg           矢量源（圆角标记 + 字样）
依赖：Pillow + numpy + 系统中文字体（Hiragino Sans GB）。
"""
import os
import math
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

S = 1024
OUT = os.path.dirname(os.path.abspath(__file__))

# ---------- 调色板（与工程 build_icons.py 一致）----------
GREEN_TOP    = (52, 199, 89)    # 34C759 苹果系统绿（顶）
GREEN_BOTTOM = (26, 174, 84)    # 1AAE54 苹果绿（底，略深）
WHITE = (255, 255, 255)
INK_SHADOW = (20, 60, 120)

FONT_PATH = "/System/Library/Fonts/Hiragino Sans GB.ttc"
# 方方正正字体：华文黑体（Heiti TC = 繁体字面，index 0），用于「記」字标
STHEITI = "/System/Library/Fonts/STHeiti Medium.ttc"

def vgrad(top, bottom, h=S):
    t = np.array(top, float); b = np.array(bottom, float)
    f = np.linspace(0, 1, h)[:, None]
    arr = t[None, :] * (1 - f) + b[None, :] * f
    arr = np.repeat(arr[:, None, :], S, axis=1)
    arr = np.concatenate([arr, np.full((S, S, 1), 255, dtype=np.uint8)], axis=2)
    return arr.astype(np.uint8)

def round_mask(radius):
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, S - 1, S - 1], radius=radius, fill=255)
    return m

def load_font(size, index=0):
    return ImageFont.truetype(FONT_PATH, size, index=index)

def sparkle(draw, cx, cy, r, color):
    """4 角星（火花/魔法），r=外半径。"""
    points = []
    outer = r
    inner = r * 0.34
    for i in range(8):
        ang = math.pi / 2 * i / 2 - math.pi / 2  # 从正上方开始
        rad = outer if i % 2 == 0 else inner
        points.append((cx + rad * math.cos(ang), cy + rad * math.sin(ang)))
    draw.polygon(points, fill=color)

def render_icon(with_sparkle=True, radius=234, ai_label=False):
    img = Image.fromarray(vgrad(GREEN_TOP, GREEN_BOTTOM), "RGBA")
    # 轻微顶部高光（更通透）
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([120, 60, S - 120, 520], fill=(255, 255, 255, 38))
    glow = glow.filter(ImageFilter.GaussianBlur(120))
    img = Image.alpha_composite(img, glow)

    # 字标「記」（繁体），方方正正字体：华文黑体 Medium（Heiti TC）
    font = ImageFont.truetype(STHEITI, 620, index=0)
    # 柔和投影
    sd = ImageDraw.Draw(img)
    sd.text((S // 2, S // 2 + 10), "記", font=font, fill=INK_SHADOW + (90,), anchor="mm")
    # 主体白字
    d = ImageDraw.Draw(img)
    d.text((S // 2, S // 2), "記", font=font, fill=WHITE, anchor="mm")

    if with_sparkle:
        # 右上小火花（AI 魔法感），克制；缩为 AI 字标左下角的小装饰
        sparkle(d, 700, 290, 32, WHITE)
        if ai_label:
            # AI 字标紧贴右上角圆角内沿（在裁切区内但不超出）
            # 用 W6 粗体（index=2）避免小字号显单薄
            f_ai = ImageFont.truetype(FONT_PATH, 100, index=2)
            d.text((832, 226), "AI", font=f_ai, fill=WHITE, anchor="mm")
        else:
            # 火花旁两个小点（原装饰）
            d.ellipse([648, 250, 666, 268], fill=WHITE)
            d.ellipse([760, 360, 774, 374], fill=WHITE)

    # 圆角遮罩
    mask = round_mask(radius)
    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out

def render_logo_horizontal():
    W, H = 1536, 512
    canvas = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    # 左侧图标 384x384 居中（圆角）
    icon = render_icon(with_sparkle=True, radius=88).resize((384, 384), Image.LANCZOS)
    canvas.paste(icon, (64, 64), icon)
    # 右侧文字「识记AI」
    d = ImageDraw.Draw(canvas)
    # 记 用中文圆体（W3），AI 用同字号 W6 粗体保持与图标一致
    f_cn = load_font(232)
    f_en = ImageFont.truetype(FONT_PATH, 232, index=2)
    # 文字左对齐起点 x=520；"识记" 中文 + "AI" 英文
    d.text((520, 256), "识记", font=f_cn, fill=(23, 42, 78), anchor="lm")
    # 测量"识记"宽度以接排 AI
    w = d.textlength("识记", font=f_cn)
    d.text((520 + w + 18, 256), "AI", font=f_en, fill=GREEN_TOP, anchor="lm")
    return canvas

if __name__ == "__main__":
    icon = render_icon(with_sparkle=False, ai_label=True)
    icon.save(os.path.join(OUT, "AppIcon_识记AI.png"))
    plain = render_icon(with_sparkle=False, ai_label=False)
    plain.save(os.path.join(OUT, "AppIcon_识记AI_plain.png"))
    logo = render_logo_horizontal()
    logo.save(os.path.join(OUT, "Logo_识记AI_horizontal.png"))

    # SVG 矢量源（标记渐变 + 文本；中文字体依赖查看器，PNG 为可靠交付物）
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="g" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#34C759"/>
      <stop offset="1" stop-color="#1AAE54"/>
    </linearGradient>
    <clipPath id="r"><rect x="0" y="0" width="1024" height="1024" rx="234" ry="234"/></clipPath>
  </defs>
  <g clip-path="url(#r)">
    <rect x="0" y="0" width="1024" height="1024" fill="url(#g)"/>
    <text x="512" y="512" font-family="Heiti TC, STHeiti Medium, sans-serif" font-size="620"
          font-weight="700" fill="#FFFFFF" text-anchor="middle" dominant-baseline="central">記</text>
    <g fill="#FFFFFF">
      <path d="M700 258 L707.7 280.3 L732 290 L707.7 299.7 L700 322 L692.3 299.7 L668 290 L692.3 280.3 Z"/>
      <text x="832" y="226" font-family="Hiragino Sans GB, PingFang SC, sans-serif" font-size="100"
            font-weight="600" fill="#FFFFFF" text-anchor="middle" dominant-baseline="central">AI</text>
    </g>
  </g>
</svg>'''
    with open(os.path.join(OUT, "Logo_识记AI.svg"), "w", encoding="utf-8") as f:
        f.write(svg)
    print("OK →", [f for f in os.listdir(OUT) if f.startswith(("AppIcon_", "Logo_"))])
