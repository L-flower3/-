# -*- coding: utf-8 -*-
"""生成技术文档用示意图：系统总体框图 + 三种转场读地址映射（v2 正交布线）"""
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
}


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


def lane(d, y0, y1, label, kind):
    fill = KIND[kind][0]
    soft = tuple(int(c + (255 - c) * 0.62) for c in fill)
    d.rounded_rectangle([36, y0, W - 36, y1], radius=12, fill=soft)
    d.text((44, y0 - 21), label, font=f(13, True), fill=KIND[kind][1])


# ===========================================================================
# 图 2-1  系统总体框图
# ===========================================================================
W, H = 1480, 830
img = Image.new('RGB', (W, H), WHITE)
d = ImageDraw.Draw(img)

lane(d, 52, 168, '① 写入域  100 MHz（sd_card_clk）', 'write')
lane(d, 200, 310, '② 存储域  100 MHz（ext_mem_clk）', 'mem')
lane(d, 342, 476, '③ 像素域  25 MHz（video_clk）', 'pix')
lane(d, 508, 622, '④ 输出与音频（HDMI 域与像素域同源节拍）', 'hdmi')
lane(d, 654, 790, '⑤ 控制与指示  50 MHz（clk）', 'ctrl')

# ---------- ① 写入 ----------
y1, h1 = 78, 62
b1 = [(60, 310), (400, 310), (740, 310), (1080, 310)]
t1 = [('TF 卡（SPI）', '24 位 BMP / 48 kHz WAV'),
      ('SD 卡驱动', 'sd_card_top'),
      ('扫描与解析', 'sd_card_bmp / bmp_read'),
      ('帧写 FIFO', '跨域 + 行对齐')]
for (x, w), (t, s) in zip(b1, t1):
    box(d, x, y1, w, h1, t, s, 'write', ts=16, ss=11)
for i in range(3):
    arrow(d, b1[i][0] + b1[i][1], y1 + h1 / 2, b1[i + 1][0] - 3, y1 + h1 / 2, KIND['write'][1])

# ---------- ② SDRAM ----------
sy, sh = 228, 66
d.rounded_rectangle([60, sy, W - 60, sy + sh], radius=10,
                    fill=KIND['mem'][0], outline=KIND['mem'][1], width=2)
d.text((78, sy + 8), '片内 SDRAM  8 MB（2M × 32 bit）　双缓冲共 614400 字', font=f(14, True), fill=KIND['mem'][1])
inner_y = sy + 32
d.rounded_rectangle([78, inner_y, 700, sy + sh - 8], radius=6, fill=WHITE,
                    outline=KIND['mem'][1], width=1)
d.rounded_rectangle([720, inner_y, W - 78, sy + sh - 8], radius=6, fill=WHITE,
                    outline=KIND['mem'][1], width=1)
for txt, cx in (('BUF0　基址 0', 389), ('BUF1　基址 307200（与 BUF0 首尾相邻）', 1040)):
    d.text((cx - d.textlength(txt, font=f(13)) / 2, inner_y + 13), txt, font=f(13), fill=INK)

path(d, [(1235, y1 + h1), (1235, sy - 3)], KIND['write'][1])
d.text((1250, sy - 44), '写满一帧才切换显示指针', font=f(12), fill=KIND['write'][1])

# ---------- ③ 像素处理链 ----------
y3, h3 = 372, 76
chain = [('帧读 + 突发', 'frame_fifo_read'), ('画质调节', 'bright_ctrl'),
         ('转场', 'trans_fade'), ('滚动字幕', 'osd_scroll'),
         ('音频频谱', 'audio_vu'), ('应急叠加', 'emergency_mode')]
cw, gap = 196, 26
tot = 6 * cw + 5 * gap
cx0 = (W - tot) / 2
xc = []
for i, (t, s) in enumerate(chain):
    x = cx0 + i * (cw + gap)
    xc.append(x)
    box(d, x, y3, cw, h3, t, s, 'pix', ts=16, ss=11)
    if i:
        arrow(d, x - gap + 2, y3 + h3 / 2, x - 3, y3 + h3 / 2, KIND['pix'][1])

path(d, [(190, sy + sh), (190, y3 - 3)], KIND['pix'][1])

# 淡变系数回灌（画质 ← 转场）
b_bri = xc[1] + cw / 2
b_tra = xc[2] + cw / 2
path(d, [(b_tra, y3), (b_tra, y3 - 24), (b_bri, y3 - 24), (b_bri, y3 - 3)], KIND['pix'][1], w=2, head=True)
d.text((b_bri + 30, y3 - 54), 'fade 系数回灌（零乘法器）', font=f(11, True), fill=KIND['pix'][1])

# ---------- ④ 输出与音频 ----------
y4, h4 = 534, 64
b4 = [(60, 240, 'WAV 播放', 'wav_player：流式读 + 循环', 'audio'),
      (340, 240, '48 kHz 节拍', '520/521 分数分频', 'audio'),
      (620, 300, 'HDMI 1.4b 发送核', '视频打包 + 音频数据岛（ACR N=6144）', 'hdmi'),
      (960, 200, 'TMDS PHY', '5× DDR 差分输出', 'hdmi'),
      (1200, 220, '显示器', '640×480 @ 60 Hz', 'hdmi')]
for x, w, t, s, k in b4:
    box(d, x, y4, w, h4, t, s, k, ts=15, ss=11)
for i in range(4):
    x = b4[i][0] + b4[i][1]
    arrow(d, x, y4 + h4 / 2, b4[i + 1][0] - 3, y4 + h4 / 2, KIND[b4[i + 1][4]][1])

# 像素 → HDMI（正交折线：从应急叠加底部下到 y4 上方，再进 HDMI 核顶部）
e_cx = xc[5] + cw / 2
h_cx = b4[2][0] + b4[2][1] / 2
path(d, [(e_cx, y3 + h3), (e_cx, y4 - 26), (h_cx, y4 - 26), (h_cx, y4 - 3)], KIND['hdmi'][1])
d.text((h_cx + 8, y4 - 24), 'RGB → AXI4-Stream', font=f(11), fill=KIND['hdmi'][1])

# ---------- ⑤ 控制与指示 ----------
y5, h5 = 686, 60
b5 = [(120, 300, '矩阵键盘 key_scan', '8 键 / 1 kHz 双相位扫描'),
      (480, 300, '状态机与参数', '模式 / 亮度 / 转场 / 应急'),
      (840, 480, 'LED ×8 与 4 位数码管', '版本号与 SD 状态码，免显示器自检')]
for x, w, t, s in b5:
    box(d, x, y5, w, h5, t, s, 'ctrl', ts=15, ss=11)
for i in range(2):
    arrow(d, b5[i][0] + b5[i][1], y5 + h5 / 2, b5[i + 1][0] - 3, y5 + h5 / 2, KIND['ctrl'][1])

# 控制信号（虚线总线示意，不逐条连线）
path(d, [(630, y5), (630, y4 + h4 + 6)], KIND['ctrl'][1], w=2, dash=True)
d.text((642, y4 + h4 + 10), '控制信号送往上述各模块：切图 / 参数 / 转场方式 / 应急',
       font=f(11, True), fill=KIND['ctrl'][1])

img.save(os.path.join(OUT, 'fig_system_block.png'))
print('fig1', img.size)

# ===========================================================================
# 图 2-6  三种转场的读地址映射
# ===========================================================================
W2, H2 = 1500, 500
im2 = Image.new('RGB', (W2, H2), WHITE)
d2 = ImageDraw.Draw(im2)

PW, GAPX = 440, 50
X0 = (W2 - (3 * PW + 2 * GAPX)) / 2
TY = 18
SC = 0.60
SW, SH = int(640 * SC), int(480 * SC)

titles = [
    ('① 匀速滑动（SLIDE）', '平移读起点 + 帧内一次跳转'),
    ('② 淡出淡入（FADE）', '复用画质通路的斜率与偏移'),
    ('③ 旋转擦除（ROTATE）', '降突发至 16 字 + 块边界选源帧'),
]

for i, (t1, t2) in enumerate(titles):
    px = X0 + i * (PW + GAPX)
    d2.rounded_rectangle([px, TY, px + PW, H2 - 24], radius=14,
                         fill=(249, 251, 254), outline=(214, 223, 236), width=2)
    d2.text((px + 20, TY + 16), t1, font=f(18, True), fill=INK)
    d2.text((px + 20, TY + 56), t2, font=f(12), fill=INK2)

    ox = px + (PW - SW) / 2
    oy = TY + 84

    if i == 0:
        d2.rectangle([ox, oy, ox + SW, oy + SH], outline=(118, 128, 146), width=2)
        shift = int(SH * 0.36)
        d2.rectangle([ox + 2, oy + 2, ox + SW - 2, oy + shift], fill=(206, 222, 242))
        d2.rectangle([ox + 2, oy + shift, ox + SW - 2, oy + SH - 2], fill=(238, 226, 210))
        d2.text((ox + 12, oy + 12), '新图（从顶部推入）', font=f(12, True), fill=(46, 84, 150))
        d2.text((ox + 12, oy + shift + 12), '旧图（整体下移）', font=f(12, True), fill=(150, 92, 30))
        # 左侧行标尺
        for yy, lab in ((oy, '0'), (oy + SH / 2, '240'), (oy + SH, '480')):
            d2.line([ox - 8, yy, ox - 2, yy], fill=(150, 162, 182), width=1)
            d2.text((ox - 30, yy - 8), lab, font=f(10), fill=INK2)
        d2.text((ox - 34, oy - 22), '行', font=f(10), fill=INK2)
        # 右侧方向箭头
        arrow(d2, ox + SW + 26, oy + 20, ox + SW + 26, oy + 74, (46, 84, 150), 3)
        d2.text((ox + SW + 34, oy + 34), '每帧\n10 行', font=f(11), fill=INK2, spacing=3)
        bx, by = ox, oy + SH + 22
        d2.text((bx, by), '读地址 = 起始帧基址 + 帧内偏移', font=f(12), fill=INK)
        d2.text((bx, by + 24), '48 帧走完一屏，不需要行缓冲', font=f(12, True), fill=(44, 122, 75))

    elif i == 1:
        gx, gy = ox + 26, oy + 34
        gw, gh = SW - 56, SH - 74
        d2.line([gx, gy + gh, gx + gw, gy + gh], fill=(140, 152, 170), width=2)
        d2.line([gx, gy + gh, gx, gy - 6], fill=(140, 152, 170), width=2)
        for k in range(5):
            yy = gy + gh * k / 4
            d2.line([gx, yy, gx + gw, yy], fill=(233, 238, 245), width=1)
        pts = []
        n = 80
        for k in range(n + 1):
            tt = k / n
            v = 1 - tt * 2 if tt <= 0.5 else (tt - 0.5) * 2
            pts.append((gx + gw * tt, gy + gh * (1 - v)))
        d2.line(pts, fill=(184, 92, 30), width=4)
        d2.text((gx - 22, gy - 20), '亮度', font=f(11), fill=INK2)
        d2.text((gx + gw - 8, gy + gh + 6), '帧', font=f(11), fill=INK2)
        d2.text((gx + gw * 0.5 - 46, gy + gh * 0.34), '17 档 · 每档 1 帧', font=f(11, True), fill=(184, 92, 30))
        d2.text((gx + gw * 0.5 - 52, gy + gh + 20), '换图藏在全黑那一帧', font=f(11), fill=INK2)
        bx, by = ox, oy + SH + 22
        d2.text((bx, by), "k′ = k × fade / 16，offset′ 同理", font=f(12), fill=INK)
        d2.text((bx, by + 24), '系数每帧变一次，像素通路零新增乘法器', font=f(12, True), fill=(44, 122, 75))

    else:
        ccx, ccy = ox + SW / 2 - 6, oy + SH / 2 - 4
        rad = 96
        # 未扫过（旧图）整圆
        d2.ellipse([ccx - rad, ccy - rad, ccx + rad, ccy + rad], fill=(238, 226, 210))
        # 已扫过扇形 0°~130°（自 12 点顺时针）
        a0, a1 = -90, 40
        pts = [(ccx, ccy)]
        for k in range(49):
            ang = math.radians(a0 + (a1 - a0) * k / 48)
            pts.append((ccx + rad * math.cos(ang), ccy + rad * math.sin(ang)))
        d2.polygon(pts, fill=(206, 222, 242))
        d2.ellipse([ccx - rad, ccy - rad, ccx + rad, ccy + rad],
                   outline=(118, 128, 146), width=2)
        ang = math.radians(a1)
        d2.line([ccx, ccy, ccx + rad * math.cos(ang), ccy + rad * math.sin(ang)],
                fill=(184, 92, 30), width=4)
        d2.text((ccx + 16, ccy + 26), '分界线', font=f(11, True), fill=(184, 92, 30))
        d2.text((ccx + 26, ccy - 78), '新图', font=f(12, True), fill=(46, 84, 150))
        d2.text((ccx - 78, ccy + 40), '旧图', font=f(12, True), fill=(150, 92, 30))
        # 16 像素块示意（圆右下外侧）
        gx, gy, cs = ox + SW - 92, oy + SH - 62, 34
        for r in range(2):
            for c in range(2):
                fillc = (206, 222, 242) if (r + c) % 2 == 0 else (238, 226, 210)
                d2.rectangle([gx + c * cs, gy + r * cs, gx + (c + 1) * cs, gy + (r + 1) * cs],
                             fill=fillc, outline=(118, 128, 146), width=1)
        d2.text((gx - 6, gy - 18), '16 像素/块', font=f(10), fill=INK2)
        bx, by = ox, oy + SH + 22
        d2.text((bx, by), '每块 16 字：选 BUF0（旧）或 BUF1（新）', font=f(12), fill=INK)
        d2.text((bx, by + 24), '48 帧 × 7.5° 转满一圈，末帧整屏新图', font=f(12, True), fill=(44, 122, 75))

im2.save('fig_transition_map.png')
print('fig2', im2.size)
