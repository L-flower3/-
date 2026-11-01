# -*- coding: utf-8 -*-
"""生成现场演示视频台词本 docx（时间码由字数反算，避免估错）"""
import os
import re
from docx import Document
from docx.shared import Pt, Cm, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK
from docx.oxml.ns import qn
from docx.oxml import OxmlElement

BASE = r'D:\Work buddy Project\zuizhong_V26_V34\zuizhong_V26'
DOC = os.path.join(BASE, '现场演示视频台词_CHR战队_V1.docx')

F_HEI = '黑体'
F_SONG = '宋体'
F_EN = 'Times New Roman'
C_H1 = RGBColor(0x1F, 0x3B, 0x63)
C_TAG = RGBColor(0x2E, 0x54, 0x96)
C_GRAY = RGBColor(0x59, 0x59, 0x59)

CPS = 220.0  # 汉字/分钟

# ============================================================
# 台词数据：no, 段落名, 画面, 台词列表, 操作停顿(秒), 提示
# ============================================================
SHOTS = [
    ('01', '开场', '整机正面全景，屏幕已出图，灯光均匀',
     ['各位评委老师好，我们是 CHR 战队。下面演示我们的参赛作品《以芯止戈》，'
      '一套完全跑在 FPGA 内部的 HDMI 音视频播放系统。'],
     1, None),
    ('02', '团队', '队员出镜，或字幕条叠在整机画面上',
     ['团队共 [人数] 人，[姓名] 负责 RTL 与时序，[姓名] 负责板级调试，[姓名] 负责文档与录制。'],
     1, '姓名与分工须与报名表一致；单人队改为“这套系统由我一人完成”。'),
    ('03', '作品定位', '开发板特写，手指点向 FPGA 芯片与 TF 卡座',
     ['整个系统只用了一片安路 EG4S20BG256，板上没有处理器，没有操作系统，也没有外挂 DDR。'],
     1, None),
    ('04', '问题', '屏幕出图与开发板同框，缓慢推近',
     ['我们要解决的问题是：在一片中小规模 FPGA 上，怎样让开发板自己读出 TF 卡里的图片，'
      '并稳定送上 HDMI 显示器。'],
     1, None),
    ('05', '方案', '技术文档图 2-1 系统框图叠在实拍画面上',
     ['整条链路做成纯硬件流水线：SPI 读卡，片内 SDRAM 做两块帧缓存交替读写，'
      '像素域完成画质、转场与字幕，最后由 HDMI 1.4b 发送核送出。'],
     2, None),
    ('06', '时钟域', '回到实拍，画面稳定运行',
     ['系统跑在三个时钟域：读卡写帧 100 兆，像素 25 兆，控制 50 兆，'
      '跨域只走异步 FIFO 的格雷码指针，所以画面不会撕裂。'],
     1, None),
    ('07', '上电', '断电特写 → 拨动电源 → 数码管与 LED 亮起（一镜到底）',
     ['现在上电。数码管先显示版本号，随后 8 个 LED 依次点亮，'
      '对应 SD 卡初始化、扫描扇区和首帧写入三个节点。'],
     4, '此镜必须一镜到底，不剪辑。评委判断稳定性主要看这一段。'),
    ('08', '首图', '屏幕由黑转出第一张图片',
     ['首帧写满整块缓存之后，画面自动切到第一张图，中间没有花屏。'],
     2, '若首帧确实较慢，在镜头里打字幕说明正在扫描扇区，主动交代优于让评委猜。'),
    ('09', '切图', '按 KEY1 切下一张，再按 KEY0 切回',
     ['按 KEY1 切下一张，KEY0 切回上一张。新图先写进另一块缓存，'
      '写满 307200 个像素才切换显示指针。'],
     2, None),
    ('10', '轮播', '按 KEY2，画面连续自动切换',
     ['按 KEY2 开启轮播，每秒一张，全程不撕裂。'],
     3, None),
    ('11', '滑动', '按 KEY7 切到滑动，完整录一次',
     ['转场由 KEY7 循环切换。第一种是滑动，整幅画面连续推移。'],
     3, None),
    ('12', '淡变', '再按 KEY7 切到淡变',
     ['第二种是淡变，画面先压暗再提亮。这一路没有增加乘法器，'
      '系数并进了画质通路的斜率与偏移。'],
     3, None),
    ('13', '旋转擦除', '再按 KEY7 切到旋转擦除，先 0.3 倍慢放，再补正常速度',
     ['第三种是旋转擦除，我们花时间最多的一种。一条分界线绕中心转一圈，'
      '新图随扫过的扇区渐次显现，转满一圈约 800 毫秒。',
      '我们没有做二维重采样，而是把读突发从 128 字降到 16 字，'
      '在每 16 像素块的边界上换源帧，用一条转动的分界线换来同样的观感。'],
     6, '800 毫秒在视频里一闪就过，必须慢放，并在角标注明倍数。'),
    ('14', '画质调节', '长按 KEY6 切换对象，OSD 变化；KEY3/KEY4 调档',
     ['KEY3、KEY4 调当前参数，长按连发；长按 KEY6 切换亮度与对比度，'
      '左上角 OSD 实时显示档位。'],
     4, None),
    ('15', '滚动字幕', '镜头靠近屏幕底部，字幕滚动特写',
     ['字幕全程滚动，中英双语同速，每帧一个像素，约每秒 60 像素；'
      '白字黑描边加渐变暗底，压亮背景也读得清。'],
     3, None),
    ('16', '音频', '镜头带到 HDMI 线，画面中音乐响起',
     ['声音走同一条 HDMI 线。系统扫描 WAV 的 RIFF 头，流式读 data 段，'
      '用 520/521 分频得到 48 千赫兹，再按 ACR 写进数据岛。'],
     4, '只保留作品自身播放的音乐，不要另配 BGM，否则分不清声音来源。'),
    ('17', '频谱', '按 KEY6 打开频谱，八段柱随节拍起伏',
     ['KEY6 打开频谱。八段柱子对应 100 赫兹到 11 千赫兹，'
      '落下约需 0.45 秒，所以它跟得上节拍。'],
     3, None),
    ('18', '应急画面', '按 KEY5 进入，屏幕切到固定图案，警报音起；再按一次退出',
     ['KEY5 进入应急画面。这一路直接从片内 ROM 出，不经过帧缓存，'
      '卡读不出来也有画面，同时锁定切图键防止误触。'],
     4, None),
    ('19', '状态指示', '数码管与 LED 特写',
     ['数码管和 LED 全程报状态。调试时我们不看屏幕，光凭这两个器件就知道卡在哪一步。'],
     2, None),
    ('20', '指标', '切到资源与时序数据页，或叠加大字指标',
     ['最后是数据。TD 5.6.2 布局布线后 LUT 用 7959 个，占 40.6%；'
      'DSP 13 个共 29；BRAM 33 块共 64。建立余量 +0.287 纳秒，'
      '保持余量 +0.011 纳秒，无违例端点。',
      '这组数字背后改过一次结构：地址计算原来串在一拍里，100 兆下 slack 是负 2.94 纳秒，'
      '12 个端点违例；把最后一段寄存一拍、拆成两级流水，才把它拉回正数。'],
     2, '数字念慢一点，让评委记下来。'),
    ('21', '收尾', '回到整机全景，屏幕正常播放',
     ['以上就是《以芯止戈》的全部演示，谢谢各位评委老师。'],
     1, None),
]

CN = lambda t: len(re.findall(r'[\u4e00-\u9fa5]', t))


def fmt(sec):
    sec = int(round(sec))
    return '%d:%02d' % (sec // 60, sec % 60)


timeline = []
t = 0.0
total_cn = 0
for no, sec_name, scene, lines, pause, note in SHOTS:
    n = sum(CN(x) for x in lines)
    total_cn += n
    dur = n / CPS * 60 + pause
    timeline.append((no, t, t + dur, n, dur))
    t += dur
TOTAL = t
PAUSE_SUM = sum(x[4] for x in SHOTS)

d = Document()
for s in d.sections:
    s.page_width, s.page_height = Cm(21.0), Cm(29.7)
    s.left_margin = s.right_margin = Cm(2.8)
    s.top_margin = s.bottom_margin = Cm(2.54)


def font(r, cn=F_SONG, en=F_EN, size=12, bold=False, color=None):
    r.font.name = en
    r.font.size = Pt(size)
    r.font.bold = bold
    if color is not None:
        r.font.color.rgb = color
    rPr = r._element.get_or_add_rPr()
    rF = rPr.find(qn('w:rFonts'))
    if rF is None:
        rF = OxmlElement('w:rFonts')
        rPr.append(rF)
    rF.set(qn('w:eastAsia'), cn)
    rF.set(qn('w:ascii'), en)
    rF.set(qn('w:hAnsi'), en)
    return r


def P(text, indent=True, size=12, cn=F_SONG, bold=False, color=None,
      align=WD_ALIGN_PARAGRAPH.JUSTIFY, sb=0, sa=6, ls=1.5):
    p = d.add_paragraph()
    p.alignment = align
    pf = p.paragraph_format
    pf.first_line_indent = Pt(size * 2) if indent else Pt(0)
    pf.space_before = Pt(sb)
    pf.space_after = Pt(sa)
    pf.line_spacing = ls
    font(p.add_run(text), cn=cn, size=size, bold=bold, color=color)
    return p


def H(text, lvl=2):
    p = d.add_paragraph()
    pf = p.paragraph_format
    pf.first_line_indent = Pt(0)
    pf.space_before = Pt(20 if lvl == 1 else 15)
    pf.space_after = Pt(9 if lvl == 1 else 6)
    pf.line_spacing = 1.3
    pf.keep_with_next = True
    font(p.add_run(text), cn=F_HEI, en='Arial',
         size={1: 17, 2: 13.5}[lvl], bold=True, color=C_H1)
    pPr = p._element.get_or_add_pPr()
    ol = OxmlElement('w:outlineLvl')
    ol.set(qn('w:val'), str(lvl - 1))
    pPr.append(ol)
    return p


def shot(tag, scene):
    p = d.add_paragraph()
    pf = p.paragraph_format
    pf.first_line_indent = Pt(0)
    pf.space_before = Pt(11)
    pf.space_after = Pt(4)
    pf.line_spacing = 1.25
    pf.keep_with_next = True
    font(p.add_run(tag), cn=F_HEI, en='Arial', size=10.5, bold=True, color=C_TAG)
    font(p.add_run('　｜　' + scene), cn=F_HEI, en='Arial', size=10, color=C_GRAY)
    pPr = p._element.get_or_add_pPr()
    pbdr = OxmlElement('w:pBdr')
    left = OxmlElement('w:left')
    left.set(qn('w:val'), 'single')
    left.set(qn('w:sz'), '18')
    left.set(qn('w:space'), '8')
    left.set(qn('w:color'), '2E5496')
    pbdr.append(left)
    pPr.append(pbdr)
    return p


def say(text, size=12):
    p = d.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.JUSTIFY
    pf = p.paragraph_format
    pf.first_line_indent = Pt(24)
    pf.left_indent = Pt(14)
    pf.space_before = Pt(2)
    pf.space_after = Pt(6)
    pf.line_spacing = 1.55
    font(p.add_run(text), size=size)
    return p


def note(text):
    p = d.add_paragraph()
    pf = p.paragraph_format
    pf.first_line_indent = Pt(0)
    pf.left_indent = Pt(14)
    pf.space_after = Pt(10)
    pf.line_spacing = 1.4
    font(p.add_run('※ ' + text), cn=F_HEI, en='Arial', size=9.5, color=C_GRAY)
    return p


def hr():
    p = d.add_paragraph()
    p.paragraph_format.space_before = Pt(2)
    p.paragraph_format.space_after = Pt(2)
    pPr = p._element.get_or_add_pPr()
    pbdr = OxmlElement('w:pBdr')
    bot = OxmlElement('w:bottom')
    bot.set(qn('w:val'), 'single')
    bot.set(qn('w:sz'), '6')
    bot.set(qn('w:space'), '1')
    bot.set(qn('w:color'), 'BFBFBF')
    pbdr.append(bot)
    pPr.append(pbdr)


def thcell(c, text, size=10):
    c.text = ''
    pr = c.paragraphs[0]
    pr.alignment = WD_ALIGN_PARAGRAPH.CENTER
    pr.paragraph_format.space_before = Pt(2)
    pr.paragraph_format.space_after = Pt(2)
    font(pr.add_run(text), cn=F_HEI, en='Arial', size=size, bold=True,
         color=RGBColor(0xFF, 0xFF, 0xFF))
    sh = OxmlElement('w:shd')
    sh.set(qn('w:fill'), '2E5496')
    c._tc.get_or_add_tcPr().append(sh)


# ============================================================
# 封面
# ============================================================
p = d.add_paragraph()
p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.paragraph_format.space_before = Pt(26)
p.paragraph_format.space_after = Pt(6)
font(p.add_run('现场演示视频解说台词'), cn=F_HEI, en='Arial', size=24, bold=True, color=C_H1)

p = d.add_paragraph()
p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.paragraph_format.space_after = Pt(6)
font(p.add_run('《以芯止戈》——基于 FPGA 的纯硬件 HDMI 音视频播放与可视化系统'),
     cn=F_HEI, en='Arial', size=12, color=C_TAG)

p = d.add_paragraph()
p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.paragraph_format.space_after = Pt(4)
font(p.add_run('CHR 战队　｜　共 21 个镜头　｜　%s 字　｜　估算成片 %s'
               % (format(total_cn, ','), fmt(TOTAL))), size=11, color=C_GRAY)

p = d.add_paragraph()
p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.paragraph_format.space_after = Pt(20)
font(p.add_run('全国大学生嵌入式芯片与系统设计竞赛·安路科技赛道·选题一'),
     size=10, color=C_GRAY)

hr()

p = d.add_paragraph()
p.paragraph_format.space_before = Pt(8)
p.paragraph_format.space_after = Pt(5)
font(p.add_run('使用说明'), cn=F_HEI, en='Arial', size=11, bold=True, color=C_H1)

for tt in [
    '全稿按“问好 → 团队 → 作品定位 → 方案与架构 → 逐项功能 → 指标 → 收尾”排列，'
    '功能段与操作动作一一对应，念到哪一句就按哪个键。',
    '方括号内是需团队自行填入的真实信息（学校、姓名、上电实测秒数），不要照读括号。',
    '时间码由每镜台词字数按 220 字／分钟推算，再加操作停顿，属估算值；'
    '定稿前请计时通读一遍，按实际语速微调。',
    '画面提示中的“KEY”指板上丝印的按键名，与第二节的按键对照表一一对应。',
]:
    p = d.add_paragraph()
    p.paragraph_format.first_line_indent = Pt(0)
    p.paragraph_format.left_indent = Pt(16)
    p.paragraph_format.space_after = Pt(4)
    p.paragraph_format.line_spacing = 1.45
    font(p.add_run('· ' + tt), size=10.5, color=RGBColor(0x33, 0x33, 0x33))

p = d.add_paragraph()
p.paragraph_format.left_indent = Pt(16)
p.paragraph_format.space_before = Pt(10)
p.paragraph_format.space_after = Pt(6)
p.paragraph_format.line_spacing = 1.7
font(p.add_run('本稿共分四节：第一节是带画面提示的分镜台词，拍摄与剪辑时对着它走；'
               '第二节是按键与术语对照，用来统一念法；第三节是去掉提示的连读版，配音时只用这一节；'
               '第四节是时长核对、拍摄建议与删减顺序。'),
     size=10.5, color=RGBColor(0x33, 0x33, 0x33))

# 三条硬要求
tbk = d.add_table(rows=1, cols=1)
tbk.alignment = 1
cell = tbk.rows[0].cells[0]
cell.width = Cm(14.8)
tcPr = cell._tc.get_or_add_tcPr()
sh = OxmlElement('w:shd')
sh.set(qn('w:fill'), 'EEF3FA')
tcPr.append(sh)
# 边框
borders = OxmlElement('w:tcBorders')
for edge in ('top', 'left', 'bottom', 'right'):
    e = OxmlElement('w:%s' % edge)
    e.set(qn('w:val'), 'single')
    e.set(qn('w:sz'), '6')
    e.set(qn('w:color'), 'A9C1E0')
    borders.append(e)
tcPr.append(borders)

cell.text = ''
first = cell.paragraphs[0]
first.paragraph_format.space_before = Pt(10)
first.paragraph_format.space_after = Pt(4)
first.paragraph_format.line_spacing = 1.4
font(first.add_run('三条不能动的规矩'), cn=F_HEI, en='Arial', size=10.5, bold=True, color=C_H1)

for i, tt in enumerate([
    '上电那一段一镜到底，不剪辑、不加转场，这是全片唯一的稳定性证据。',
    '旋转擦除必须慢放，并在画面角标注明倍数，否则 800 毫秒一闪而过，评委看不见。',
    '指标段不删。开场的创意和结尾的数据，是评委最容易记住的两头。',
]):
    q = cell.add_paragraph()
    q.paragraph_format.space_before = Pt(0)
    q.paragraph_format.space_after = Pt(3 if i < 2 else 10)
    q.paragraph_format.line_spacing = 1.45
    font(q.add_run('· ' + tt), size=10, color=RGBColor(0x22, 0x22, 0x22))

# ============================================================
# 一、分镜台词
# ============================================================
d.add_page_break()
H('一　分镜台词', 1)
P('每镜给出时间码、画面提示与口播文字。时间码左端为该镜开始处，右端为结束处。',
  indent=True, size=10.5, color=C_GRAY, sa=8)

for (no, sec_name, scene, lines, pause, nt), (_, s0, s1, n, dur) in zip(SHOTS, timeline):
    shot('镜 %s　%s–%s' % (no, fmt(s0), fmt(s1)), scene)
    for ln in lines:
        say(ln)
    if nt:
        note(nt)

# ============================================================
# 二、按键对照
# ============================================================
d.add_page_break()
H('二　按键与功能对照', 1)
H('2.1　按键一览', 2)
P('下表按板上丝印的键名列出口播中提到的每一个按键，供录制时核对，避免念错键名。',
  indent=True, size=10.5, color=C_GRAY, sa=8)

KEYS = [
    ('KEY0', '上一张图片；转场方式为旋转擦除时决定逆时针', '镜 09、镜 13'),
    ('KEY1', '下一张图片；转场方式为旋转擦除时决定顺时针', '镜 09、镜 13'),
    ('KEY2', '自动轮播 开 / 关', '镜 10'),
    ('KEY3', '当前参数递减（长按 200 ms 连发）', '镜 14'),
    ('KEY4', '当前参数递增（长按 200 ms 连发）', '镜 14'),
    ('KEY5', '应急模式 进入 / 退出', '镜 18'),
    ('KEY6', '短按：音频频谱 开 / 关；长按 0.8 s：切换调节对象', '镜 14、镜 17'),
    ('KEY7', '转场方式循环：滑动 → 淡变 → 旋转擦除', '镜 11–13'),
]

tbl = d.add_table(rows=1, cols=3)
tbl.style = 'Table Grid'
tbl.alignment = 1
widths = [Cm(2.2), Cm(9.0), Cm(3.6)]
for i, h in enumerate(['按键', '功能', '对应镜头']):
    thcell(tbl.rows[0].cells[i], h)

for k, v, pos in KEYS:
    row = tbl.add_row()
    for i, val in enumerate([k, v, pos]):
        c = row.cells[i]
        c.text = ''
        pr = c.paragraphs[0]
        pr.paragraph_format.space_before = Pt(2)
        pr.paragraph_format.space_after = Pt(2)
        pr.paragraph_format.line_spacing = 1.15
        pr.alignment = WD_ALIGN_PARAGRAPH.CENTER if i != 1 else WD_ALIGN_PARAGRAPH.LEFT
        font(pr.add_run(val), cn=F_HEI if i == 0 else F_SONG, en='Arial',
             size=9.5, bold=(i == 0), color=C_TAG if i == 0 else RGBColor(0x22, 0x22, 0x22))
for row in tbl.rows:
    for i, c in enumerate(row.cells):
        c.width = widths[i]

P('注：KEY0 与 KEY1 在常态下是上一张与下一张；当转场方式切换到旋转擦除后，'
  '这两个键用来指定旋转方向，KEY1 对应顺时针、KEY0 对应逆时针。',
  indent=True, size=10, color=C_GRAY, sb=8, sa=12)

H('2.2　数字与型号的读法', 2)
P('下面这些写法直接照着念容易卡壳或念错，录制前统一一遍。左列是文稿写法，右列是口播读法。',
  indent=True, size=10.5, sa=6)

READ = [
    ('EG4S20BG256', 'E-G-4-S-20-B-G-256，逐段念，不连读'),
    ('TD 5.6.2', 'T-D 五点六点二'),
    ('HDMI 1.4b', 'HDMI 一点四 b'),
    ('7959', '七千九百五十九'),
    ('19600', '一万九千六百'),
    ('40.6%', '百分之四十点六'),
    ('307200', '三十万七千二百'),
    ('520/521 分频', '五百二十与五百二十一交替分频'),
    ('+0.287 ns', '正零点二八七纳秒'),
    ('+0.011 ns', '正零点零一一纳秒'),
    ('100 兆 / 25 兆 / 50 兆', '一百兆赫兹、二十五兆赫兹、五十兆赫兹'),
]

tb3 = d.add_table(rows=1, cols=2)
tb3.style = 'Table Grid'
tb3.alignment = 1
w3 = [Cm(5.4), Cm(9.4)]
for i, h in enumerate(['文稿写法', '口播读法']):
    thcell(tb3.rows[0].cells[i], h, 9.5)

for a, b in READ:
    row = tb3.add_row()
    for i, val in enumerate([a, b]):
        c = row.cells[i]
        c.text = ''
        pr = c.paragraphs[0]
        pr.paragraph_format.line_spacing = 1.15
        pr.paragraph_format.space_before = Pt(1)
        pr.paragraph_format.space_after = Pt(1)
        pr.alignment = WD_ALIGN_PARAGRAPH.LEFT
        font(pr.add_run(val), size=9.5, cn=F_SONG, en='Arial',
             color=C_TAG if i == 0 else RGBColor(0x22, 0x22, 0x22))
for row in tb3.rows:
    for i, c in enumerate(row.cells):
        c.width = w3[i]

d.add_paragraph().add_run().add_break(WD_BREAK.PAGE)
H('2.3　术语口径统一', 2)
P('同一样东西在一段解说里换三种叫法，评委会以为你在说三个模块。下面四个词建议全片只用一个说法。',
  indent=True, size=10.5, sa=6)

TERMS = [
    ('帧缓存', '双缓冲、乒乓 buffer', '“帧缓存”是评委最熟的说法，且与图 2-2 一致'),
    ('读突发 / 写突发', 'burst、BURST_LEN', '中文优先，确需提英文时可括注一次'),
    ('像素域', '视频时钟域', '本稿第三节已定义一次，后面全用“像素域”'),
    ('分界线', '扫描线、擦除线', '与“扫描扇区”区分开，避免两个“扫描”打架'),
]

tb4 = d.add_table(rows=1, cols=3)
tb4.style = 'Table Grid'
tb4.alignment = 1
w4 = [Cm(3.4), Cm(4.4), Cm(7.0)]
for i, h in enumerate(['固定叫法', '避免的说法', '理由']):
    thcell(tb4.rows[0].cells[i], h, 9.5)

for a, b, c3 in TERMS:
    row = tb4.add_row()
    for i, val in enumerate([a, b, c3]):
        c = row.cells[i]
        c.text = ''
        pr = c.paragraphs[0]
        pr.paragraph_format.line_spacing = 1.15
        pr.paragraph_format.space_before = Pt(1)
        pr.paragraph_format.space_after = Pt(1)
        pr.alignment = WD_ALIGN_PARAGRAPH.LEFT if i != 1 else WD_ALIGN_PARAGRAPH.LEFT
        font(pr.add_run(val), size=9.5, cn=F_SONG, en='Arial',
             color=C_TAG if i == 0 else RGBColor(0x22, 0x22, 0x22))
for row in tb4.rows:
    for i, c in enumerate(row.cells):
        c.width = w4[i]

H('2.4　口播自查清单', 2)
P('录制前对着这份清单通读一遍，能避免大部分现场口误。以下各条是经验性建议，不是硬性规定。',
  indent=True, size=10.5, color=C_GRAY, sa=6)
for tt in [
    '三个时钟域的顺序固定为 100、25、50，不要一会儿说“像素 25 兆”，一会儿说“视频 25 兆”。',
    '单位全稿统一用中文：纳秒、毫秒、千赫兹、兆赫兹。不要在同一段里混用 ns 与“纳秒”。',
    '每念完一个数字停半拍，给评委留下记录的时间；指标段尤其不能赶。',
    '讲到旋转擦除时把语速压下来，这是全片最主要的技术攻坚点，念快了评委抓不住。',
    '收尾一句要干脆，说完“谢谢各位评委老师”就停，不要补“作品还有很多不足”之类的客套。',
]:
    p = d.add_paragraph()
    p.paragraph_format.first_line_indent = Pt(0)
    p.paragraph_format.left_indent = Pt(16)
    p.paragraph_format.space_after = Pt(5)
    p.paragraph_format.line_spacing = 1.55
    font(p.add_run('· ' + tt), size=10.5, color=RGBColor(0x33, 0x33, 0x33))

# ============================================================
# 三、纯台词连读版
# ============================================================
d.add_page_break()
H('三　纯台词连读版（配音／背稿用）', 1)
P('本节删去画面提示与提示语，文字与第一节完全一致，供配音与背稿使用。',
  indent=True, size=10.5, color=C_GRAY, sa=10)

for (no, sec_name, scene, lines, pause, nt), (_, s0, s1, n, dur) in zip(SHOTS, timeline):
    p = d.add_paragraph()
    p.paragraph_format.space_before = Pt(10)
    p.paragraph_format.space_after = Pt(2)
    p.paragraph_format.first_line_indent = Pt(0)
    p.paragraph_format.keep_with_next = True
    font(p.add_run('%s　[%s–%s]' % (sec_name, fmt(s0), fmt(s1))),
         cn=F_HEI, en='Arial', size=10, bold=True, color=C_TAG)
    for ln in lines:
        q = d.add_paragraph()
        q.alignment = WD_ALIGN_PARAGRAPH.JUSTIFY
        pf = q.paragraph_format
        pf.first_line_indent = Pt(24)
        pf.space_before = Pt(0)
        pf.space_after = Pt(8)
        pf.line_spacing = 1.85
        font(q.add_run(ln), size=12)

# ============================================================
# 四、时长与拍摄
# ============================================================
d.add_page_break()
H('四　时长核对与拍摄建议', 1)

H('4.1　时间分配', 2)
P('全稿共 %s 个汉字。按每分钟 220 字计算，纯口播约 %s，加按键与画面停留的 %d 秒，'
  '估算成片 %s，落在多数赛区 5 分钟的限制以内。若赛区限时 3 分钟，可按 4.3 的顺序整镜删除。'
  % (format(total_cn, ','), fmt(total_cn / CPS * 60), PAUSE_SUM, fmt(TOTAL)))

tb2 = d.add_table(rows=1, cols=3)
tb2.style = 'Table Grid'
tb2.alignment = 1
w2 = [Cm(7.2), Cm(3.4), Cm(4.2)]
for i, h in enumerate(['段落', '镜头', '时长']):
    thcell(tb2.rows[0].cells[i], h, 9.5)

GROUPS = [
    ('开场与团队', ['01', '02']),
    ('作品定位与问题', ['03', '04']),
    ('方案与时钟域', ['05', '06']),
    ('上电与首图', ['07', '08']),
    ('切图与轮播', ['09', '10']),
    ('三种转场', ['11', '12', '13']),
    ('画质与字幕', ['14', '15']),
    ('音频与频谱', ['16', '17']),
    ('应急与状态', ['18', '19']),
    ('指标与收尾', ['20', '21']),
]
TL = {x[0]: x for x in timeline}
for gname, ids in GROUPS:
    gdur = sum(TL[i][4] for i in ids)
    row = tb2.add_row()
    vals = [gname, '、'.join(ids), '%d 秒' % round(gdur)]
    for i, val in enumerate(vals):
        c = row.cells[i]
        c.text = ''
        pr = c.paragraphs[0]
        pr.paragraph_format.line_spacing = 1.15
        pr.alignment = WD_ALIGN_PARAGRAPH.LEFT if i == 0 else WD_ALIGN_PARAGRAPH.CENTER
        font(pr.add_run(val), size=9.5, cn=F_SONG, en='Arial')
for row in tb2.rows:
    for i, c in enumerate(row.cells):
        c.width = w2[i]

H('4.2　拍摄与剪辑', 2)
for tt in [
    '固定三个机位：整机正面全景、屏幕特写、键盘与数码管特写。三机位同时录，后期按台词切，'
    '避免现场手忙脚乱。',
    '上电那一段一镜到底，不剪辑。这是评委判断稳定性的唯一依据。',
    '旋转擦除与淡变加慢放，慢放倍数在画面角标注明，不要让人误以为是实时速度。',
    '念到“按 KEY5”时，画面里必须正在按 KEY5。声音与动作差半秒，专业感就掉了。',
    '只保留作品自身播放的音乐，不另配 BGM，否则评委会分不清声音是不是板子发出来的。',
    '桌面只留开发板、HDMI 线、电源与 TF 卡。画面越干净，越像成品而不是实验台。',
]:
    p = d.add_paragraph()
    p.paragraph_format.first_line_indent = Pt(0)
    p.paragraph_format.left_indent = Pt(16)
    p.paragraph_format.space_after = Pt(4)
    p.paragraph_format.line_spacing = 1.5
    font(p.add_run('· ' + tt), size=10.5)

H('4.3　压到 3 分钟以内的删减顺序', 2)
P('若赛区限时 3 分钟，按下列顺序整镜删除，删到够用为止。'
  '镜 07、镜 13、镜 20 三段建议保留，它们分别是稳定性证据、技术含量与量化结果。',
  indent=True, size=10.5, sa=6)
DEL = [('镜 06', '时钟域', '25 秒'), ('镜 19', '状态指示', '15 秒'),
       ('镜 10', '轮播', '18 秒'), ('镜 12', '淡变', '15 秒'),
       ('镜 15', '滚动字幕', '22 秒')]
for a, b, c3 in DEL:
    p = d.add_paragraph()
    p.paragraph_format.first_line_indent = Pt(0)
    p.paragraph_format.left_indent = Pt(16)
    p.paragraph_format.space_after = Pt(3)
    p.paragraph_format.line_spacing = 1.45
    font(p.add_run('· 删 %s（%s），省约 %s' % (a, b, c3)), size=10.5)

P('五镜全删约省 1 分 35 秒，成片落到 3 分钟以内，此时可再从镜 02、镜 05 各删一句。'
  '反过来说，若赛区允许 8 分钟，镜 13 与镜 20 各有一句可展开细讲的余量，'
  '展开后按现有语速约增加 40 秒。',
  indent=True, size=10.5, sa=8)

H('4.4　需团队核实后填入的空位', 2)
for tt in [
    '学校名称与队名全称：若报名表队名与“CHR 战队”不同，开场第一句须改成报名表写法。',
    '队员人数与分工：三人队与单人队说法不同，单人队改为“这套系统由我一人完成”。',
    '上电到首帧的实际秒数：若确实需要较长时间，建议在镜头里打字幕说明正在扫描扇区。',
]:
    p = d.add_paragraph()
    p.paragraph_format.first_line_indent = Pt(0)
    p.paragraph_format.left_indent = Pt(16)
    p.paragraph_format.space_after = Pt(4)
    p.paragraph_format.line_spacing = 1.5
    font(p.add_run('· ' + tt), size=10.5)

H('4.5　参考来源', 2)
refs = [
    '“【英咖师生面对面】第77期 玩转竞赛——全国大学生嵌入式芯片与系统设计竞赛.” '
    '电子科技大学英才实验学院, www.yingcai.uestc.edu.cn/info/1022/7072.htm. 2026年10月31日访问.',
    '“答辩十分钟：问题、指标、对照实验.” 成电国芯FPGA云课堂, z.shaonianxue.cn/71382.html. '
    '2026年10月31日访问.',
]
for i, tt in enumerate(refs, 1):
    p = d.add_paragraph()
    p.paragraph_format.first_line_indent = Pt(-18)
    p.paragraph_format.left_indent = Pt(18)
    p.paragraph_format.space_after = Pt(4)
    p.paragraph_format.line_spacing = 1.4
    font(p.add_run('[%d]　%s' % (i, tt)), size=9.5, color=C_GRAY)

P('本稿的叙事骨架取自上述两条公开建议：前者提出演示视频应按创意简介、架构说明、实物演示、'
  '对比实验与指标总结排布，并删减冗余镜头以提升信息密度；后者提出口播只保留要解决的问题、'
  '给出的指标与对照实验的差值。台词文本为原创撰写，未复制任何现成稿件。',
  indent=True, size=10.5, color=C_GRAY, sa=10)

H('4.6　可验证事实与本稿推测的区分', 2)
P('可验证部分：文中全部工程参数均取自本工程源码与 TD 5.6.2 布局布线报告，包括 LUT 7959 个、'
  'DSP 13 个、BRAM 33 块、建立余量 +0.287 纳秒、保持余量 +0.011 纳秒、旋转擦除约 800 毫秒、'
  '读突发 16 字与写突发 256 字、单帧 307200 像素、音频 48 千赫兹与 520/521 分频、ACR N=6144、'
  '字幕每帧 1 像素、频谱 8 段与 0.45 秒缓降、亮度 8 档与对比度 7 档、按键功能分配。'
  '以上可在 route.qor、final_timing.rpt、sd_hdmi_bmp.adc 与技术文档 V5 中逐项核对。')
P('属推测部分：每分钟 220 字的语速、由字数推算的各镜时间码与成片总时长，'
  '以及 4.3 中“省多少秒”的数值，均为依据常规播音语速所作的估算，尚未实测。'
  '定稿前须计时通读一遍，以实测结果替换。', indent=True, sa=10)

d.save(DOC)
print('saved:', DOC)
print('hanzi=%d  total=%s  shots=%d  pause=%ds' % (total_cn, fmt(TOTAL), len(SHOTS), PAUSE_SUM))
for no, s0, s1, n, dur in timeline:
    print('  镜%s %s-%s  %d字 %.0fs' % (no, fmt(s0), fmt(s1), n, dur))

# ---- 纯文本版，便于配音软件或手机背稿 ----
TXT = os.path.join(BASE, '现场演示视频台词_纯文本版.txt')
buf = []
buf.append('《以芯止戈》现场演示视频解说台词（纯文本版）')
buf.append('CHR 战队　共 %d 个镜头　%s 字　估算成片 %s' % (len(SHOTS), format(total_cn, ','), fmt(TOTAL)))
buf.append('=' * 46)
buf.append('')
for (no, sec_name, scene, lines, pause, nt), (_, s0, s1, n, dur) in zip(SHOTS, timeline):
    buf.append('［%s］%s–%s' % (sec_name, fmt(s0), fmt(s1)))
    for ln in lines:
        buf.append('　　' + ln)
    buf.append('')
buf.append('=' * 46)
buf.append('说明：时间码按每秒 220 字推算，属估算值，定稿前请计时通读一遍。')
buf.append('方括号内为需团队填入的真实信息。')
open(TXT, 'w', encoding='utf-8').write(chr(10).join(buf))
print('txt saved:', TXT)
