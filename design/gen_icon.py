# -*- coding: utf-8 -*-
"""
Liang AI App 图标生成脚本
设计：字母 L 标 + 多彩渐变底（蓝→紫→粉），圆角方形背景
输出：design/icon_1024.png（母版，供 flutter_launcher_icons 使用）
"""
import math
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SS = 4  # 超采样倍数（抗锯齿）
S = SIZE * SS


def lerp(a, b, t):
    return a + (b - a) * t


def gradient_bg(size):
    """纯黑背景"""
    return Image.new("RGB", (size, size), (10, 10, 12))


def rainbow_L_colors(n):
    """沿 L 笔画生成彩虹渐变色序列（红→橙→黄→绿→青→蓝→紫）"""
    stops = [
        (255, 59, 48),    # 红
        (255, 149, 0),    # 橙
        (255, 214, 10),   # 黄
        (52, 199, 89),    # 绿
        (50, 173, 230),   # 青
        (88, 86, 214),    # 蓝
        (175, 82, 222),   # 紫
    ]

    def sample(t):
        """t ∈ [0,1] → 彩虹插值色"""
        t = max(0.0, min(1.0, t))
        pos = t * (len(stops) - 1)
        i = min(int(pos), len(stops) - 2)
        k = pos - i
        a, b = stops[i], stops[i + 1]
        return (int(lerp(a[0], b[0], k)),
                int(lerp(a[1], b[1], k)),
                int(lerp(a[2], b[2], k)))

    return [sample(i / (n - 1)) for i in range(n)]


def rounded_rect_mask(size, radius_ratio):
    """圆角方形蒙版（Android 自适应图标底用全出血，圆角由启动器裁）"""
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    r = int(size * radius_ratio)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=r, fill=255)
    return m


def draw_L(draw, s):
    """
    几何化字母 L：彩虹渐变笔画 + 圆角端点 + 右上角 AI 星点
    坐标基于画布尺寸 s（超采样后）
    渐变方向：竖笔从上(红)到拐角(绿)，横笔从拐角到右端(紫)
    """
    stroke = int(s * 0.135)          # 笔画粗度
    x0 = int(s * 0.28)               # L 左边缘
    y_top = int(s * 0.22)            # L 顶
    y_bot = int(s * 0.78)            # L 底
    x_foot = int(s * 0.72)           # L 底部右端
    r = stroke // 2                  # 端点半径

    colors = rainbow_L_colors(64)

    # 竖笔：分段绘制，颜色从上到下渐变（红→绿）
    v_len = (y_bot + r) - (y_top - r)
    seg = 64
    for i in range(seg):
        t0, t1 = i / seg, (i + 1) / seg
        ya = int((y_top - r) + v_len * t0)
        yb = int((y_top - r) + v_len * t1) + 1  # +1 防缝
        draw.rectangle([x0 - r, ya, x0 + r, min(yb, y_bot + r)],
                       fill=(*colors[int(t0 * 63)], 255))

    # 横笔：分段绘制，颜色从左到右渐变（绿→紫）
    h_len = (x_foot + r) - (x0 - r)
    for i in range(seg):
        t0, t1 = i / seg, (i + 1) / seg
        # 横笔的色相接续竖笔末端：整体 t 从 0.5 → 1.0
        ci = int((0.5 + t0 * 0.5) * 63)
        xa = int((x0 - r) + h_len * t0)
        xb = int((x0 - r) + h_len * t1) + 1
        draw.rectangle([xa, y_bot - r, min(xb, x_foot + r), y_bot + r],
                       fill=(*colors[ci], 255))

    # 圆角端点盖片：三端各画一个对应颜色的圆，柔化分段边界
    draw.ellipse([x0 - r, y_top - r, x0 + r, y_top + r],
                 fill=(*colors[0], 255))                      # 顶：红
    draw.ellipse([x0 - r, y_bot - r, x0 + r, y_bot + r],
                 fill=(*colors[31], 255))                     # 拐角：绿
    draw.ellipse([x_foot - r, y_bot - r, x_foot + r, y_bot + r],
                 fill=(*colors[63], 255))                     # 右端：紫

    # 右上角 AI 星点：白色星芒在黑底上保持高对比
    star_cx, star_cy = int(s * 0.70), int(s * 0.30)

    def star4(cx, cy, radius, color):
        """四角星（菱形星芒）"""
        pts = []
        for i in range(8):
            ang = math.pi / 4 * i - math.pi / 2
            rad = radius if i % 2 == 0 else radius * 0.36
            pts.append((cx + rad * math.cos(ang), cy + rad * math.sin(ang)))
        draw.polygon(pts, fill=color)

    star4(star_cx, star_cy, int(s * 0.085), (255, 255, 255, 255))
    star4(int(s * 0.82), int(s * 0.20), int(s * 0.038), (255, 255, 255, 230))
    star4(int(s * 0.60), int(s * 0.16), int(s * 0.030), (255, 255, 255, 200))


def main():
    # 1. 纯黑底（超采样）
    bg = gradient_bg(S).convert("RGBA")

    # 2. 画彩虹 L + 星点（超采样层）
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    draw_L(d, S)

    # 3. 合成（黑底不加高光，保持纯净）
    canvas = Image.alpha_composite(bg, layer)

    # 4. 缩到目标尺寸（超采样抗锯齿）
    icon = canvas.resize((SIZE, SIZE), Image.LANCZOS)

    # 6. 输出两个版本
    # 6a. 全出血方形（自适应图标前景/背景用）
    icon.save("design/icon_1024.png")

    # 6b. 圆角方形预览（模拟桌面效果）
    preview = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    mask = rounded_rect_mask(SIZE, 0.22)
    preview.paste(icon, (0, 0), mask)
    preview.save("design/icon_preview_rounded.png")

    print("OK: design/icon_1024.png + design/icon_preview_rounded.png")


if __name__ == "__main__":
    main()
