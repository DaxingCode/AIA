#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 5 个 iOS App 图标候选（不含 AI 字样）。"""
import math, os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 1024
OUT = os.path.dirname(os.path.abspath(__file__))
os.makedirs(OUT, exist_ok=True)

# ---------- 调色板 ----------
BLUE      = (55, 138, 221)    # 378ADD 科技蓝
BLUE_L    = (86, 165, 240)
BLUE_D    = (33, 96, 176)
CYAN      = (56, 189, 248)
WHITE     = (255, 255, 255)
INK       = (26, 36, 52)
ORANGE    = (255, 159, 67)    # 饮食
PURPLE    = (139, 92, 246)    # 账单
TEAL      = (45, 212, 191)    # 待办
GREEN     = (52, 199, 123)
PINK      = (255, 99, 132)    # 爱心
YELLOW    = (255, 205, 80)
NAVY      = (23, 42, 78)

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def vgrad(top, bottom):
    t = np.array(top, float); b = np.array(bottom, float)
    f = np.linspace(0, 1, S)[:, None]
    arr = t[None, :] * (1 - f) + b[None, :] * f
    arr = np.repeat(arr[:, None, :], S, axis=1)
    arr = np.concatenate([arr, np.full((S, S, 1), 255, dtype=np.uint8)], axis=2)
    return arr.astype(np.uint8)

def new_canvas(bg=None):
    if bg is None:
        return Image.new("RGBA", (S, S), (0, 0, 0, 0))
    if callable(bg):
        return Image.fromarray(bg(), "RGBA")
    return Image.new("RGBA", (S, S), bg + (255,))

def glow_layer(cx, cy, radius, color, max_alpha=180):
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.ellipse([cx - radius, cy - radius, cx + radius, cy + radius], fill=color + (max_alpha,))
    return layer.filter(ImageFilter.GaussianBlur(radius * 0.55))

def add_glow(img, cx, cy, radius, color, max_alpha=180):
    g = glow_layer(cx, cy, radius, color, max_alpha)
    return Image.alpha_composite(img, g)

def round_mask(radius):
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, S - 1, S - 1], radius=radius, fill=255)
    return m

def finalize(img, radius=230):
    """透明圆角预览（系统会再套 squircle 遮罩）。"""
    base = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    base.paste(img, (0, 0), img)
    mask = round_mask(radius)
    base.putalpha(mask)
    return base

def draw_heart(d, cx, cy, scale, color):
    pts = []
    for deg in range(0, 361, 3):
        t = math.radians(deg)
        x = 16 * math.sin(t) ** 3
        y = 13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)
        pts.append((cx + x * scale, cy - y * scale))
    d.polygon(pts, fill=color)

def draw_star4(d, cx, cy, R, r, color):
    pts = []
    for i in range(8):
        ang = -math.pi / 2 + i * math.pi / 4
        rad = R if i % 2 == 0 else r
        pts.append((cx + rad * math.cos(ang), cy + rad * math.sin(ang)))
    d.polygon(pts, fill=color)

def qbezier(p0, p1, p2, n=24):
    pts = []
    for i in range(n + 1):
        t = i / n
        x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0]
        y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1]
        pts.append((x, y))
    return pts

# ============================================================
# 图标 1：熊猫阿宝
# ============================================================
def icon_panda():
    img = new_canvas(lambda: vgrad(BLUE_L, BLUE_D))
    img = add_glow(img, S // 2, S // 2, 360, WHITE, 60)
    d = ImageDraw.Draw(img)
    cx, cy = S // 2, S // 2 + 30
    # 耳朵
    d.ellipse([cx - 250, cy - 300, cx - 70, cy - 120], fill=INK)
    d.ellipse([cx + 70, cy - 300, cx + 250, cy - 120], fill=INK)
    d.ellipse([cx - 220, cy - 280, cx - 100, cy - 160], fill=(60, 70, 86))
    d.ellipse([cx + 100, cy - 280, cx + 220, cy - 160], fill=(60, 70, 86))
    # 脸
    d.ellipse([cx - 270, cy - 250, cx + 270, cy + 290], fill=WHITE)
    # 腮红
    d.ellipse([cx - 230, cy + 70, cx - 130, cy + 150], fill=(255, 160, 175, 150))
    d.ellipse([cx + 130, cy + 70, cx + 230, cy + 150], fill=(255, 160, 175, 150))
    # 黑眼圈
    d.ellipse([cx - 175, cy - 120, cx - 35, cy + 30], fill=INK)
    d.ellipse([cx + 35, cy - 120, cx + 175, cy + 30], fill=INK)
    # 眼睛
    d.ellipse([cx - 150, cy - 80, cx - 80, cy - 10], fill=WHITE)
    d.ellipse([cx + 80, cy - 80, cx + 150, cy - 10], fill=WHITE)
    d.ellipse([cx - 132, cy - 62, cx - 98, cy - 28], fill=INK)
    d.ellipse([cx + 98, cy - 62, cx + 132, cy - 28], fill=INK)
    # 鼻子
    d.ellipse([cx - 42, cy + 35, cx + 42, cy + 92], fill=INK)
    # 嘴巴：自然平和
    d.line([cx, cy + 92, cx, cy + 120], fill=INK, width=12, joint="curve")
    d.arc([cx - 70, cy + 95, cx, cy + 175], start=20, end=160, fill=INK, width=12)
    d.arc([cx, cy + 95, cx + 70, cy + 175], start=20, end=160, fill=INK, width=12)
    return finalize(img)

# ============================================================
# 图标 2：四宫格（饮食/健康/账单/待办）
# ============================================================
def icon_quad():
    img = new_canvas(lambda: vgrad((244, 248, 253), (232, 240, 250)))
    d = ImageDraw.Draw(img)
    pad = 150
    gap = 36
    tile = (S - 2 * pad - gap) // 2
    cells = [
        (pad, pad, ORANGE, "diet"),
        (pad + tile + gap, pad, BLUE, "health"),
        (pad, pad + tile + gap, PURPLE, "bill"),
        (pad + tile + gap, pad + tile + gap, TEAL, "todo"),
    ]
    for (x0, y0, color, kind) in cells:
        d.rounded_rectangle([x0, y0, x0 + tile, y0 + tile], radius=70, fill=color)
        d.rounded_rectangle([x0 + 10, y0 + 10, x0 + tile - 10, y0 + tile - 10],
                            radius=62, fill=lerp(color, WHITE, 0.12))
        cx, cy = x0 + tile // 2, y0 + tile // 2
        if kind == "diet":       # 叶子
            d.ellipse([cx - 60, cy - 80, cx + 50, cy + 60], fill=WHITE)
            d.line([cx + 50, cy + 60, cx - 20, cy - 30], fill=lerp(ORANGE, INK, 0.25), width=14)
        elif kind == "health":   # 心
            draw_heart(d, cx, cy + 20, 9, WHITE)
        elif kind == "bill":     # 圆形 + ¥
            d.ellipse([cx - 75, cy - 75, cx + 75, cy + 75], fill=WHITE)
            d.line([cx, cy - 55, cx, cy + 55], fill=PURPLE, width=16)
            d.line([cx - 42, cy - 28, cx + 42, cy - 28], fill=PURPLE, width=16)
            d.line([cx - 34, cy + 18, cx + 34, cy + 18], fill=PURPLE, width=16)
        else:                    # 勾
            d.line([cx - 55, cy, cx - 10, cy + 50], fill=WHITE, width=22, joint="curve")
            d.line([cx - 10, cy + 50, cx + 70, cy - 45], fill=WHITE, width=22, joint="curve")
    return finalize(img)

# ============================================================
# 图标 3：星标助手（蓝光星 + 完成徽章）
# ============================================================
def icon_sparkle():
    img = new_canvas(lambda: vgrad(BLUE, CYAN))
    img = add_glow(img, S // 2, S // 2, 320, WHITE, 70)
    d = ImageDraw.Draw(img)
    cx, cy = S // 2, S // 2 - 30
    draw_star4(d, cx, cy, 250, 95, WHITE)
    img = add_glow(img, cx, cy, 150, WHITE, 110)
    d = ImageDraw.Draw(img)
    # 完成徽章
    bx, by = cx + 200, cy + 210
    br = 110
    d.ellipse([bx - br, by - br, bx + br, by + br], fill=WHITE)
    d.line([bx - 55, by, bx - 12, by + 46], fill=GREEN, width=26, joint="curve")
    d.line([bx - 12, by + 46, bx + 64, by - 46], fill=GREEN, width=26, joint="curve")
    return finalize(img)

# ============================================================
# 图标 4：守护心盾
# ============================================================
def icon_shield():
    img = new_canvas(lambda: vgrad(BLUE_D, BLUE))
    img = add_glow(img, S // 2, S // 2 - 40, 300, CYAN, 70)
    d = ImageDraw.Draw(img)
    cx = S // 2
    top = 200
    w = 300
    mid_y = 560
    bot_y = 850
    # 盾牌外形（含底部曲线）
    top_pts = [(cx - w, top), (cx + w, top)]
    right = qbezier((cx + w, top), (cx + w + 20, mid_y), (cx, bot_y))
    left = qbezier((cx, bot_y), (cx - w - 20, mid_y), (cx - w, top))
    shield = top_pts + right + left[::-1][1:]
    d.polygon(shield, fill=WHITE)
    d.polygon(shield, outline=lerp(BLUE, WHITE, 0.35), width=10)
    # 盾内爱心
    draw_heart(d, cx, (top + mid_y) // 2 + 30, 11, PINK)
    return finalize(img)

# ============================================================
# 图标 5：宝钻
# ============================================================
def icon_gem():
    img = new_canvas(lambda: vgrad(NAVY, BLUE_D))
    img = add_glow(img, S // 2, S // 2, 300, CYAN, 90)
    d = ImageDraw.Draw(img)
    cx = S // 2
    top = 300
    table_w = 200
    girdle = 470
    girdle_w = 320
    bot = 780
    # 上半（冠部梯形）
    crown = [(cx - table_w, top), (cx + table_w, top),
             (cx + girdle_w, girdle), (cx - girdle_w, girdle)]
    d.polygon(crown, fill=lerp(CYAN, WHITE, 0.35))
    # 下半（底部三角 + 尖端）
    pav = [(cx - girdle_w, girdle), (cx + girdle_w, girdle), (cx, bot)]
    d.polygon(pav, fill=lerp(BLUE_L, CYAN, 0.45))
    # 刻面线
    d.line([cx - table_w, top, cx - girdle_w, girdle], fill=WHITE, width=6)
    d.line([cx + table_w, top, cx + girdle_w, girdle], fill=WHITE, width=6)
    d.line([cx, top, cx, girdle], fill=WHITE, width=6)
    d.line([cx, girdle, cx, bot], fill=WHITE, width=6)
    d.line([cx - girdle_w, girdle, cx, bot], fill=WHITE, width=6)
    d.line([cx + girdle_w, girdle, cx, bot], fill=WHITE, width=6)
    # 桌面高光
    d.polygon([(cx - table_w, top), (cx + table_w, top), (cx, top + 60)], fill=WHITE)
    return finalize(img)

icons = [
    ("icon1_熊猫阿宝.png", icon_panda),
    ("icon2_四宫格.png", icon_quad),
    ("icon3_星标助手.png", icon_sparkle),
    ("icon4_守护心盾.png", icon_shield),
    ("icon5_宝钻.png", icon_gem),
]
for name, fn in icons:
    im = fn()
    path = os.path.join(OUT, name)
    im.save(path)
    print("saved", path, im.size)
