import os
from PIL import Image, ImageDraw, ImageFont

def generate_dmg_background(output_path):
    # 逻辑尺寸: 560 x 400 pt
    # Retina @2x: 1120 x 800 px, 144 DPI
    SCALE = 2
    WIDTH_PT = 560
    HEIGHT_PT = 400
    WIDTH_PX = WIDTH_PT * SCALE
    HEIGHT_PX = HEIGHT_PT * SCALE

    img = Image.new("RGBA", (WIDTH_PX, HEIGHT_PX), (248, 249, 251, 255))
    draw = ImageDraw.Draw(img)

    # 1. 绘制极简纯净微渐变背景 (#F9FAFC -> #EEF1F5)
    for y in range(HEIGHT_PX):
        ratio = y / float(HEIGHT_PX)
        r = int(249 - (249 - 238) * ratio)
        g = int(250 - (250 - 241) * ratio)
        b = int(252 - (252 - 245) * ratio)
        draw.line([(0, y), (WIDTH_PX, y)], fill=(r, g, b, 255))

    # 2. 标题："Maple for Mac"
    title_text = "Maple for Mac"
    try:
        title_font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 22 * SCALE)
    except Exception:
        title_font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 22 * SCALE)

    bbox = draw.textbbox((0, 0), title_text, font=title_font)
    title_w = bbox[2] - bbox[0]
    title_x = (WIDTH_PX - title_w) // 2
    title_y = int(46 * SCALE)
    draw.text((title_x, title_y), title_text, font=title_font, fill=(32, 34, 40, 255))

    # 3. 左右两个贴合 96pt 图标的圆角白色卡片
    # Finder 放置位置为 (140, 200) 与 (420, 200)
    # 96pt 图标的几何中心位于 Y = 187 pt
    CARD_CX_LEFT = int(140 * SCALE)
    CARD_CX_RIGHT = int(420 * SCALE)
    CARD_CY = int(187 * SCALE)
    CARD_W = int(130 * SCALE)
    CARD_H = int(130 * SCALE)
    RADIUS = int(24 * SCALE)

    def draw_card(cx, cy, w, h, r):
        x0 = cx - w // 2
        y0 = cy - h // 2
        x1 = x0 + w
        y1 = y0 + h

        # 柔和多层阴影
        for i in range(int(5 * SCALE), 0, -1):
            alpha = int(3 * (1 - i / float(5 * SCALE)))
            draw.rounded_rectangle(
                [x0 - i, y0 + int(2 * SCALE) - i, x1 + i, y1 + int(2 * SCALE) + i],
                radius=r + i,
                fill=(0, 0, 0, alpha)
            )

        # 纯白卡片底色
        draw.rounded_rectangle([x0, y0, x1, y1], radius=r, fill=(255, 255, 255, 255))

        # 精致浅灰边框
        draw.rounded_rectangle([x0, y0, x1, y1], radius=r, outline=(220, 224, 230, 220), width=int(1.5 * SCALE))

    draw_card(CARD_CX_LEFT, CARD_CY, CARD_W, CARD_H, RADIUS)
    draw_card(CARD_CX_RIGHT, CARD_CY, CARD_W, CARD_H, RADIUS)

    # 4. 中间蓝色导向箭头 (从 X=232 到 X=328, Y=187)
    arrow_start_x = int(232 * SCALE)
    arrow_end_x = int(328 * SCALE)
    arrow_y = CARD_CY

    dash_len = int(8 * SCALE)
    gap_len = int(5 * SCALE)
    cur_x = arrow_start_x
    arrow_color = (55, 135, 250, 180)
    while cur_x < arrow_end_x - int(12 * SCALE):
        next_x = min(cur_x + dash_len, arrow_end_x - int(12 * SCALE))
        draw.line([(cur_x, arrow_y), (next_x, arrow_y)], fill=arrow_color, width=int(3.5 * SCALE))
        cur_x += dash_len + gap_len

    head_size = int(10 * SCALE)
    head_color = (40, 125, 245, 240)
    draw.line([(arrow_end_x - head_size, arrow_y - head_size), (arrow_end_x, arrow_y)], fill=head_color, width=int(3.5 * SCALE))
    draw.line([(arrow_end_x - head_size, arrow_y + head_size), (arrow_end_x, arrow_y)], fill=head_color, width=int(3.5 * SCALE))

    # 箭头下方提示微文
    sub_text = "拖移至右侧安装"
    try:
        sub_font = ImageFont.truetype("/System/Library/Fonts/PingFang.ttc", 11 * SCALE)
    except Exception:
        sub_font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 11 * SCALE)

    s_bbox = draw.textbbox((0, 0), sub_text, font=sub_font)
    s_w = s_bbox[2] - s_bbox[0]
    s_x = (WIDTH_PX - s_w) // 2
    s_y = arrow_y + int(14 * SCALE)
    draw.text((s_x, s_y), sub_text, font=sub_font, fill=(75, 135, 235, 220))

    # 5. 输出 144 DPI Retina PNG
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    img.save(output_path, format="PNG", dpi=(144, 144))
    print(f"✓ 成功生成 144 DPI Retina DMG 背景图: {output_path}")

if __name__ == "__main__":
    script_dir = os.path.dirname(os.path.abspath(__file__))
    target = os.path.join(script_dir, "dmg_background.png")
    generate_dmg_background(target)
