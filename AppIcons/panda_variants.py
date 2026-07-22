#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""熊猫阿宝图标的更可爱、更温和版本。"""
import math, os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 1024
OUT = "/Volumes/MacBook/Workbuddy/AI助理/AppIcons"

def vgrad(top, bottom):
    t = np.array(top, float); b = np.array(bottom, float)
    f = np.linspace(0, 1, S)[:, None]
    arr = t[None, :] * (1 - f) + b[None, :] * f
    arr = np.repeat(arr[:, None, :], S, axis=1)
    arr = np.concatenate([arr, np.full((S, S, 1), 255, dtype=np.uint8)], axis=2)
    return arr.astype(np.uint8)

def new_canvas(grad_fn):
    return Image.fromarray(grad_fn(), "RGBA")

def glow(img, cx, cy, r, color, alpha=120):
    l = Image.new("RGBA", (S, S), (0,0,0,0))
    d = ImageDraw.Draw(l)
    d.ellipse([cx-r, cy-r, cx+r, cy+r], fill=color+(alpha,))
    l = l.filter(ImageFilter.GaussianBlur(r*0.5))
    return Image.alpha_composite(img, l)

def round_mask(radius=230):
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0,0,S-1,S-1], radius=radius, fill=255)
    return m

def finalize(img):
    base = Image.new("RGBA", (S, S), (0,0,0,0))
    base.paste(img, (0,0), img)
    base.putalpha(round_mask(230))
    return base

def draw_cute_eye(d, cx, cy, patch_r, sclera_r, pupil_r, ink=(40,50,68)):
    # 黑色眼罩（更圆）
    d.ellipse([cx-patch_r, cy-patch_r, cx+patch_r, cy+patch_r], fill=ink)
    # 眼白
    d.ellipse([cx-sclera_r, cy-sclera_r, cx+sclera_r, cy+sclera_r], fill=(255,255,255))
    # 瞳孔
    d.ellipse([cx-pupil_r, cy-pupil_r, cx+pupil_r, cy+pupil_r], fill=ink)
    # 主高光
    d.ellipse([cx-pupil_r+10, cy-pupil_r-5, cx-pupil_r+32, cy-pupil_r+17], fill=(255,255,255))
    # 次高光
    d.ellipse([cx-pupil_r+22, cy+pupil_r-8, cx-pupil_r+34, cy+pupil_r+4], fill=(255,255,255))

def panda_v1_soft():
    """柔和软萌版：更圆润、大眼睛、粉鼻、微笑。"""
    img = new_canvas(lambda: vgrad((108, 178, 244), (75, 145, 222)))
    img = glow(img, S//2, S//2, 300, (255,255,255), 40)
    d = ImageDraw.Draw(img)
    cx, cy = S//2, S//2 + 10
    # 耳朵：更圆、更小、更贴近头部
    d.ellipse([cx-210, cy-340, cx-50, cy-180], fill=(40,50,68))
    d.ellipse([cx+50, cy-340, cx+210, cy-180], fill=(40,50,68))
    d.ellipse([cx-190, cy-320, cx-70, cy-200], fill=(70,80,100))
    d.ellipse([cx+70, cy-320, cx+190, cy-200], fill=(70,80,100))
    # 脸：更圆、略大
    d.ellipse([cx-250, cy-260, cx+250, cy+280], fill=(255,255,255))
    # 腮红：柔和粉色，小一点
    d.ellipse([cx-205, cy+30, cx-120, cy+105], fill=(255,180,190,110))
    d.ellipse([cx+120, cy+30, cx+205, cy+105], fill=(255,180,190,110))
    # 眼睛：大而圆
    draw_cute_eye(d, cx-115, cy-60, 95, 60, 32)
    draw_cute_eye(d, cx+115, cy-60, 95, 60, 32)
    # 鼻子：粉色小椭圆
    d.ellipse([cx-28, cy+55, cx+28, cy+95], fill=(255,130,150))
    d.ellipse([cx-18, cy+65, cx+8, cy+80], fill=(255,200,205,180))
    # 嘴巴：小微笑
    d.arc([cx-50, cy+80, cx, cy+150], start=20, end=160, fill=(40,50,68), width=12)
    d.arc([cx, cy+80, cx+50, cy+150], start=20, end=160, fill=(40,50,68), width=12)
    return finalize(img)

def panda_v2_kawaii():
    """Q 萌版：头身比更大、眼睛占脸部更多、表情更天真。"""
    img = new_canvas(lambda: vgrad((120, 190, 250), (88, 160, 232)))
    img = glow(img, S//2, S//2, 320, (255,255,255), 50)
    d = ImageDraw.Draw(img)
    cx, cy = S//2, S//2 + 15
    # 耳朵
    d.ellipse([cx-200, cy-310, cx-60, cy-180], fill=(40,50,68))
    d.ellipse([cx+60, cy-310, cx+200, cy-180], fill=(40,50,68))
    d.ellipse([cx-180, cy-290, cx-80, cy-190], fill=(75,85,105))
    d.ellipse([cx+80, cy-290, cx+180, cy-190], fill=(75,85,105))
    # 脸：更圆
    d.ellipse([cx-245, cy-240, cx+245, cy+270], fill=(255,255,255))
    # 超大眼睛
    draw_cute_eye(d, cx-120, cy-40, 105, 70, 38)
    draw_cute_eye(d, cx+120, cy-40, 105, 70, 38)
    # 腮红：更明显（爱心式腮红）
    d.ellipse([cx-210, cy+40, cx-130, cy+115], fill=(255,165,180,130))
    d.ellipse([cx+130, cy+40, cx+210, cy+115], fill=(255,165,180,130))
    # 小粉鼻
    d.ellipse([cx-22, cy+70, cx+22, cy+102], fill=(255,120,145))
    #  tiny 微笑
    d.arc([cx-35, cy+95, cx, cy+145], start=20, end=160, fill=(40,50,68), width=10)
    d.arc([cx, cy+95, cx+35, cy+145], start=20, end=160, fill=(40,50,68), width=10)
    # 额头小呆毛（更可爱）
    d.polygon([(cx-10, cy-245), (cx+10, cy-245), (cx, cy-285)], fill=(40,50,68))
    return finalize(img)

def panda_v3_gentle():
    """温和治愈版：眯眼笑、脸颊更粉、整体更柔和。"""
    img = new_canvas(lambda: vgrad((138, 198, 255), (95, 160, 235)))
    img = glow(img, S//2, S//2, 320, (255,255,255), 60)
    d = ImageDraw.Draw(img)
    cx, cy = S//2, S//2 + 10
    # 耳朵
    d.ellipse([cx-205, cy-320, cx-55, cy-170], fill=(40,50,68))
    d.ellipse([cx+55, cy-320, cx+205, cy-170], fill=(40,50,68))
    d.ellipse([cx-185, cy-300, cx-75, cy-190], fill=(70,80,100))
    d.ellipse([cx+75, cy-300, cx+185, cy-190], fill=(70,80,100))
    # 脸
    d.ellipse([cx-255, cy-250, cx+255, cy+280], fill=(255,255,255))
    # 眯眯眼（弧线）
    d.arc([cx-190, cy-80, cx-80, cy+20], start=20, end=160, fill=(40,50,68), width=16)
    d.arc([cx+80, cy-80, cx+190, cy+20], start=20, end=160, fill=(40,50,68), width=16)
    # 腮红
    d.ellipse([cx-210, cy+40, cx-120, cy+120], fill=(255,170,190,130))
    d.ellipse([cx+120, cy+40, cx+210, cy+120], fill=(255,170,190,130))
    # 鼻子
    d.ellipse([cx-30, cy+60, cx+30, cy+100], fill=(255,130,150))
    # 开心嘴巴
    d.arc([cx-70, cy+80, cx, cy+160], start=20, end=160, fill=(40,50,68), width=14)
    d.arc([cx, cy+80, cx+70, cy+160], start=20, end=160, fill=(40,50,68), width=14)
    return finalize(img)

variants = [
    ("icon1a_熊猫阿宝_软萌.png", panda_v1_soft),
    ("icon1b_熊猫阿宝_Q萌.png", panda_v2_kawaii),
    ("icon1c_熊猫阿宝_治愈.png", panda_v3_gentle),
]
for name, fn in variants:
    im = fn()
    im.save(os.path.join(OUT, name))
    print("saved", os.path.join(OUT, name))
