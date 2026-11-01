# -*- coding: utf-8 -*-
"""补充示意图（二）：fig_rtl_flow.png（图 2-5）、fig_pipeline.png（图 2-7）"""
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


def path(d, pts, color=LINE, w=3, head=True):
    for i in range(len(pts) - 1):
        (x1, y1), (x2, y2) = pts[i], pts[i + 1]
        d.line([x1, y1, x2, y2], fill=color, width=w)
    if head:
        (xa, ya), (xb, yb) = pts[-2], pts[-1]
        arrow(d, xa, ya, xb, yb, color, w)


def lane(d, x0, y0, x1, y1, label, kind, ls=14):
    fc, bc = KIND[kind]
    d.rounded_rectangle([x0, y0, x1, y1], radius=12, fill=soft(fc, 0.72))
    d.text((x0 + 14, y0 + 8), label, font=f(ls, True), fill=bc)


def vtext(img, cx, cy, text, font, fill):
    tmp = Image.new('RGBA', (int(font.size * 1.8 * len(text)) + 20, int(font.size * 2.2)), (0, 0, 0, 0))
    dd = ImageDraw.Draw(tmp)
    tw = dd.textlength(text, font=font)
    dd.text(((tmp.width - tw) / 2, 2), text, font=font, fill=fill)
    tmp = tmp.rotate(90, expand=True)
    tmp = tmp.crop(tmp.getbbox())
    img.paste(tmp, (int(cx - tmp.width / 2), int(cy - tmp.height / 2)), tmp)


# ===========================================================================
# 图 2-5  RTL 总体数据流
# ===========================================================================
W, H = 1520, 906
img = Image.new('RGB', (W, H), WHITE)
d = ImageDraw.Draw(img)


def flowrow(items, y, h, x0, w, gap, kind, ts=14, ss=11):
    for i, (t, s) in enumerate(items):
        x = x0 + i * (w + gap)
        box(d, x, y, w, h, t, s, kind, ts, ss)
        if i:
            arrow(d, x - gap + 2, y + h / 2, x - 4, y + h / 2, KIND[kind][1], head=9)


# ① 写入
lane(d, 20, 40, 1500, 192, '①  视频写入通路　100 MHz（sd_card_clk）— 逐帧完整写入', 'write')
t1 = [('TF 卡（SPI）', '512 B / 扇区'), ('sd_card_top', 'CMD0/8/55 + ACMD41'),
      ('sd_card_bmp', '文件头扫描，前 4 张'), ('bmp_read', 'BGR→RGB、行序翻转'),
      ('frame_fifo_write', '写侧异步 FIFO')]
flowrow(t1, 96, 80, 26, 272, 22, 'write', 14, 11)

# ② 读出
lane(d, 20, 208, 1500, 488, '②  视频读出与处理通路　25 MHz（video_clk）— 按光栅顺序逐字对齐', 'pix')
t2 = [('frame_fifo_read', '突发 16 字 + 块选帧'), ('bright_ctrl', '画质 + OSD'),
      ('trans_fade', '滑动 / 淡变 / 擦除'), ('osd_scroll', '双语滚动字幕'),
      ('audio_vu', '8 段频谱柱')]
flowrow(t2, 256, 82, 70, 260, 20, 'pix', 14, 11)
box(d, 70, 370, 260, 82, 'emergency_mode', 'ROM 直出 + 叠加', 'pix', 14, 11)
arrow(d, 332, 411, 348, 411, KIND['pix'][1])
t3 = [('video_rgb_to_axis', '并转 AXI4-Stream'),
      ('HDMI 1.4b 发送核', '视频 + 音频数据岛'), ('lane_lvds_10_1', '5× DDR 串行化'),
      ('TMDS 差分四对', '至显示器')]
flowrow(t3, 370, 82, 350, 260, 20, 'hdmi', 13, 11)
# 上一行末端回到下一行起点的折线
cx_end = 70 + 4 * 280 + 130
path(d, [(cx_end, 338), (cx_end, 352), (200, 352), (200, 368)], (88, 100, 118), w=3, head=10)
d.text((70, 466), '像素、行场同步与数据使能严格对齐：读延迟由 video_delay 补偿；'
                  '转场只改读地址，不打断像素流。', font=f(12), fill=INK2)

# ③ 音频
lane(d, 20, 504, 1500, 660, '③  音频通路　（与读卡同源，节拍在像素时钟域重建）', 'audio')
t4 = [('wav_player', '扫描 RIFF/WAVE，流式读 data'),
      ('afifo_16_32_256', '写 100 MHz / 读 25 MHz'),
      ('wav_audio_out', '520/521 分数分频 → 48 kHz'),
      ('HDMI 音频数据岛', 'ACR N=6144，CTS 实测')]
flowrow(t4, 552, 76, 60, 300, 34, 'audio', 14, 11)
d.text((60, 640), 'audio_arc_calculate 依据实际像素时钟测量 CTS；I2S 与数据岛同源，音画不漂移。',
       font=f(12), fill=INK2)

# ④ 控制
lane(d, 20, 676, 1500, 796, '④  控制与指示通路　50 MHz（clk）— 按键经两级同步后分发', 'ctrl')
t5 = [('key_scan', '1 kHz 双相位扫描 8 键'), ('两级同步器', '按键跨入各时钟域'),
      ('top 参数寄存器', '模式 / 亮度 / 转场 / 应急'), ('seg4_scan + LED', '版本号、SD 状态码')]
flowrow(t5, 724, 64, 60, 300, 62, 'ctrl', 14, 11)

# ⑤ 时钟与复位
lane(d, 20, 802, 1500, 898, '⑤  时钟生成与复位', 'gray')
box(d, 60, 840, 250, 52, '50 MHz 有源晶振', 'R7，LVCMOS33', 'gray', 14, 11)
box(d, 350, 840, 300, 52, 'clk_pll', '100 MHz + 100 MHz/180°（SDRAM）', 'gray', 13, 11)
box(d, 690, 840, 300, 52, 'video_pll', '25 MHz 像素 + 125 MHz 串行', 'gray', 13, 11)
box(d, 1030, 840, 430, 52, '复位：两路 PLL 锁定 & SW0', '失锁即复位全部逻辑', 'gray', 13, 11)
arrow(d, 312, 866, 346, 866, KIND['gray'][1])
arrow(d, 652, 866, 686, 866, KIND['gray'][1])
arrow(d, 992, 866, 1026, 866, KIND['gray'][1])

img.save(os.path.join(OUT, 'fig_rtl_flow.png'))
print('fig 2-5', img.size)

# ===========================================================================
# 图 2-7  地址链两级流水
# ===========================================================================
W, H = 1240, 640
img = Image.new('RGB', (W, H), WHITE)
d = ImageDraw.Draw(img)
RED = (196, 74, 62)
GRN = (44, 122, 75)

d.text((30, 20), '帧读取地址链：由单拍串联改为两级流水', font=f(18, True), fill=INK)
d.text((30, 52), '功能不变，只把末端一段寄存一拍，100 MHz 下的建立时间由负转正', font=f(12), fill=INK2)

# 改造前
d.text((30, 92), '改造前　同一时钟沿前必须走完的串联路径', font=f(14, True), fill=RED)
d.rounded_rectangle([30, 116, 1210, 240], radius=10, fill=(253, 245, 244), outline=RED, width=2)
pre = [('比较', 'wrusedw < 阈值'), ('状态机', '下一状态判定'), ('块坐标比较', 'n_use 计算'),
       ('选帧', 'mux 新旧帧'), ('地址加法', '21 bit')]
pw, pg = 195, 22
for i, (t, s) in enumerate(pre):
    x = 46 + i * (pw + pg)
    d.rounded_rectangle([x, 146, x + pw, 206], radius=7, fill=WHITE, outline=(178, 140, 136), width=2)
    d.text((x + (pw - d.textlength(t, font=f(14, True))) / 2, 156), t, font=f(14, True), fill=INK)
    d.text((x + (pw - d.textlength(s, font=f(11))) / 2, 180), s, font=f(11), fill=INK2)
    if i:
        arrow(d, x - pg + 2, 176, x - 4, 176, (178, 140, 136))
d.text((46, 214), '该路径 slack −2.94 ns　→　不满足 100 MHz 的 10 ns 周期', font=f(12, True), fill=RED)

# 改造后
d.text((30, 266), '改造后　在块边界处插入寄存器，拆为两级，各自满足 10 ns', font=f(14, True), fill=GRN)
d.rounded_rectangle([30, 290, 1210, 470], radius=10, fill=(243, 250, 245), outline=GRN, width=2)
stage1 = [('比较', 'wrusedw < 阈值'), ('状态机', '下一状态判定'), ('块坐标比较', 'n_use / wb_noff')]
sw_, sg = 195, 22
for i, (t, s) in enumerate(stage1):
    x = 46 + i * (sw_ + sg)
    d.rounded_rectangle([x, 322, x + sw_, 382], radius=7, fill=WHITE, outline=(128, 158, 136), width=2)
    d.text((x + (sw_ - d.textlength(t, font=f(14, True))) / 2, 332), t, font=f(14, True), fill=INK)
    d.text((x + (sw_ - d.textlength(s, font=f(11))) / 2, 356), s, font=f(11), fill=INK2)
    if i:
        arrow(d, x - sg + 2, 352, x - 4, 352, (128, 158, 136))

rx = 46 + 3 * (sw_ + sg) - 8
d.rounded_rectangle([rx, 310, rx + 44, 394], radius=4, fill=KIND['mem'][0], outline=KIND['mem'][1], width=2)
vtext(img, rx + 22, 352, 'reg', f(13, True), KIND['mem'][1])
arrow(d, rx - 12, 352, rx - 3, 352, (128, 158, 136))

x = rx + 58
for i, (t, s) in enumerate([('选帧', 'mux 新旧帧'), ('地址加法', '21 bit')]):
    d.rounded_rectangle([x, 322, x + sw_, 382], radius=7, fill=WHITE, outline=(128, 158, 136), width=2)
    d.text((x + (sw_ - d.textlength(t, font=f(14, True))) / 2, 332), t, font=f(14, True), fill=INK)
    d.text((x + (sw_ - d.textlength(s, font=f(11))) / 2, 356), s, font=f(11), fill=INK2)
    if i == 0:
        arrow(d, x + sw_ + 2, 352, x + sw_ + sg - 4, 352, (128, 158, 136))
    x += sw_ + sg

d.text((46, 398), '第一级：比较与块坐标计算', font=f(12), fill=INK2)
d.text((rx + 58, 398), '第二级：只剩选帧与加法', font=f(12), fill=INK2)
d.text((46, 428), '块内地址在突发期间保持稳定，提前一拍寄存不改变读取顺序；16 字突发约 28 拍，流水代价可忽略。',
       font=f(12), fill=GRN)

# 结果
box(d, 30, 496, 260, 96, '建立余量 WNS', '−2.94 ns → +0.287 ns', 'hdmi', 14, 12)
box(d, 310, 496, 250, 96, '保持余量 WNS', '+0.011 ns，违例 0', 'hdmi', 14, 12)
box(d, 580, 496, 250, 96, '建立违例端点', '12 → 0', 'hdmi', 14, 12)
box(d, 850, 496, 340, 96, 'Fmax（布局后）', '139.6 MHz（10 ns 约束）', 'hdmi', 14, 12)
d.text((30, 606), '改造后数据取自 route.qor 与 final_timing.rpt；改造前为该地址路径在 100 MHz 下的实测 slack。',
       font=f(11), fill=INK2)

img.save(os.path.join(OUT, 'fig_pipeline.png'))
print('fig 2-7', img.size)
