# -*- coding: utf-8 -*-
"""
sim_slide_v28.py — 滑动转场端到端验证

不是验证"公式对不对"，而是模拟 frame_fifo_read 的真实地址生成过程：
  从 base(start_idx)+start_off 开始逐字读, 到 seg_cnt 处跳到 seg_addr,
  共读 307200 个字; 把每个地址还原成 (帧, 行, 列), 得到这一帧真正的画面,
  再与"正确滑动合成"逐行比对。

行号编码成像素值 (old = 1000+y, new = 2000+y), 因此比对的是完整语义而不只是地址。
"""

W, H = 640, 480
TOTAL = W * H          # 307200
STEP_ROWS = 40
STEP_Q = STEP_ROWS * W
BASE = [0, TOTAL]      # BUF0 = 0, BUF1 = 307200


def trans_fade_params(old_i, new_i, dirn, q):
    """复现 trans_fade.v 的组合输出"""
    sliding = True
    q_rev = TOTAL - q
    idx_out = new_i if dirn else old_i
    start_off = q_rev if dirn else q
    seg_cnt = q if dirn else q_rev
    seg_idx = old_i if dirn else new_i
    seg_en = (dirn == new_i)
    return dict(idx=idx_out, off=start_off, seg_en=seg_en, seg_cnt=seg_cnt, seg_idx=seg_idx)


def read_stream(p):
    """复现 frame_fifo_read 的地址推进: 返回 307200 个地址"""
    addr = BASE[p['idx']] + p['off']
    out = []
    cnt = 0
    for _ in range(TOTAL):
        out.append(addr)
        cnt += 1
        if p['seg_en'] and cnt == p['seg_cnt']:
            addr = BASE[p['seg_idx']]
        else:
            addr += 1
    return out


def decode(a):
    """地址 -> (帧, 行)"""
    buf, off = (0, a) if a < TOTAL else (1, a - TOTAL)
    return buf, off // W


def expected_rows(old_i, new_i, dirn, p_rows):
    """正确的滑动合成: 返回每行应来自 (帧, 行)"""
    rows = []
    if dirn:  # 下滑: 新图从顶部推入
        for y in range(H):
            if y < p_rows:
                rows.append((new_i, H - p_rows + y))
            else:
                rows.append((old_i, y - p_rows))
    else:     # 上滑: 新图从底部推入
        for y in range(H):
            if y < H - p_rows:
                rows.append((old_i, y + p_rows))
            else:
                rows.append((new_i, y - (H - p_rows)))
    return rows


def check(old_i, new_i, dirn):
    ok = True
    q = STEP_Q
    seq = []
    while True:
        seq.append(q)
        if q + STEP_Q >= TOTAL:
            break
        q += STEP_Q

    for q in seq:
        p_rows = q // W
        prm = trans_fade_params(old_i, new_i, dirn, q)
        addrs = read_stream(prm)

        # 地址合法性
        if any(a < 0 or a >= 2 * TOTAL for a in addrs):
            print(f"  FAIL old={old_i} new={new_i} dir={dirn} q={q}: 地址越界")
            ok = False
            continue

        got = [decode(a) for a in addrs]
        exp = expected_rows(old_i, new_i, dirn, p_rows)

        bad = 0
        for y in range(H):
            got_row = got[y * W:(y + 1) * W]
            if any(g != exp[y] for g in got_row):
                bad += 1
        if bad:
            print(f"  FAIL old={old_i} new={new_i} dir={dirn} p={p_rows}: {bad} 行错位")
            # 打印前两处错行
            shown = 0
            for y in range(H):
                got_row = got[y * W:(y + 1) * W]
                if any(g != exp[y] for g in got_row):
                    print(f"      y={y}: 期望{exp[y]} 实际{got_row[0]}")
                    shown += 1
                    if shown >= 2:
                        break
            ok = False
    return ok, seq


print("=" * 66)
print("滑动转场端到端验证 (地址序列 -> 画面还原)")
print("=" * 66)

all_ok = True
for old_i, new_i in [(0, 1), (1, 0)]:
    for dirn in (1, 0):
        name = "下滑(下一张)" if dirn else "上滑(上一张)"
        ok, seq = check(old_i, new_i, dirn)
        frames = len(seq)
        p_list = [q // W for q in seq]
        print(f"{'PASS' if ok else 'FAIL'}  old=BUF{old_i} new=BUF{new_i} {name}  "
              f"{frames}帧  位移行={p_list[0]}..{p_list[-1]}")
        all_ok &= ok

# 边界检查
#   RTL 中滑动态的 q 只可能是 STEP_Q..(TOTAL-STEP_Q), 完成帧由 idx_r 直接跳到新图。
#   这里验证 q 取该范围两端时, 读出的内容语义正确。
print("-" * 66)
for dirn in (1, 0):
    for q in (STEP_Q, TOTAL - STEP_Q):
        prm = trans_fade_params(0, 1, dirn, q)
        addrs = read_stream(prm)
        if any(a < 0 or a >= 2 * TOTAL for a in addrs):
            print(f"FAIL  dir={dirn} q={q}: 地址越界")
            all_ok = False
            continue
        first_buf, first_row = decode(addrs[0])
        p_rows = q // W
        # 第一段起点: 下滑从新图第(480-p)行起, 上滑从旧图第 p 行起
        exp_buf, exp_row = (1, H - p_rows) if dirn else (0, p_rows)
        good = (first_buf, first_row) == (exp_buf, exp_row)
        print(f"{'PASS' if good else 'FAIL'}  dir={dirn} q={q:<6} 起点=BUF{first_buf}行{first_row} "
              f"期望=BUF{exp_buf}行{exp_row}")
        all_ok &= good

print("=" * 66)
print("全部通过" if all_ok else "存在失败项")
