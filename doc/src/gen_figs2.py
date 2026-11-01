# -*- coding: utf-8 -*-
"""补充技术文档示意图（与 fig_system_block / fig_transition_map 同一视觉体系）
   fig_clock_domain.png  图 2-2  三时钟域与乒乓双缓冲
   fig_pin_map.png       图 2-4  板卡接口与引脚分配
   fig_rtl_flow.png      图 2-5  RTL 总体数据流
   fig_pipeline.png      图 2-7  帧读取地址链两级流水
"""
import math
import os
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'fig')
import os
from PIL import Image, ImageDraw, ImageFont

FZ = r'C:\Windows\Fonts\msyh.ttc'
FZB = r'C:\Windows\Fonts\msyhbd.ttc'


K_SCALE = 1.45


def f(size, bold=False):
    return ImageFont.truetype(FZB if bold else FZ, int(round(size * K_SCALE)))


WHITE = (255, 255, 255)
INK = (26, 34, 48)
INK2 = (84, 94, 110)
LINE = (146, 158, 178)

KIND = {
    'write': ((221, 233, 247), (46, 84, 150)),
    'mem':   ((230, 235, 243), (31, 56, 100)),
    'pix':   ((252, 232, 218), (184, 92, 30)),
    'hdmi':  ((219, 239, 227), (44, 122, 75)),
    'audio': ((236, 227, 244), (107, 74, 158)),
    'ctrl':  ((255, 242, 212), (150, 110, 11)),
    'gray':  ((240, 243, 248), (110, 122, 140)),
}


def soft(fill, k=0.62):
    return tuple(int(c + (255 - c) * k) for c in fill)


def box(d, x, y, w, h, title, sub='', kind='write', ts=17, ss=12):
    fc, bc = KIND[kind]
    d.rounded_rectangle([x, y, x + w, y + h], radius=9, fill=fc, outline=bc, width=2)
    ft, fs = f(ts, True), f(ss)
    if sub:
        th, sh, gap = ts * K_SCALE * 1.05, ss * K_SCALE * 1.05, 4
        ty = y + (h - (th + gap + sh)) / 2
        tw = d.textlength(title, font=ft)
        d.text((x + (w - tw) / 2, ty), title, font=ft, fill=INK)
        sw = d.textlength(sub, font=fs)
        d.text((x + (w - sw) / 2, ty + th + gap), sub, font=fs, fill=INK2)
    else:
        tw = d.textlength(title, font=ft)
        d.text((x + (w - tw) / 2, y + (h - ts * K_SCALE * 1.05) / 2), title, font=ft, fill=INK)


def arrow(d, x1, y1, x2, y2, color=LINE, w=3, head=12):
    d.line([x1, y1, x2, y2], fill=color, width=w)
    ang = math.atan2(y2 - y1, x2 - x1)
    sp = 0.44
    p1 = (x2 - head * math.cos(ang - sp), y2 - head * math.sin(ang - sp))
    p2 = (x2 - head * math.cos(ang + sp), y2 - head * math.sin(ang + sp))
    d.polygon([(x2, y2), p1, p2], fill=color)


def path(d, pts, color=LINE, w=3, dash=False, head=True):
    for i in range(len(pts) - 1):
        (x1, y1), (x2, y2) = pts[i], pts[i + 1]
        if dash:
            n = max(2, int(math.hypot(x2 - x1, y2 - y1) / 9))
            for k in range(n):
                if k % 2:
                    continue
                xa = x1 + (x2 - x1) * k / n
                ya = y1 + (y2 - y1) * k / n
                xb = x1 + (x2 - x1) * (k + 1) / n
                yb = y1 + (y2 - y1) * (k + 1) / n
                d.line([xa, ya, xb, yb], fill=color, width=w)
        else:
            d.line([x1, y1, x2, y2], fill=color, width=w)
    if head:
        (xa, ya), (xb, yb) = pts[-2], pts[-1]
        arrow(d, xa, ya, xb, yb, color, w)


def lane(d, x0, y0, x1, y1, label, kind, ls=14):
    fc, bc = KIND[kind]
    d.rounded_rectangle([x0, y0, x1, y1], radius=12, fill=soft(fc, 0.72))
    d.text((x0 + 14, y0 + 8), label, font=f(ls, True), fill=bc)


def vtext(img, cx, cy, text, font, fill):
    tmp = Image.new('RGBA', (int(font.size * 1.6 * len(text)) + 20, int(font.size * 1.9)), (0, 0, 0, 0))
    dd = ImageDraw.Draw(tmp)
    tw = dd.textlength(text, font=font)
    dd.text(((tmp.width - tw) / 2, 2), text, font=font, fill=fill)
    tmp = tmp.rotate(90, expand=True)
    bbox = tmp.getbbox()
    tmp = tmp.crop(bbox)
    img.paste(tmp, (int(cx - tmp.width / 2), int(cy - tmp.height / 2)), tmp)


# ===========================================================================
# 图 2-2  三时钟域与乒乓双缓冲
# ===========================================================================
W, H = 1480, 812
img = Image.new('RGB', (W, H), WHITE)
d = ImageDraw.Draw(img)

# ---- 三个时钟域 ----
lane(d, 20, 44, 420, 486, '', 'write')
d.text((36, 54), '①  写入域　sd_card_clk　100 MHz', font=f(14, True), fill=KIND['write'][1])
lane(d, 500, 44, 980, 486, '', 'mem')
d.text((516, 54), '②  存储域　ext_mem_clk　100 MHz', font=f(14, True), fill=KIND['mem'][1])
lane(d, 1060, 44, 1460, 486, '', 'pix')
d.text((1076, 54), '③  像素域　video_clk　25 MHz', font=f(14, True), fill=KIND['pix'][1])

bx, bw = 40, 360
box(d, bx, 92, bw, 62, 'TF 卡（MicroSD，SPI 模式）', '512 字节单扇区读写', 'write', 15, 11)
box(d, bx, 178, bw, 62, 'SD 卡驱动', 'sd_card_top / sd_card_cmd', 'write', 15, 11)
box(d, bx, 264, bw, 62, 'BMP 扫描与解析', 'sd_card_bmp / bmp_read', 'write', 15, 11)
box(d, bx, 350, bw, 76, '帧写 FIFO', 'BGR→RGB、行序翻转、行宽对齐', 'write', 15, 11)
for y in (154, 240, 326):
    arrow(d, bx + bw / 2, y, bx + bw / 2, y + 24, KIND['write'][1])

# ---- SDRAM ----
sx0, sy0, sx1, sy1 = 520, 88, 960, 448
d.rounded_rectangle([sx0, sy0, sx1, sy1], radius=10, fill=WHITE, outline=KIND['mem'][1], width=2)
d.text((sx0 + 16, sy0 + 10), '片内 SDRAM　2M×32 bit（8 MB）', font=f(15, True), fill=KIND['mem'][1])
for yy, name, base, note in ((150, 'BUF0', '基址 0', '写新帧时显示 BUF1'),
                             (252, 'BUF1', '基址 307200', '写 BUF0 时显示 BUF1')):
    d.rounded_rectangle([540, yy, 940, yy + 82], radius=7, fill=KIND['mem'][0], outline=KIND['mem'][1], width=2)
    d.text((558, yy + 14), name, font=f(18, True), fill=KIND['mem'][1])
    d.text((558 + 74, yy + 20), base, font=f(13), fill=INK)
    d.text((558, yy + 48), '640×480×24 bit = 307 200 字', font=f(12), fill=INK2)
    d.text((940 - 12 - d.textlength(note, font=f(12, True)), yy + 20), note, font=f(12, True), fill=INK2)
d.text((540, 350), '两帧首尾相邻，共 614 400 字；写指针与显示指针分离',
       font=f(12), fill=INK2)
d.text((540, 376), '读写仲裁：写 256 字 / 读 16 字突发，交替占用用户接口',
       font=f(12), fill=INK2)
d.text((540, 402), '写满整帧（307 200 字）后方切换 → 无撕裂、无黑场',
       font=f(12, True), fill=KIND['mem'][1])

# ---- 跨域连线与 AFIFO 标注 ----
def pill(d, cx, cy, text, kind='gray', pw=80):
    fc, bc = KIND[kind]
    d.rounded_rectangle([cx - pw / 2, cy - 15, cx + pw / 2, cy + 15], radius=15,
                        fill=soft(fc, 0.15), outline=bc, width=2)
    tw = d.textlength(text, font=f(12, True))
    d.text((cx - tw / 2, cy - 9), text, font=f(12, True), fill=bc)


path(d, [(400, 388), (410, 388), (410, 292), (536, 292)], KIND['write'][1])
path(d, [(960, 190), (984, 190), (984, 155), (1076, 155)], KIND['pix'][1])
pill(d, 461, 292, 'AFIFO')
pill(d, 1020, 155, 'AFIFO')

# ---- 像素域 ----
cx, cw = 1080, 360
box(d, cx, 118, cw, 74, '读 FIFO', '读侧与像素时钟同步', 'pix', 15, 11)
box(d, cx, 216, cw, 74, '突发与块边界选帧', 'frame_fifo_read', 'pix', 15, 11)
box(d, cx, 314, cw, 74, '像素处理链', '画质 / 转场 / 字幕 / 频谱', 'pix', 15, 11)
arrow(d, cx + cw / 2, 192, cx + cw / 2, 214, KIND['pix'][1])
arrow(d, cx + cw / 2, 290, cx + cw / 2, 312, KIND['pix'][1])
d.text((cx, 400), '光栅顺序读出，与 FPS 消费逐字对齐', font=f(12), fill=INK2)
d.text((cx, 426), '像素时钟 25 MHz，一帧 16.7 ms', font=f(12), fill=INK2)


# ---- 底部：乒乓节拍 ----
d.line([20, 500, 1460, 500], fill=(214, 223, 236), width=2)
d.text((20, 512), '乒乓双缓冲的切换节拍　（写与显始终落在不同帧，每格为一帧 16.7 ms）',
       font=f(15, True), fill=INK)

tx0, cw2 = 150, 244
rows = [('BUF0', 552, ['写', '显', '写', '显', '写']),
        ('BUF1', 620, ['显', '写', '显', '写', '显'])]
for name, yy, seq in rows:
    d.text((60, yy + 22), name, font=f(16, True), fill=KIND['mem'][1])
    for i, s in enumerate(seq):
        x = tx0 + i * cw2
        fillc = KIND['write'][0] if s == '写' else KIND['pix'][0]
        borc = KIND['write'][1] if s == '写' else KIND['pix'][1]
        d.rounded_rectangle([x, yy, x + cw2 - 8, yy + 52], radius=6, fill=fillc, outline=borc, width=2)
        lab = '写入新图' if s == '写' else '输出显示'
        tw = d.textlength(lab, font=f(13, True))
        d.text((x + (cw2 - 8 - tw) / 2, yy + 16), lab, font=f(13, True), fill=borc)
    # 帧刻度
for i in range(6):
    x = tx0 + i * cw2 - 4
    d.line([x, 544, x, 680], fill=(224, 230, 240), width=1)
d.line([tx0 - 4, 690, tx0 + 5 * cw2 - 4, 690], fill=(150, 162, 182), width=2)
for i in range(6):
    d.text((tx0 + i * cw2 + 2, 696), '帧 %d' % i, font=f(11), fill=INK2)

notes = ['切换发生在帧边界：显示指针在帧起始更新，画面不出现半帧新半帧旧。',
         '写侧满帧标志置位后才允许换帧，读侧若正在读旧帧则等本帧结束。',
         '两帧基址固定（0 / 307 200），转场只改读地址偏移，不改缓冲归属。']
for i, t in enumerate(notes):
    d.text((30, 736 + i * 26), '· ' + t, font=f(12), fill=INK2)

img.save(os.path.join(OUT, 'fig_clock_domain.png'))
print('fig 2-2', img.size)

# ===========================================================================
# 图 2-4  板卡接口与引脚分配
# ===========================================================================
W, H = 1480, 790
img = Image.new('RGB', (W, H), WHITE)
d = ImageDraw.Draw(img)

# 中央核心板
d.rounded_rectangle([460, 50, 1020, 686], radius=14, fill=soft(KIND['gray'][0], 0.45),
                    outline=KIND['gray'][1], width=2)
d.text((478, 62), '大拇指 EG4S20BG256 核心板', font=f(16, True), fill=KIND['mem'][1])
d.rounded_rectangle([520, 100, 960, 456], radius=10, fill=WHITE, outline=KIND['mem'][1], width=2)
d.text((538, 112), 'FPGA  EG4S20BG256（BGA256）', font=f(16, True), fill=KIND['mem'][1])
d.text((538, 142), '19 600 LUT · 29 DSP · 64×9 Kb BRAM · 4 PLL', font=f(11), fill=INK2)
for i, (t, s2) in enumerate([('PLL ×2', '100 / 25 / 125 MHz'),
                             ('片内 SDRAM', '2M×32 bit · 8 MB'),
                             ('配置 Flash', '上电自加载'),
                             ('JTAG', '下载与调试')]):
    x = 536 + (i % 2) * 206
    y = 180 + (i // 2) * 132
    box(d, x, y, 190, 108, t, s2, 'mem', 14, 11)

d.text((478, 470), '底板 M0 综合设计底板：仅提供接插件、按键与 5 V 供电，不含逻辑；',
       font=f(11), fill=INK2)
d.text((478, 496), '叠插连接，全部信号经板对板连接器进入 FPGA。', font=f(11), fill=INK2)
d.text((478, 532), 'IO 占用：36 / 188（19.15%）　输入 7　输出 29', font=f(13, True), fill=KIND['mem'][1])
d.text((478, 562), '时钟 R7（50 MHz 有源晶振，LVCMOS33）', font=f(11), fill=INK2)
d.text((478, 586), '复位 A9（SW0，低有效，内部上拉）', font=f(11), fill=INK2)
d.text((478, 610), 'HDMI 走 LVDS33，仅约束 P 端，N 端由原语自动配对', font=f(11), fill=INK2)

# 左侧输入
left = [('TF 卡座（MicroSD · SPI）', 'SCK F15　CS F13　MOSI F14　MISO D14', 'write', '输入'),
        ('4×4 矩阵键盘（用 2 行 4 列）', 'ROW E10 / C10　COL E11 D11 C11 F10', 'ctrl', '输入'),
        ('拨码开关 SW0', 'A9　低有效，整机复位', 'ctrl', '输入')]
for i, (t, s2, k, tag) in enumerate(left):
    y = 84 + i * 162
    box(d, 40, y, 390, 104, t, s2, k, 13, 11)
    arrow(d, 434, y + 52, 456, y + 52, KIND[k][1])
    d.text((40, y + 112), tag, font=f(11), fill=INK2)

# 右侧输出
right = [('HDMI 座（四对差分）', 'CLK P1　D0 N1　D1 P4　D2 J3', 'hdmi'),
         ('4 位数码管', '位选 C9 B6 A5 A3　段选 A4 A6 B8 E8 A7 B5 A8 C8', 'ctrl'),
         ('8× LED', 'B14 B15 B16 C15 C16 E13 E16 F16', 'ctrl')]
for i, (t, s2, k) in enumerate(right):
    y = 84 + i * 162
    box(d, 1050, y, 390, 104, t, s2, k, 13, 11)
    arrow(d, 1024, y + 52, 1046, y + 52, KIND[k][1])
    d.text((1050, y + 112), '输出', font=f(11), fill=INK2)

d.text((40, 552), '注：8 个按键只占 6 个 IO——列线 F10 在', font=f(11), fill=INK2)
d.text((40, 580), '两个扫描相位分别承载 KEY3 与 KEY7。', font=f(11), fill=INK2)
d.text((40, 612), '底板未引出 DDC 与 HPD，系统不读 EDID，', font=f(11), fill=INK2)
d.text((40, 638), '输出固定 640×480@60 Hz，换屏免协商。', font=f(11), fill=INK2)

d.rounded_rectangle([40, 690, 1440, 772], radius=10, fill=soft(KIND['hdmi'][0], 0.55))
d.text((60, 706), '全部引脚约束集中于 sd_hdmi_bmp.adc：4 路 HDMI 差分、4 路 SD、6 路键盘、12 路数码管、8 路 LED。',
       font=f(12, True), fill=KIND['hdmi'][1])
d.text((60, 736), '约束经上板逐项验证后随工程交付，任一端口的电平标准与位置均可追溯至原理图。',
       font=f(11), fill=INK2)
img.save(os.path.join(OUT, 'fig_pin_map.png'))
print('fig 2-4', img.size)
