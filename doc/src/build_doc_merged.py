# -*- coding: utf-8 -*-
"""
《以芯止戈》技术文档 —— 三份文档整合版
基底：竞赛模板 docx（继承样式与页眉），清空正文后按模板章节顺序重建。
"""
import os
import shutil
import docx
from docx.shared import Pt, Cm, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.style import WD_STYLE_TYPE
from docx.oxml.ns import qn
from docx.oxml import OxmlElement

BASE = r'D:\Work buddy Project\zuizhong_V26_V34\zuizhong_V26'
# 目录已整理: 成品文档在 BASE/doc, 插图在 BASE/doc/fig, 本脚本在 BASE/doc/src
ARCH = r'D:\Work buddy Project\_archive_zuizhong_20261101'
SRC = os.path.join(ARCH, 'old_docs', '技术文档_以芯止戈_V34_整合版_V4.docx')  # 模板基底
DOC = os.path.join(BASE, 'doc', '技术文档_以芯止戈_V34_整合版_V5.docx')
FIGS = os.path.join(BASE, 'doc', 'fig')
if not os.path.exists(DOC) and os.path.exists(SRC):
    shutil.copy(SRC, DOC)

F_CN, F_EN = '宋体', 'Times New Roman'
F_HEAD = '黑体'
C_H1 = RGBColor(0x1F, 0x38, 0x64)
C_H2 = RGBColor(0x2E, 0x54, 0x96)
C_H3 = RGBColor(0x33, 0x33, 0x33)
C_GRAY = RGBColor(0x80, 0x80, 0x80)

d = docx.Document(DOC)


def ensure_toc_styles():
    for lvl, size in ((1, 11), (2, 10.5)):
        name = 'TOC %d' % lvl
        if name in [x.name for x in d.styles]:
            st = d.styles[name]
        else:
            st = d.styles.add_style(name, WD_STYLE_TYPE.PARAGRAPH)
            st.base_style = d.styles['Normal']
        st.font.size = Pt(size)
        st.font.name = F_EN
        st.element.get_or_add_pPr()
        st.font.bold = (lvl == 1)
        pf = st.paragraph_format
        pf.line_spacing = 1.2
        pf.space_before = Pt(4 if lvl == 1 else 0)
        pf.space_after = Pt(2)


def ensure_heading3():
    if 'Heading 3' in [s.name for s in d.styles]:
        return
    st = d.styles.add_style('Heading 3', WD_STYLE_TYPE.PARAGRAPH)
    st.base_style = d.styles['Normal']
    st.font.bold = True
    st.font.size = Pt(12)
    pPr = st.element.get_or_add_pPr()
    ol = OxmlElement('w:outlineLvl')
    ol.set(qn('w:val'), '2')
    pPr.append(ol)


ensure_heading3()
ensure_toc_styles()


def ensure_toc_styles():
    for lvl, size in ((1, 11), (2, 10.5)):
        name = 'TOC %d' % lvl
        if name in [x.name for x in d.styles]:
            st = d.styles[name]
        else:
            st = d.styles.add_style(name, WD_STYLE_TYPE.PARAGRAPH)
            st.base_style = d.styles['Normal']
        st.font.size = Pt(size)
        st.font.name = F_EN
        st.element.get_or_add_pPr()
        st.font.bold = (lvl == 1)
        pf = st.paragraph_format
        pf.line_spacing = 1.2
        pf.space_before = Pt(4 if lvl == 1 else 0)
        pf.space_after = Pt(2)


ensure_heading3()
ensure_toc_styles()
body = d.element.body
for p in list(d.paragraphs):
    body.remove(p._p)
for t in list(d.tables):
    body.remove(t._tbl)


def _rpr(run):
    if run._element.rPr is None:
        run._element.get_or_add_rPr()
    return run._element.rPr


def font(run, cn=F_CN, en=F_EN, size=12, bold=False, color=None):
    run.font.name = en
    _rpr(run).rFonts.set(qn('w:eastAsia'), cn)
    run.font.size = Pt(size)
    run.font.bold = bold
    if color is not None:
        run.font.color.rgb = color


def P(segs, indent=True, align=None, size=12, color=None, sb=0, sa=4, line=1.5):
    p = d.add_paragraph()
    pf = p.paragraph_format
    pf.line_spacing = line
    pf.space_before = Pt(sb)
    pf.space_after = Pt(sa)
    pf.first_line_indent = Pt(size * 2) if indent else Pt(0)
    if align is not None:
        p.alignment = align
    for seg in segs:
        if isinstance(seg, str):
            txt, bold, cn, col = seg, False, None, None
        elif len(seg) == 2:
            txt, bold = seg
            cn, col = None, None
        elif len(seg) == 3:
            txt, bold, cn = seg
            col = None
        else:
            txt, bold, cn, col = seg
        r = p.add_run(txt)
        font(r, cn=(cn or F_CN), size=size, bold=bold, color=(col or color))
    return p


def H(text, level):
    p = d.add_paragraph(style='Heading %d' % level)
    pf = p.paragraph_format
    pf.first_line_indent = Pt(0)
    pf.keep_with_next = True
    if level == 1:
        pf.space_before, pf.space_after = Pt(16), Pt(8)
        size, col = 16, C_H1
    elif level == 2:
        pf.space_before, pf.space_after = Pt(12), Pt(5)
        size, col = 14, C_H2
    else:
        pf.space_before, pf.space_after = Pt(10), Pt(3)
        size, col = 13, C_H3
    pf.line_spacing = 1.3
    r = p.add_run(text)
    font(r, cn=F_HEAD, en='Arial', size=size, bold=True, color=col)
    return p


def figslot(tag, img=None, width_cm=14.4):
    """插入图片并附图注；无图片时输出灰色占位"""
    if img:
        from pathlib import Path
        pic_p = d.add_paragraph()
        pic_p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        pic_p.paragraph_format.space_before = Pt(8)
        pic_p.paragraph_format.space_after = Pt(2)
        pic_p.paragraph_format.first_line_indent = Pt(0)
        pic_p.paragraph_format.keep_with_next = True
        pic_p.add_run().add_picture(os.path.join(FIGS, img), width=Cm(width_cm))
        return P(['%s' % tag], indent=False, align=WD_ALIGN_PARAGRAPH.CENTER,
                 size=9.5, color=C_GRAY, sb=0, sa=10)
    return P(['〔%s〕' % tag], indent=False, align=WD_ALIGN_PARAGRAPH.CENTER,
             size=10, color=C_GRAY, sb=4, sa=10)


def add_field(run, instr, placeholder=''):
    """在 run 中插入一个域（PAGE / TOC 等）"""
    fc1 = OxmlElement('w:fldChar')
    fc1.set(qn('w:fldCharType'), 'begin')
    it = OxmlElement('w:instrText')
    it.set(qn('xml:space'), 'preserve')
    it.text = instr
    fc2 = OxmlElement('w:fldChar')
    fc2.set(qn('w:fldCharType'), 'separate')
    t = OxmlElement('w:t')
    t.text = placeholder
    fc3 = OxmlElement('w:fldChar')
    fc3.set(qn('w:fldCharType'), 'end')
    for e in (fc1, it, fc2, t, fc3):
        run._r.append(e)


def page_footer():
    for sec in d.sections:
        f = sec.footer
        p = f.paragraphs[0] if f.paragraphs else f.add_paragraph()
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.paragraph_format.first_line_indent = Pt(0)
        r0 = p.add_run('第 ')
        font(r0, size=9, color=C_GRAY)
        r1 = p.add_run()
        font(r1, size=9, color=C_GRAY)
        add_field(r1, 'PAGE', '1')
        r2 = p.add_run(' 页')
        font(r2, size=9, color=C_GRAY)


def table_of_contents():
    p = d.add_paragraph()
    p.paragraph_format.first_line_indent = Pt(0)
    p.paragraph_format.space_after = Pt(10)
    r = p.add_run()
    font(r, size=11)
    add_field(r, 'TOC \\o "1-2" \\h \\z \\u', '（打开文档后按 F9 更新目录）')
    return p


def _shade(cell, hexcolor):
    tcPr = cell._tc.get_or_add_tcPr()
    shd = OxmlElement('w:shd')
    shd.set(qn('w:val'), 'clear')
    shd.set(qn('w:color'), 'auto')
    shd.set(qn('w:fill'), hexcolor)
    tcPr.append(shd)


def _borders(tbl):
    tblPr = tbl._tbl.tblPr
    b = OxmlElement('w:tblBorders')
    for edge in ('top', 'left', 'bottom', 'right', 'insideH', 'insideV'):
        e = OxmlElement('w:%s' % edge)
        e.set(qn('w:val'), 'single')
        e.set(qn('w:sz'), '4')
        e.set(qn('w:space'), '0')
        e.set(qn('w:color'), '8EAADB')
        b.append(e)
    tblPr.append(b)


def table(rows, widths=None, size=10, cap=None):
    if cap:
        P([cap], indent=False, align=WD_ALIGN_PARAGRAPH.CENTER,
          size=10, color=C_H3, sb=6, sa=3)
    tbl = d.add_table(rows=len(rows), cols=len(rows[0]))
    tbl.alignment = WD_TABLE_ALIGNMENT.CENTER
    tbl.autofit = False
    _borders(tbl)
    for ri, row in enumerate(rows):
        trPr = tbl.rows[ri]._tr.get_or_add_trPr()
        trPr.append(OxmlElement('w:cantSplit'))
        if ri == 0:
            trPr.append(OxmlElement('w:tblHeader'))
        for ci, val in enumerate(row):
            cell = tbl.cell(ri, ci)
            cell.text = ''
            p = cell.paragraphs[0]
            p.paragraph_format.space_before = Pt(2)
            p.paragraph_format.space_after = Pt(2)
            p.paragraph_format.line_spacing = 1.06
            p.alignment = WD_ALIGN_PARAGRAPH.CENTER if (ri == 0 or ci < len(row) - 1) else WD_ALIGN_PARAGRAPH.LEFT
            r = p.add_run(val)
            font(r, size=size, bold=(ri == 0))
            if ri == 0:
                _shade(cell, 'D9E2F3')
            cell.vertical_alignment = 1
    if widths:
        for ci, w in enumerate(widths):
            for row in tbl.rows:
                row.cells[ci].width = Cm(w)
    P([''], indent=False, size=6, sa=0)
    return tbl


# ===========================================================================
# 封面
# ===========================================================================
p = d.add_paragraph()
p.paragraph_format.space_before = Pt(10)
p.paragraph_format.space_after = Pt(4)
p.paragraph_format.first_line_indent = Pt(0)
r = p.add_run('作品名称')
font(r, cn=F_HEAD, en='Arial', size=13, bold=True, color=C_H1)

p = d.add_paragraph()
p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.paragraph_format.space_before = Pt(92)
p.paragraph_format.space_after = Pt(4)
r = p.add_run('以芯止戈')
font(r, cn=F_HEAD, en='Arial', size=26, bold=True, color=C_H1)

p = d.add_paragraph()
p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.paragraph_format.space_after = Pt(6)
r = p.add_run('——基于 FPGA 的纯硬件 HDMI 音视频播放与可视化系统')
font(r, size=12, color=C_H2)

p = d.add_paragraph()
p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.paragraph_format.space_after = Pt(2)
r = p.add_run('全国大学生嵌入式芯片与系统设计竞赛')
font(r, size=11, color=RGBColor(0x40, 0x40, 0x40))

p = d.add_paragraph()
p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.paragraph_format.space_after = Pt(18)
r = p.add_run('安路科技赛道　　选题一：HDMI 多媒体播放系统')
font(r, size=11, color=RGBColor(0x40, 0x40, 0x40))

p = d.add_paragraph()
p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p.paragraph_format.space_after = Pt(10)
r = p.add_run('CHR 战队　　器件：安路 EG4S20BG256　　工具链：Anlogic TD 5.6.2')
font(r, size=10, color=C_GRAY)

# ===========================================================================
# 摘要
# ===========================================================================
d.add_paragraph().add_run().add_break(WD_BREAK.PAGE)
H('摘要', 2)

P(['传统数字标牌大多搭建在通用计算平台上：主板、内存与操作系统缺一不可，物料成本高；开机要载入内核、'
   '挂载文件系统、拉起播放进程，从通电到出画往往数十秒；播放进程与其他进程共享 CPU 与内存，'
   '长期运行存在死机风险；需要紧急插播时，软件链路也无法保证在确定时间内切换。'])

P(['本作品以一片安路 EG4S20BG256 承担全部工作，把“读卡—缓存—出画”做成纯硬件通路，'
   '不使用处理器，也不运行操作系统。TF 卡内的 24 位非压缩 BMP 与 48 kHz 双声道 WAV 是唯一内容源，'
   '像素经重排与行序翻转写入片内 SDRAM；两个帧缓存首尾相邻，写一帧、显一帧，切图无撕裂、无黑场；'
   '画面按 640×480@60 Hz 读出，经画质调节、转场、滚动字幕与音频频谱处理后，'
   '由 HDMI 1.4b 发送核完成音频打包与 TMDS 编码输出。'])

P(['系统提供匀速滑动、淡出淡入与旋转擦除三种转场，由 KEY7 循环切换。三者均不增加读通道，仅调整读地址：'
   '滑动平移读起点，淡变复用画质通路的增益，旋转擦除将读突发降至 16 字并在块边界选择源帧，'
   '以一条转动的分界线替代二维重采样。'])

P(['Anlogic TD 5.6.2 布局布线后，建立余量 +0.287 ns、保持余量 +0.011 ns，无违例端点；'
   'LUT 占用 7959/19600（40.6%），BRAM 33/64，DSP 13/29。'])


d.add_paragraph().add_run().add_break(WD_BREAK.PAGE)
H('第一部分  作品概述', 1)

H('功能与特性', 2)

for seg in [
    [('静态图片播放——', True, '黑体', C_H2), ('满屏呈现，比例不失真。', False, '楷体'),
     ('支持 640×480 与 1280×960，后者按 2×2 抽取降采样显示。', False)],
    [('切图与自动轮播——', True, '黑体', C_H2), ('无闪烁、无撕裂。', False, '楷体'),
     ('新图写满另一帧缓存后方切换；KEY2 开启后每秒自动切换一张。', False)],
    [('三种转场——', True, '黑体', C_H2), ('动势各异。', False, '楷体'),
     ('滑动画幅连续推移；淡变压暗、换图、提亮；旋转擦除以分界线绕屏心转一周，新图随扇区渐次呈现。', False)],
    [('亮度与对比度——', True, '黑体', C_H2), ('暗部可辨，亮部存层次。', False, '楷体'),
     ('亮度 8 档、对比度 7 档，左上角 OSD 实时显示数值。', False)],
    [('滚动字幕——', True, '黑体', C_H2), ('亮背景下仍可读。', False, '楷体'),
     ('中英双语同速（约 60 像素/秒），白字黑描边，叠渐变暗底。', False)],
    [('音频频谱——', True, '黑体', C_H2), ('八段柱随节拍起伏。', False, '楷体'),
     ('100 Hz~11 kHz 分八倍频程，对数柱高，缓降约 0.45 秒。', False)],
    [('应急画面——', True, '黑体', C_H2), ('一键切换，警报音同步。', False, '楷体'),
     ('ROM 直出、不经帧缓存，读卡异常仍可显示，并锁定切图键防误触。', False)],
    [('状态指示——', True, '黑体', C_H2), ('脱离显示器亦可定位故障。', False, '楷体'),
     ('数码管显示版本号与 SD 状态码，8 个 LED 指示就绪与初始化节点。', False)],
]:
    P(seg)


H('应用领域', 2)
P(['本作品由一块开发板、一张存储卡与一台显示器构成，不依赖操作系统，'
   '适用于长期无人值守、开机即用且不容出错的显示场景。'])
for seg in [
    [('商业展陈。', True), ('橱窗、门店与展厅的海报轮播，内容仅需更换 TF 卡，无需联网与操作系统；'
     '长期运行无内存泄漏与死机风险，亦不必为每台屏配置主机。', False)],
    [('公共信息发布。', True), ('政务大厅、医院、车站的信息屏，开机即出图，断电恢复后无需人工干预，'
     '适合部署在运维人员不方便频繁到场的点位。', False)],
    [('应急广播与疏散引导。', True), ('突发情况下按一个键即在帧边界切换到高优先级应急画面与警报音，'
     '并锁定误操作按键，播毕自动恢复。这是本作品区别于普通播放器的核心价值。', False)],
    [('和平主题公益宣传。', True), ('以图片轮播配合滚动字幕输出公益标语，适合校园、社区与纪念活动，'
     '内容更换成本接近于零。', False)],
    [('教学与科研。', True), ('完整覆盖“存储卡读取—帧缓存—视频时序—TMDS 编码—音频嵌入”的视频通路，'
     '可作为数字系统设计课程的参考设计与二次开发底板。', False)],
]:
    P(seg)

H('主要技术特点', 2)

for seg in [
    [('三个时钟域各司其职。', True, '黑体'),
     ('存储与读卡运行于 100 MHz，像素输出运行于 25 MHz，HDMI 串行输出运行于 125 MHz；'
     '跨域仅经异步 FIFO 与两级同步器。', False)],
    [('双帧缓存交替写入，写满方切换。', True, '黑体'),
     ('两个帧缓存首尾相邻，写侧写入非显示缓冲，写满一整帧后方切换显示指针。', False)],
    [('单读通道支撑三种转场。', True, '黑体'),
     ('板上 SDRAM 仅提供一条顺序读流，三种转场因此只调整读地址：滑动改起点，淡变改增益，'
     '旋转擦除改每个 16 像素块的源帧选择。', False)],
    [('一次乘加完成两项画质调节。', True, '黑体'),
     ('两个参数预先合成斜率 k 与偏移 offset，像素只算 rgb×k/256+offset；淡变时再乘一个系数即可。', False)],
    [('音视频共用同一时钟节拍。', True, '黑体'),
     ('音频在像素时钟域用 520/521 分数分频精确重建 48 kHz，时钟信息随音频数据岛发送。', False)],
    [('硬件状态机调度，响应时间确定。', True, '黑体'),
     ('按键、轮播、转场与应急切换按固定节拍推进，不依赖任务调度与中断，时延稳定；'
     '配合 LED、数码管与 OSD 可定位故障。', False)],
]:
    P(seg)

H('主要性能指标', 2)
P(['数据取自本工程 TD 5.6.2 布局布线后的报告与板上实测，汇总见表 2-1。'])
table([
    ['指标项', '参数'],
    ['视频输出', 'HDMI 1.4b（TMDS 差分四对），640×480@60 Hz，行总长 800、场总长 525，像素时钟 25 MHz'],
    ['图片格式', '24 位非压缩 BMP；640×480 或 1280×960（2×2 抽取降采样）'],
    ['内容容量', '开机扫描 TF 卡前 4 张 BMP（扫描范围 131071 扇区，约 64 MB）'],
    ['转场时长', '滑动 48 帧约 800 ms；淡出淡入 32 帧约 534 ms；旋转擦除 48 帧约 800 ms（7.5°/帧）'],
    ['画面调节', '亮度 25%~200%（8 档）；对比度 50%~200%（7 档）；步进 25%，长按 200 ms 连发'],
    ['音频', 'WAV 48 kHz/16 bit/双声道，I2S 与 HDMI 数据岛同源输出（ACR N=6144），循环无缝'],
    ['频谱显示', '8 段倍频程 100/200/400/800/1600/3200/6400/11000 Hz，Q=2，对数柱高'],
    ['资源占用', 'LUT 7959/19600（40.61%）；寄存器 5294/19600（27.01%）；BRAM 33/64（51.56%）；DSP 13/29（44.83%）'],
    ['时序结果', '建立余量 +0.287 ns，保持余量 +0.011 ns，违例端点 0'],
    ['交付物', '位流 sd_hdmi_bmp.bit（642 428 字节）；39 个 Verilog 源文件（含 4 个官方加密 IP）'],
], widths=[2.9, 11.7], size=10)

H('主要创新点', 2)

for seg in [
    [('以块级选帧实现单读口旋转擦除。', True, '黑体'),
     ('降至 16 字突发、块边界选源帧，以转动分界线替代二维重采样。', False)],
    [('滑动转场不占额外缓存。', True, '黑体'),
     ('两帧首尾相邻，只平移读起点、帧内跳转一次。', False)],
    [('淡变复用画质通路。', True, '黑体'),
     ('系数并入既有斜率与偏移，转场由像素域移至参数域，不增乘法器。', False)],
    [('单乘法器分时复用完成八段频谱。', True, '黑体'),
     ('八个 biquad 串行复用，误差反馈抑制极限环，静音归零。', False)],
    [('应急画面由片内 ROM 直出。', True, '黑体'),
     ('绕过帧缓存，读卡异常仍可出画，帧边界切换并锁定误触按键。', False)],
]:
    P(seg)

H('设计流程', 2)

P(['需求与指标 → 通路划分（写入域 / 存储域 / 像素域）→ 分模块 RTL 设计 → 行为级仿真 → '
   '综合与布局布线 → 按时序报告迭代收敛 → 约束核对 → 生成位流 → 上板联调 → 版本化迭代。'])
P(['其中两步最为关键：仿真先行，使旋转擦除的象限与方向关系在离线阶段即得到验证；'
   '时序收敛以报告为准，将帧读取的地址链拆为两级流水后，建立余量由负转正。'])

H('第二部分  系统组成及功能说明', 1)

H('整体介绍', 2)
P(['系统由“内容源—FPGA—显示终端”三段组成，全部逻辑运行在 EG4S20BG256 内部，'
   '不含片外处理器与操作系统。整机对外仅需 TF 卡、HDMI 与 5 V 供电三处连接，结构见图 2-1。'])
P(['写入通路由 TF 卡经 SPI 进入：SD 驱动完成卡初始化与扇区读取，BMP 解析模块扫描并解析文件头，'
   '把 24 位 BGR 像素重排为 RGB、按行翻转（BMP 为自下而上存储）并做行宽对齐，'
   '随即由帧写入桥经异步 FIFO 写入 SDRAM。读出通路以 25 MHz 像素时钟按光栅顺序从 SDRAM 取数，'
   '经视频时序、画质调节、转场、滚动字幕、音频频谱、应急叠加逐级处理后，'
   '由 RGB 转 AXI4-Stream 送入 HDMI 1.4b 发送核，最后经 TMDS PHY 以 5 倍 DDR 方式输出差分信号。'])
P(['音频通路由同一 SD 驱动从 TF 卡流式读取 WAV，经 48 kHz 节拍重建与源选择后送入 HDMI 核的音频数据岛；'
   'ACR 模块依据实际像素时钟测量 CTS，与 N=6144 一起构成音频时钟再生包。'
   '应急状态下画面切换到片内 ROM 直出的应急图，音频同时切换到 DDS 生成的警报音。'
   '按键位于 50 MHz 域，经两级同步后分别进入 SD 控制与视频处理通路。'])
figslot('图 2-1  系统总体框图', 'fig_system_block.png')
P(['写入域 100 MHz、SDRAM 域 100 MHz、像素域 25 MHz 各自独立，'
   '跨域只经异步 FIFO 与同步器；两帧缓存在片内 8 MB SDRAM 中首尾相邻，双缓冲共占 614400 字，'
   '显示指针与写入指针分离，由上层保证“写新图时显示旧图，写完之后再切换”，三者的交接见图 2-2。'])
figslot('图 2-2  三时钟域划分与乒乓双缓冲结构', 'fig_clock_domain.png')

H('硬件系统介绍', 2)
H('2.2.1  硬件整体介绍', 3)
P(['硬件平台由“大拇指 EG4S20BG256 核心板 + M0 微处理器原理综合设计底板”叠插构成。'
   '核心板提供 FPGA 本体、50 MHz 有源晶振、配置电路与全部 I/O，并集成片内 8 MB SDRAM；'
   '底板提供 TF 卡座、HDMI 接口、4×4 矩阵键盘、4 位数码管、8 个 LED 与 5 V 供电。'
   'EG4S20BG256 片内集成 64 Mb SDRAM（2M×32 bit）、64 块 9Kb BRAM、29 个 DSP 与 4 个 PLL，'
   '使“帧缓存 + 视频时序 + 音频嵌入”可以全部在单片内完成，无需外扩存储器（图 2-3）。'])
table([
    ['器件 / 资源', '规格', '在本作品中的作用'],
    ['FPGA', 'EG4S20BG256（BGA256）', '全部逻辑与接口'],
    ['片内 SDRAM', '2M×32 bit（8 MB / 64 Mb）', '两个 640×480 帧缓存，各 307200 字'],
    ['BRAM', '64 块 9 Kb', '跨时钟域 FIFO、字幕与 OSD 字模、应急画面 ROM'],
    ['DSP', '29 个', '画质合并运算、频谱滤波器、转场斜率运算'],
    ['PLL', '4 个（使用 2 个）', '100 MHz 存储域；25 MHz 像素域与 125 MHz 串行时钟'],
], widths=[3.0, 5.0, 6.6], size=10, cap='表 2-1  主要器件与片内资源')

H('2.2.2  机械设计介绍', 3)
P(['本作品不涉及自制机械结构件。整机采用现成核心板与综合底板叠插，TF 卡与 HDMI 线缆直接插接于底板接口，'
   '无外壳、无运动部件，因此不需要机械设计图纸；可交付成果集中在 FPGA 逻辑设计本身'
   '（RTL 源码、约束文件与位流）。'])
figslot('图 2-3  核心板与底板叠插实物照片（待插入）')

H('2.2.3  电路各模块介绍', 3)
P(['本作品不涉及自制 PCB，电路层面的工作是在既有平台上完成引脚分配、电平标准设定与接口时序约束，'
   '约束文件为 sd_hdmi_bmp.adc。主要引脚分配如表 2-2，接口与引脚的对应关系见图 2-4。'])
table([
    ['模块', '信号', '引脚', '说明'],
    ['时钟', 'clk', 'R7', '50 MHz 有源晶振，LVCMOS33'],
    ['复位', 'rst_n', 'A9', 'SW0 拨码开关，低有效，内部上拉'],
    ['矩阵键盘', 'key_row / key_row1', 'E10 / C10', '行驱动，分时拉低'],
    ['矩阵键盘', 'key0~key3', 'E11 / D11 / C11 / F10', '列采样，内部上拉'],
    ['TF 卡（SPI）', 'sck / cs_n / mosi / miso', 'F15 / F13 / F14 / D14', 'MicroSD 卡座'],
    ['HDMI', 'CLK_P / D0_P / D1_P / D2_P', 'P1 / N1 / P4 / J3', 'LVDS33，N 端由原语自动配对'],
    ['数码管', 'seg_sel[3:0] / seg_led[7:0]', 'C9,B6,A5,A3 / A4,A6,B8,E8,A7,B5,A8,C8', '位选低有效，段选高有效'],
    ['LED', 'led[7:0]', 'B14,B15,B16,C15,C16,E13,E16,F16', '高电平点亮'],
], widths=[2.6, 4.2, 4.2, 3.6], size=9, cap='表 2-2  主要引脚分配（LVCMOS33 / LVDS33）')

P([('时钟与复位：', True, '黑体'),
   ('50 MHz 由有源晶振提供，经 clk_pll 产生 100 MHz 存储时钟与 100 MHz/180° 相移时钟（后者仅送 SDRAM 硬核），'
    '经 video_pll 产生 25 MHz 像素时钟与 125 MHz 串行时钟；整机复位为“两路 PLL 锁定 + SW0”的逻辑或，'
    '任一时钟失锁即复位全部逻辑。', False)])
P([('矩阵键盘：', True, '黑体'),
   ('4×4 键盘只使用 Row0/Row1 两行与 Col0~Col3 四列，通过 1 kHz 双相位分时扫描把 8 个物理按键映射为 KEY0~KEY7；'
    '其中 Col3（F10）在不同扫描相位分别承载 KEY3 与 KEY7，因此 8 个按键只占 6 个 IO。各键功能见表 2-3。', False)])
table([
    ['按键', '行列组合（列引脚）', '功能'],
    ['KEY0', 'Row0 × Col0（E11）', '上一张图片'],
    ['KEY1', 'Row0 × Col1（D11）', '下一张图片'],
    ['KEY2', 'Row0 × Col2（C11）', '自动轮播 开 / 关'],
    ['KEY3', 'Row0 × Col3（F10）', '当前参数递减（长按 200 ms 连发）'],
    ['KEY4', 'Row1 × Col0（E11）', '当前参数递增（长按 200 ms 连发）'],
    ['KEY5', 'Row1 × Col1（D11）', '应急模式 进入 / 退出'],
    ['KEY6', 'Row1 × Col2（C11）', '短按：音频频谱 开 / 关；长按 0.8 s：切换调节对象'],
    ['KEY7', 'Row1 × Col3（F10）', '转场方式循环：滑动 → 淡变 → 旋转擦除'],
], widths=[1.8, 4.4, 8.0], size=9, cap='表 2-3  按键功能分配')
P([('TF 卡接口：', True, '黑体'),
   ('采用 SPI 模式，初始化阶段低速、识别后全速；读写以 512 字节单扇区为单位，'
    '由片内状态机完成 CMD0/CMD8/CMD55/ACMD41/CMD17 命令序列。', False)])
P([('HDMI 接口：', True, '黑体'),
   ('底板只引出四对差分线（时钟一对、数据三对），未引出 DDC 与 HPD，因此系统不读取 EDID，'
    '输出固定为 640×480@60 Hz，插拔显示器不需要重新协商。', False)])
P([('人机指示：', True, '黑体'),
   ('4 位数码管动态扫描，8 个 LED 由内部状态信号直接驱动，两者共同构成不依赖显示器的自检通道。', False)])
figslot('图 2-4  板卡接口与引脚分配示意（据核心板与底板原理图整理）', 'fig_pin_map.png')

H('软件系统介绍', 2)
H('2.3.1  软件整体介绍', 3)
P(['本作品为纯硬件实现，不含处理器程序与操作系统，所谓“软件系统”指 FPGA 内部由 RTL 描述的逻辑系统。'
   '顶层 top.v 完成时钟与复位生成、模块例化与跨域同步，数据通路可划分为视频写入、视频读出与处理、音频、'
   '控制与指示四条。时钟域划分与跨域方式如表 2-4，各通路的模块归属见图 2-5。'])
table([
    ['时钟域', '频率', '主要模块', '跨域方式'],
    ['clk（输入）', '50 MHz', '复位计数、键盘扫描、数码管扫描', '—'],
    ['sd_card_clk', '100 MHz', 'SD 驱动、BMP/WAV 解析、帧写入', '异步 FIFO 写侧'],
    ['ext_mem_clk', '100 MHz', 'SDRAM 用户接口、帧读取、读写仲裁', '异步 FIFO 读写侧'],
    ['ext_mem_clk_sft', '100 MHz / 180°', '仅 SDRAM 硬核采样', '硬核内部'],
    ['video_clk', '25 MHz', '视频时序、像素处理、转场、HDMI 核', '异步 FIFO 读侧 + 两级同步'],
    ['hdmi_5x_clk', '125 MHz', 'TMDS 5 倍串行化', '同源 PLL 输出'],
], widths=[3.4, 3.0, 5.0, 3.2], size=9, cap='表 2-4  时钟域划分与跨域方式')
figslot('图 2-5  RTL 总体数据流与各通路的时钟域归属', 'fig_rtl_flow.png', width_cm=13.6)

H('2.3.2  软件各模块介绍', 3)

mods = [
    ('时钟与复位（clk_pll / video_pll）',
     '由 50 MHz 晶振经两个 PLL 产生 100 MHz 存储时钟（含送 SDRAM 硬核的 180° 相移时钟）、'
     '25 MHz 像素时钟与 125 MHz 串行时钟。复位在全时钟稳定后才释放，避免亚稳态向下游传播。'),
    ('键盘扫描（key_scan）',
     '以 1 kHz 双相位交替拉低 Row0/Row1，在每相位 0.8 ms 处采样四列，两相位各自消抖。'
     '输出上一张、下一张、自动轮播、参数增减、应急、可视化开关与转场切换；'
     'KEY6 采用“按下计时、松手判定”，短按切可视化、长按 0.8 秒切调节对象，避免长按误触发短按功能。'),
    ('存储卡与 BMP 解析（sd_card_bmp / bmp_read）',
     '上电后写入 CMD0/CMD8/CMD55/ACMD41 完成卡初始化，由 0 扇区顺序扫描至多 131071 个扇区，'
     '识别文件头并记录前 4 张 BMP 的起始扇区。解析阶段读取宽、高、位深与数据偏移，仅接受 24 位非压缩格式；'
     '像素写入前完成 BGR→RGB 重排与垂直翻转（抵消 BMP 自下而上存储），并按 640 字行宽对齐，'
     '使后续地址计算只做移位与加法。'),
    ('帧缓存与双缓冲（frame_read_write）',
     '把片内 SDRAM 封装为同步读写接口，写侧 100 MHz、读侧 25 MHz，两侧各有一级异步 FIFO。'
     '两个帧缓存分别位于 0 与 307200 字，正好一帧一块。写满一帧才切换显示指针，因此切图不产生撕裂；'
     '读侧同时接受转场模块下发的偏移、跳转与块选择参数。'),
    ('帧读取与突发控制（frame_fifo_read）',
     '按光栅顺序把 SDRAM 突发数据整理成连续像素流。转场改动集中在这里：读突发由 128 字降为 16 字，'
     '使读地址可以在每 16 像素的块边界重新选择源帧；块选择位与块偏移拆成两级流水，'
     '将“比较—选帧—加法”长链拆为两级流水，使 100 MHz 下建立时间由负转正。'),
    ('视频时序（video_timing_data / video_delay）',
     '产生 640×480@60 Hz 的行场同步与数据使能：行总长 800（同步 96、前肩 16、后肩 48），'
     '场总长 525（同步 2、前肩 10、后肩 33），像素时钟 25 MHz，实际场频约 59.5 Hz；'
     '并按 640×480 发起整帧读请求、补偿读延迟使像素与使能对齐。'),
    ('画质调节与 OSD（bright_ctrl）',
     '用慢速预计算把亮度与对比度合并为一次线性变换：k = 亮度×对比度/256，offset = (256−对比度)/2，'
     '输出 out = rgb×k/256 + offset 并做上下饱和，负偏移用 12 位补码借位判别。'
     '淡变时把 k 与 offset 再乘 0~16 的系数，像素通路不新增乘法器。'
     '同一模块生成左上角三行 OSD：分辨率、当前参数（BRI/CON）、转场方式（SLIDE/FADE/ROTATE）。'),
    ('转场引擎（trans_fade）',
     '以场同步为节拍推进状态机，对外只输出参数、不改动像素。滑动输出读起点偏移与帧内跳转点；'
     '淡变输出 0~16 级增益；旋转擦除输出象限、边界起点、每行增量与方向，'
     '其中角度由 12 档 tan/cot 查表换算（每档 7.5°），最后由一帧“整屏新图”收尾，补掉末档残留的楔形缺口。'),
    ('滚动字幕（osd_scroll）',
     '在画面底部叠加两行字幕：中文 16×16 点阵位于 y=448~463，英文 8×16 点阵位于 y=464~479，'
     '两行同速左移（1 像素/帧，约 60 像素/秒）；文字做四邻域黑描边，字幕区叠加由深到浅的渐变暗底，'
     '保证亮背景下仍可读。'),
    ('音频播放（wav_player / wav_audio_out）',
     '从固定起始扇区起扫描 RIFF/WAVE 头，校验 fmt 与 data 块，按 data 偏移流式读取，'
     '每 4 字节组装为一个 32 bit 立体声帧写入异步 FIFO，播完回到 data 起始循环。'
     '读侧在 25 MHz 域用 520/521 分数分频（每 6 帧 5×521+1×520=3125 周期）得到精确 48 kHz 节拍，'
     '16 bit 样本左移 8 位扩展为 24 bit；FIFO 空时补零静音但保持节拍，保证时钟信息连续。'),
    ('频谱可视化（audio_vu）',
     '8 段并联 biquad 带通滤波器，中心频率按倍频程分布（100~11000 Hz，Q=2），'
     '逐采样计算各段能量后取对数刻度驱动柱高；系数定点化（b0 取 Q24、反馈系数 Q14），'
     '21 bit 饱和运算并引入误差反馈抑制极限环。上升即时跟随，下降每帧衰减 3 级。'),
    ('应急模式（emergency_mode / DDS 警报音）',
     '画面直接由片内 ROM 生成（安全绿底、白色闪烁外框、左向箭头、开门奔跑人形，'
     '以及“应急出口”与“EMERGENCY EXIT”字模），不经 SDRAM 帧缓存，与图片读取互不干扰；'
     '音频切换为 DDS 方波（800/600 Hz 每 0.35 秒交替）；进入时锁定 KEY0/KEY1/KEY2，退出后恢复原图与音乐。'),
    ('HDMI 发送（官方 IP + PHY）',
     'hdmi_1_4b_transmitter_core_wrapper.enc.v 把 RGB 视频与音频打包为 TMDS 数据流，'
     '包含音频数据岛与 ACR 时钟恢复；lane_lvds_10_1 将 10 bit 并行数据以 5 倍 DDR 转为差分对输出。'),
    ('顶层与指示（top / seg4_scan）',
     '例化全部模块并分配引脚；数码管开机 2 秒显示版本号，之后显示 SD 状态机状态码；'
     '8 个 LED 映射图片就绪、SDRAM 初始化、两路 PLL 锁定、WAV 定位与播放、SD 初始化等状态。'),
]
for name, text in mods:
    P([('%s：' % name, True, '黑体'), (text, False)])

P(['三种转场的效果与读地址映射见图 2-6。'])
figslot('图 2-6  三种转场效果与对应的读地址映射', 'fig_transition_map.png')
P(['三种转场的差别最终都落在读地址的生成方式上：滑动与淡变不改变突发长度，'
   '旋转擦除则把每个读突发缩短为 16 字，以便在块边界更换源帧。这一改动同时把地址链推到了时序极限，'
   '处理办法见图 2-7。'])
figslot('图 2-7  帧读取地址链由单拍串联改为两级流水', 'fig_pipeline.png')

# ===========================================================================
# 第三部分
# ===========================================================================
H('第三部分  完成情况及性能参数', 1)

H('整体介绍', 2)
P(['系统已完成全部设计并成功上板运行，整机形态为“核心板 + 底板 + TF 卡 + HDMI 显示器”。'
   '上电后数码管先显示版本号 34，指示灯依次点亮，随后自动读卡并显示第一张图片，'
   '此后所有功能均可通过按键实时控制，无需任何外部设备介入。'])
P(['整机完成情况可概括为三条：一是功能完整，八项功能逐项通过板上验证；'
   '二是状态可视，任一阶段异常均可由数码管状态码与 LED 定位；'
   '三是可重建，工程经 build.tcl 即可由 RTL 重新生成位流，在任一开发机上均可复现。'])
figslot('图 3-1  整机正面实物照片（待插入）')
figslot('图 3-2  整机斜 45° 全局照片（待插入）')

H('工程成果', 2)
H('3.2.1  机械成果', 3)
P(['本作品无自制机械结构件。整机为现成核心板与底板叠插，TF 卡与 HDMI 线缆直接插接，'
   '结构稳固、接口方向合理，置于展台即可连续运行，搬迁无需拆装。'])
H('3.2.2  电路成果', 3)
P(['本作品无自制 PCB，硬件平台为 EG4S20BG256 核心板与 M0 综合底板；'
   '电路层面的成果是一套完整的引脚分配与电平约束：约束 4 路 HDMI 差分、4 路 SD、6 路键盘、'
   '12 路数码管与 8 路 LED，全部经上板验证，约束文件随工程交付。'])
figslot('图 3-3  核心板与底板接口、TF 卡座与 HDMI 接口特写（待插入）')
H('3.2.3  软件（逻辑）成果', 3)
P(['交付物为完整的 FPGA 逻辑工程：RTL 源码 39 个文件（含 4 个官方加密 IP）、引脚约束 sd_hdmi_bmp.adc、'
   '时序约束 sd_hdmi_bmp.sdc、一键构建脚本 build.tcl，以及可直接烧录的位流 sd_hdmi_bmp.bit（642 428 字节）。'
   '综合、布局、布线全流程 0 时序违例，工程在 TD 5.6.2 下可重复构建。'])
figslot('图 3-4  TD 工程编译结果截图（资源利用率与时序报告）（待插入）')

H('特性成果', 2)
P(['实测结果与验证方法见表 3-1；时序与资源数据取自布局布线后的报告，'
   '其余为板上观察与逐档操作验证。'])
table([
    ['特性', '实测结果', '验证方法'],
    ['图片显示', '640×480 与 1280×960 均整幅铺满，无拉伸', '分别显示两种尺寸样图观察'],
    ['切图', '手动与自动切图无撕裂、无黑场', '连续手动与自动切换观察'],
    ['滑动转场', '约 800 ms 匀速滚动，方向与按键一致', '观察切换中间态'],
    ['淡变转场', '约 534 ms 淡出淡入，全黑仅 1 帧', '观察切换中间态'],
    ['旋转擦除', '约 800 ms 转满一圈，KEY1 顺时针 / KEY0 逆时针', '观察切换中间态'],
    ['亮度/对比度', '25%~200% 与 50%~200% 逐档可调，OSD 同步', '逐档调节观察'],
    ['滚动字幕', '中英双语同速左移，亮背景下仍可读', '切换不同背景图观察'],
    ['音频', '48 kHz 立体声与画面同源，循环无接缝', '长时间播放观察音画同步'],
    ['频谱', '8 段随频率分布变化，静音归零', '以鼓点与人声素材分别观察'],
    ['应急插播', '帧边界切换，警报音响，切图键锁定', '按键验证'],
], widths=[2.8, 7.2, 4.6], size=9, cap='表 3-1  功能与指标实测结果')
figslot('图 3-5  轮播与滑动转场演示照片（待插入）')
figslot('图 3-6  淡变与旋转擦除中间态照片（待插入）')
figslot('图 3-7  频谱与应急画面照片（待插入）')

# ===========================================================================
# 第四部分
# ===========================================================================
H('第四部分  总结', 1)

H('可扩展之处', 2)

for seg in [
    [('八段频谱扩展为完整曲线。', True), ('沿用单乘法器分时复用的思路，替换为 256 点硬件 FFT，可获得连续频谱与更细分辨率。', False)],
    [('块级选帧推广为图层合成。', True), ('旋转擦除已验证按块选源可行，再增设一级块级混合即可实现画中画与渐显。', False)],
    [('应急插播升级为优先级调度。', True), ('引入多级优先队列后，字幕与角标可常驻，告警条自底部叠加而不中断主画面。', False)],
    [('参数掉电保持。', True), ('亮度、对比度与转场方式写入保留区后即可掉电记忆。', False)],
    [('滑动引入加减速曲线。', True), ('按行偏移查表生成缓入缓出轨迹，可获得更接近影片的运镜效果。', False)],
]:
    P(seg)

H('心得体会', 2)
P(['项目中最基本的一条经验，是先厘清约束再讨论效果。最初的设想是两张图叠加互融，动手后才发现板上 SDRAM '
   '仅提供一条顺序读流；同一像素位置要同时取新旧两帧，就必须增设一条读通道，带宽翻倍、仲裁重写，'
   '而时序余量仅零点几纳秒。由此换了一个问法：在不增加读通道的前提下，地址流还能作何安排？'
   '三种转场正是在这一问法下形成的——滑动仅移动读起点，淡变复用画质通路的增益，'
   '旋转擦除将读突发降至 16 字并在块边界更换源帧。三者均非最理想的实现，'
   '却是本板卡上能够稳定运行且不牺牲时序的实现。'])
P(['第二条体会是仿真先行的价值。旋转擦除的几何关系并不复杂，但象限、镜像与 tan/cot 的对应关系容易出错。'
   '我们编写了只依赖帧读取模块的测试台，逐块打印其读取的是旧帧还是新帧并逐一比对，'
   '在离线阶段即发现象限判断取错位：象限为 2 bit 数，第二象限编码高位为 0，最初按高位判断，'
   '致使该段采用了错误斜率。此类错误若直接上板，现象仅为旋转至中途出现跳变，定位成本很高。'])
P(['第三条与工具链有关。构建脚本中途报错时，流程仍会跑完并打印成功，实际是以先前的缓存网表生成位流；'
   '我们一度误判改动已生效，直至发现工程中缺少一个被顶层引用的源文件。'
   '此后形成一项习惯：每次编译均核对资源数字与关键路径是否随改动变化，而非只看最后一行的完成提示。'
   '时序亦不能凭主观感受判定：将帧读取的地址路径由“比较—选帧—加法”拆为两级流水后，建立余量由负转正，'
   '该数值较主观判断更为可靠。'])
P(['最后是对产品可用性的理解。竞赛要求的不只是画面可动，更要求设备在真实场合中能够长期开机、承受误操作，'
   '并在故障时易于判读。为此补充了状态码、OSD 参数显示、按键锁定与音乐断点续播等并不炫目的细节。'
   '这些设计不出现在演示的高光时刻，却决定系统能否在展厅或大厅中长期运行。'])
P(['回顾整个过程，作品是在资源与时序的硬约束下逐步成形的：每轮仅增加一项特性，'
   '增补后须保证全链路可演示、资源有余量、时序零违例，方才进入下一轮。'
   '这一节奏使每次出现问题都能判断其来源层次，也使最终整合未成为一次冒险。'])


H('第五部分  参考文献', 1)
for ref in [
    '[1] 上海安路信息科技股份有限公司. EG4S20 系列 FPGA 数据手册[Z]. 2023.',
    '[2] 上海安路信息科技股份有限公司. Tang Dynasty 软件用户指南[Z]. 2023.',
    '[3] 上海安路信息科技股份有限公司. 内部块 RAM 用户指南[Z]. 2023.',
    '[4] 上海安路信息科技股份有限公司. 基于 ERAM 接口实现的高性能 SDRAM 读写（APUG011）[Z]. 2021.',
    '[5] 上海安路信息科技股份有限公司. HDMI 发送显示（APUG004）[Z]. 2021.',
    '[6] HDMI Licensing, LLC. High-Definition Multimedia Interface Specification Version 1.4b[S]. 2011.',
    '[7] SD Association. SD Specifications Part 1: Physical Layer Simplified Specification[Z]. 2020.',
    '[8] JEDEC Solid State Technology Association. JESD79F: SDR SDRAM Specification[S]. 2010.',
    '[9] Microsoft Corporation. BITMAPINFOHEADER Structure[EB/OL]. Windows Dev Center.',
    '[10] Microsoft Corporation. Multiple Channel Audio Data and WAVE Files[EB/OL]. Windows Dev Center.',
    '[11] 夏宇闻. Verilog 数字系统设计教程（第 4 版）[M]. 北京：北京航空航天大学出版社, 2018.',
    '[12] A. V. Oppenheim, R. W. Schafer. 离散时间信号处理（第 3 版）[M]. 北京：电子工业出版社, 2015.',
]:
    P([ref], indent=False, align=WD_ALIGN_PARAGRAPH.LEFT, size=10.5, sa=1, line=1.2)

# 默认样式兜底
st = d.styles['Normal']
st.font.name = F_EN
st.font.size = Pt(12)
st.element.rPr.rFonts.set(qn('w:eastAsia'), F_CN)

d.save(DOC)
print('SAVED', DOC)
d2 = docx.Document(DOC)
print('paras', len(d2.paragraphs), 'tables', len(d2.tables))
