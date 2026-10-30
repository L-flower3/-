# -*- coding: utf-8 -*-
r"""
=============================================================================
 TF 卡制卡工具 (v7 WAV 音频版) —— BMP 图片 + WAV 音乐裸写固定扇区
=============================================================================

布局 (与 FPGA 内 bmp_read/wav_player 的扫描起始一致):
    BMP 4 张 : 扇区 8192 + i*1808   (i=0..3)
    WAV 1 个 : 扇区 15424           (= 8192 + 4*1808)

要求:
    TF 卡按裸扇区写入 (卡可不用 FAT32 格式化; 若为 FAT32 卡, 写入会覆盖对应
    区域的 FAT 元数据, 请用专门的空卡或接受该区域被占用)。
    Windows 下需要【管理员权限】访问物理磁盘 (\\.\PhysicalDriveN)。

WAV 格式校验:
    PCM / 48000Hz / 16bit / 双声道, data 长度 4 字节对齐, 时长 ≤ 约 5min9s
    (WAV 裸写区间 15424..131071 扇区内的上限), RIFF 头 ≤ 512 字节。

用法:
    # 1) 图片转 640x480 BMP (输出 out_bmp/ 目录)
    python write_tfcard_audio.py convert a.jpg b.png c.jpg d.jpg

    # 2) 写卡 (BMP 与 WAV 可任意组合; 需管理员)
    python write_tfcard_audio.py raw --dev \\.\PhysicalDrive2 \
        --bmp out_bmp/PIC0.BMP out_bmp/PIC1.BMP out_bmp/PIC2.BMP out_bmp/PIC3.BMP \
        --wav music.wav --verify

依赖: Pillow (pip install pillow)
=============================================================================
"""
import os
import sys
import struct
import argparse

IMG_W = 640
IMG_H = 480
SEC_SIZE = 512
NUM_IMG_MAX = 4

FALLBACK_SEC = 8192          # BMP 起始扇区
FALLBACK_STEP = 1808         # BMP 间隔扇区
WAV_BASE_SEC = 8192 + 4 * 1808   # WAV 起始扇区 = 15424
WAV_MAX_END_SEC = 131072     # WAV 结束扇区上限 (与 FPGA WAV_SCAN_MAX 对应)

FS = 48000
BITS = 16
CH = 2
BYTES_PER_SEC = FS * BITS // 8 * CH        # 192000 B/s
MAX_WAV_DUR = 5 * 60                       # 5 分钟 (秒)


# ----------------------------------------------------------------- 转 BMP
def convert_to_bmp(src_list, out_dir):
    try:
        from PIL import Image
    except ImportError:
        print("[ERR] 需要 Pillow : pip install pillow")
        sys.exit(1)

    os.makedirs(out_dir, exist_ok=True)
    outs = []
    for i, src in enumerate(src_list[:NUM_IMG_MAX]):
        im = Image.open(src).convert("RGB")
        w, h = im.size
        tw, th = IMG_W, IMG_H
        if abs(w / h - 4 / 3) > 0.01:
            if w / h > 4 / 3:
                nw = int(h * 4 / 3)
                im = im.crop(((w - nw) // 2, 0, (w - nw) // 2 + nw, h))
            else:
                nh = int(w * 3 / 4)
                im = im.crop((0, (h - nh) // 2, w, (h - nh) // 2 + nh))
        im = im.resize((tw, th), Image.LANCZOS)

        dst = os.path.join(out_dir, "PIC%d.BMP" % i)
        row_bytes = tw * 3
        pad = (4 - (row_bytes % 4)) % 4
        pix = im.load()
        body = bytearray()
        for y in range(th - 1, -1, -1):          # BMP: 底行在前
            for x in range(tw):
                r, g, b = pix[x, y]
                body += bytes((b, g, r))
            body += b"\x00" * pad
        data_size = len(body)
        file_size = 54 + data_size
        hdr = b"BM"
        hdr += struct.pack("<IHHI", file_size, 0, 0, 54)
        hdr += struct.pack("<IiiHHIIiiII", 40, tw, th, 1, 24, 0,
                           data_size, 0, 0, 0, 0)
        with open(dst, "wb") as f:
            f.write(hdr)
            f.write(body)
        outs.append(dst)
        print("[OK] %s -> %s  (%d bytes)" % (src, dst, 54 + data_size))
    return outs


# ------------------------------------------------------------- WAV 校验/读取
def load_wav(path):
    """校验 WAV 并返回 (完整文件字节, data 偏移, data 长度)。不符合要求则退出。"""
    if not os.path.isfile(path):
        print("[ERR] 找不到 %s" % path)
        sys.exit(1)
    data = open(path, "rb").read()

    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        print("[ERR] %s 不是 RIFF/WAVE 格式" % path)
        sys.exit(1)
    riff_size = struct.unpack("<I", data[4:8])[0]
    if len(data) < 12 or riff_size + 8 > len(data):
        print("[ERR] %s RIFF 长度字段异常" % path)
        sys.exit(1)

    # chunk 游走找 fmt/data
    fmt = None
    data_ofs = None
    data_len = None
    pos = 12
    while pos + 8 <= len(data):
        cid = data[pos:pos + 4]
        csz = struct.unpack("<I", data[pos + 4:pos + 8])[0]
        if cid == b"fmt ":
            if csz < 16 or pos + 8 + 16 > len(data):
                print("[ERR] %s fmt chunk 异常" % path)
                sys.exit(1)
            f = data[pos + 8:pos + 8 + 16]
            fmt = struct.unpack("<HHIIHH", f)
        elif cid == b"data":
            data_ofs = pos + 8
            data_len = csz
            break
        pos += 8 + csz + (csz & 1)

    if fmt is None:
        print("[ERR] %s 缺少 fmt chunk" % path)
        sys.exit(1)
    if data_ofs is None:
        print("[ERR] %s 缺少 data chunk" % path)
        sys.exit(1)
    if data_len in (0, 0xFFFFFFFF):
        data_len = riff_size - (data_ofs - 8)   # data 在末尾时的兜底推算
    if data_ofs + data_len > len(data):
        print("[WARN] data 长度 %d 超出文件实际大小 %d, 按实际截断" %
              (data_len, len(data) - data_ofs))
        data_len = len(data) - data_ofs

    tag, ch, rate, byte_rate, block_align, bits = fmt
    if tag != 1:
        print("[ERR] 仅支持 PCM(WAVE_FORMAT_PCM=1), 当前 tag=%d" % tag)
        sys.exit(1)
    if rate != FS:
        print("[ERR] 采样率必须为 %dHz, 当前 %dHz (请用 ffmpeg 重采样)" % (FS, rate))
        sys.exit(1)
    if ch != CH:
        print("[ERR] 必须为 %d 声道, 当前 %d" % (CH, ch))
        sys.exit(1)
    if bits != BITS:
        print("[ERR] 位深必须为 %dbit, 当前 %dbit" % (BITS, bits))
        sys.exit(1)
    if data_len % 4 != 0:
        print("[ERR] data 长度 %d 非 4 字节对齐 (立体声 16bit 每帧 4 字节)" % data_len)
        sys.exit(1)

    dur = data_len / BYTES_PER_SEC
    if dur > MAX_WAV_DUR + 9.5:    # 512B 头以内, 上限约 5min9s
        print("[ERR] 时长 %.1fs 超过上限(约 5min9s, 受裸写扇区区间限制)" % dur)
        sys.exit(1)
    if dur > MAX_WAV_DUR:
        print("[WARN] 时长 %.1fs 超过 5min, 注意播完前不会触底, 但占扇区较多" % dur)

    need_end = WAV_BASE_SEC + ((data_ofs + data_len + SEC_SIZE - 1) // SEC_SIZE)
    if need_end > WAV_MAX_END_SEC:
        print("[ERR] WAV 占用扇区超出上限 %d (需要 %d), 请缩短音频" %
              (WAV_MAX_END_SEC, need_end))
        sys.exit(1)

    print("[OK] WAV 校验通过: PCM %dHz/%dbit/%dch, data偏移=%d, 长度=%d, 时长=%.1fs" %
          (rate, bits, ch, data_ofs, data_len, dur))
    return data, data_ofs, data_len


# ----------------------------------------------------------------- 裸写
def raw_write(dev, bmp_list, wav_path, verify):
    if os.name != "nt":
        print("[ERR] 裸写模式仅支持 Windows")
        sys.exit(1)

    # 先全部读取校验, 再一次性打开盘写入, 减少失败半途的风险
    plans = []
    for i, path in enumerate(bmp_list[:NUM_IMG_MAX]):
        if not os.path.isfile(path):
            print("[ERR] 找不到 %s" % path)
            sys.exit(1)
        d = open(path, "rb").read()
        need = 54 + IMG_W * IMG_H * 3
        if len(d) < need:
            d = d + b"\x00" * (need - len(d))
        lba = FALLBACK_SEC + i * FALLBACK_STEP
        plans.append((lba * SEC_SIZE, d))
        print("[OK] BMP %s -> 扇区 %d (偏移 0x%X)" % (path, lba, lba * SEC_SIZE))

    if wav_path:
        d, data_ofs, data_len = load_wav(wav_path)
        lba = WAV_BASE_SEC
        plans.append((lba * SEC_SIZE, d))
        print("[OK] WAV %s -> 扇区 %d (偏移 0x%X)" % (wav_path, lba, lba * SEC_SIZE))

    if not plans:
        print("[ERR] 没有可写入的内容 (需要 --bmp 或 --wav)")
        sys.exit(1)

    try:
        f = open(dev, "r+b")
    except Exception as e:
        print("[ERR] 打开 %s 失败: %s" % (dev, e))
        print("      请以【管理员身份】运行, 并确认盘符正确")
        sys.exit(1)

    for off, blob in plans:
        f.seek(off)
        f.write(blob)
        print("[OK] 已写入偏移 0x%X, 长度 %d" % (off, len(blob)))
    f.close()

    if verify:
        print("---- 回读校验 ----")
        ok = True
        f = open(dev, "rb")
        for off, blob in plans:
            f.seek(off)
            back = f.read(len(blob))
            if back == blob:
                print("[OK] 偏移 0x%X 校验一致" % off)
            else:
                ok = False
                print("[FAIL] 偏移 0x%X 校验不一致" % off)
        f.close()
        # 校验 WAV 头关键标记
        f = open(dev, "rb")
        f.seek(WAV_BASE_SEC * SEC_SIZE)
        hdr = f.read(12)
        f.close()
        if hdr[:4] == b"RIFF" and hdr[8:12] == b"WAVE":
            print("[OK] LBA %d 处确认为 RIFF/WAVE 头" % WAV_BASE_SEC)
        else:
            ok = False
            print("[FAIL] LBA %d 处未找到 RIFF/WAVE (0x%02X%02X%02X%02X ...)" %
                  (WAV_BASE_SEC, hdr[0], hdr[1], hdr[2], hdr[3]))
        if ok:
            print("---- 校验全部通过 ----")
        else:
            print("---- 存在校验失败, 请重写 ----")
            sys.exit(1)


def main():
    ap = argparse.ArgumentParser(description="TF 卡 BMP+WAV 制卡工具 (v7)")
    ap.add_argument("mode", choices=["convert", "raw"])
    ap.add_argument("files", nargs="*")
    ap.add_argument("--out", default="out_bmp")
    ap.add_argument("--dev", default="")
    ap.add_argument("--bmp", nargs="*", default=[])
    ap.add_argument("--wav", default="")
    ap.add_argument("--verify", action="store_true")
    a = ap.parse_args()

    if a.mode == "convert":
        if not a.files:
            print("用法: python write_tfcard_audio.py convert <图片1> [图片2] ...")
            sys.exit(1)
        outs = convert_to_bmp(a.files, a.out)
        print("\n生成的 BMP 已放在 %s/" % a.out)
        print("下一步(管理员): python write_tfcard_audio.py raw --dev "
              r"\\.\PhysicalDriveN --bmp " + " ".join(outs) +
              " --wav music.wav --verify")
    else:
        if not a.dev:
            print("用法: python write_tfcard_audio.py raw --dev "
                  r"\\.\PhysicalDriveN [--bmp <bmp...>] [--wav <wav>] [--verify]")
            sys.exit(1)
        raw_write(a.dev, a.bmp, a.wav, a.verify)


if __name__ == "__main__":
    main()
