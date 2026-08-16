#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把好记AI 启动屏预览(HTML)重绘成全屏启动图 PNG（无设备外框）。

设计来自 launch_screen_preview.html：
- 浅色背景 #f7f9fb
- 居中绿色 App 图标（取自真实 AppIcon.png）
- 标题「好记AI」#3c3c43 半粗
- 页脚「自动记账记待办，管理饮食和健康」#8a9099 常规

按比例适配任意尺寸（以 390x844 逻辑点为基准 @3x）。
"""
import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

HIRAGINO = "/System/Library/Fonts/Hiragino Sans GB.ttc"
ICON_SRC = "/Volumes/MacBook/Workbuddy/AI助理/AIA/AIA/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
OUT_DIR = "/Volumes/MacBook/Workbuddy/AI助理/AppIcons"

SURFACE = (247, 249, 251)   # #f7f9fb
READING = (60, 60, 67)      # #3c3c43
MUTED   = (138, 144, 153)   # #8a9099
GREEN   = (52, 199, 89)     # #34C759 图标同色辉光


def round_mask(size, radius):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius=radius, fill=255)
    return m


def render(W, H, path):
    scale = W / 390.0
    icon_size = int(round(76 * scale))
    gap = int(round(18 * scale))
    title_font = int(round(20 * scale))
    footer_font = int(round(14 * scale))
    footer_bottom = int(round(80 * scale))

    canvas = Image.new("RGB", (W, H), SURFACE)
    c = ImageDraw.Draw(canvas)

    # ---- 图标（带绿色辉光阴影）----
    icon = Image.open(ICON_SRC).convert("RGBA").resize((icon_size, icon_size), Image.LANCZOS)
    radius = int(round(icon_size * 22 / 76))  # 与 HTML border-radius 比例一致
    # 辉光：绿色圆角矩形模糊后置于图标下方
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gx0, gy0 = (W - icon_size) // 2, 0
    gy0 = int(0.38 * H) - icon_size // 2 + int(round(8 * scale))
    gd.rounded_rectangle([gx0, gy0, gx0 + icon_size, gy0 + icon_size], radius=radius,
                         fill=GREEN + (70,))
    glow = glow.filter(ImageFilter.GaussianBlur(int(round(20 * scale))))
    canvas = Image.alpha_composite(canvas.convert("RGBA"), glow).convert("RGB")
    c = ImageDraw.Draw(canvas)

    icon_x = (W - icon_size) // 2
    icon_top = int(0.38 * H) - icon_size // 2
    # 用圆角遮罩裁掉图标直角外缘，贴合 HTML 的圆角观感
    icon_mask = round_mask((icon_size, icon_size), radius)
    icon.putalpha(icon_mask)
    canvas.paste(icon, (icon_x, icon_top), icon)

    # ---- 标题「好记AI」----
    f_title = ImageFont.truetype(HIRAGINO, title_font, index=2)  # W6 半粗
    title = "好记AI"
    tb = c.textbbox((0, 0), title, font=f_title)
    title_w, title_h = tb[2] - tb[0], tb[3] - tb[1]
    title_x = (W - title_w) // 2 - tb[0]
    title_y = icon_top + icon_size + gap - tb[1]
    c.text((title_x, title_y), title, font=f_title, fill=READING)

    # ---- 页脚 ----
    f_footer = ImageFont.truetype(HIRAGINO, footer_font, index=0)  # W3 常规
    footer = "自动记账记待办，管理饮食和健康"
    fb = c.textbbox((0, 0), footer, font=f_footer)
    footer_w = fb[2] - fb[0]
    footer_x = (W - footer_w) // 2 - fb[0]
    footer_y = H - footer_bottom - (fb[3] - fb[1]) - fb[1]
    c.text((footer_x, footer_y), footer, font=f_footer, fill=MUTED)

    canvas.save(path)
    print("OK", os.path.basename(path), canvas.size)


if __name__ == "__main__":
    os.makedirs(OUT_DIR, exist_ok=True)
    render(1170, 2532, os.path.join(OUT_DIR, "LaunchScreen_1170x2532.png"))
    render(1290, 2796, os.path.join(OUT_DIR, "LaunchScreen_1290x2796.png"))
