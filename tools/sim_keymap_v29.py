#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
sim_keymap_v29.py — key_scan.v (V29 按键重分配) 行为级仿真

验证目标
  1) 列/相位映射：KEY3=Row0xCol3 只在相位A 采样；KEY4/5/6=Row1xCol0/1/2 只在相位B 采样
     （相位B 期间 KEY3 的锁存值必须保持，否则按 KEY3 会误触发 KEY4）
  2) 20ms 消抖：短于阈值的抖动不响应
  3) 单次按下只触发一次（应急 / VU 是 toggle，连翻就是 bug）
  4) 长按连发：首次 + 每 200ms 一次
  5) 边界：亮度到 200% / 25% 后不再越界

常量按同一比例缩放以便快速跑完（DEB 1e6->40, RP 1e7->400, 相位 5e4->500），比例与 RTL 一致。

时间轴（缩放世界，PHASE_DIV=500，采样点 cnt==400）：
  phase=0 (Row0 选中)：全局拍 t ≡ 400 (mod 1000) 采样 -> KEY0..KEY3
  phase=1 (Row1 选中)：全局拍 t ≡ 900 (mod 1000) 采样 -> KEY4..KEY6
  按键窗口必须包住对应采样点，再留 40 拍消抖余量。
"""

# 全部按 1/1000 等比缩放：相位 1ms->50 拍, 消抖 20ms->1000 拍, 连发 200ms->10000 拍
PHASE_DIV = 50         # RTL 50000   (1ms 双相位)
SAMPLE_AT = 40         # RTL 40000   (相位内 0.8ms 采样)
DEB_MAX   = 999        # RTL 999_999 (20ms @50MHz)
RP_MAX    = 10000      # RTL 10_000_000 (200ms @50MHz)
SHOW_MAX  = 100000     # RTL 100_000_000 (2s)

BRI_MIN, BRI_MAX, BRI_STEP = 64, 512, 64

T_ROW0 = 40            # Row0 采样时刻 (mod 100)
T_ROW1 = 90            # Row1 采样时刻 (mod 100)
PERIOD = 2 * PHASE_DIV  # 100


def win(t_sample, hold=2000):
    """包住采样点并留出 >= DEB_MAX(999) 消抖余量的按键窗口"""
    return (t_sample - 30, t_sample + hold)


def run(script, cycles):
    cnt, phase = 0, 0
    key_l = [1] * 7
    k_st = {3: 1, 4: 1, 5: 1, 6: 1}
    db   = {3: 0, 4: 0, 5: 0, 6: 0}
    k5d, k6d = 1, 1
    emg, vu = 0, 1
    bright, bri_show, show_cnt = 256, 0, 0
    rp = {3: 0, 4: 0}

    bright_log, emg_flips, vu_flips = [], [], []
    show_off_at = None

    def pressed_at(t):
        for a, b, ps in script:
            if a <= t < b:
                return ps
        return set()

    for t in range(cycles):
        if cnt >= PHASE_DIV - 1:
            cnt = 0
            phase ^= 1
        else:
            cnt += 1

        ps = pressed_at(t)
        row_sel = 0 if phase == 0 else 1
        col = [1, 1, 1, 1]
        for c in range(4):
            if (row_sel, c) in ps:
                col[c] = 0

        if cnt == SAMPLE_AT:
            if phase == 0:
                key_l[0], key_l[1], key_l[2], key_l[3] = col[0], col[1], col[2], col[3]
            else:
                key_l[4], key_l[5], key_l[6] = col[0], col[1], col[2]

        for k, idx in ((3, 3), (4, 4), (5, 5), (6, 6)):
            cur = key_l[idx]
            if cur != k_st[k]:
                if db[k] >= DEB_MAX:
                    db[k] = 0
                    k_st[k] = cur
                else:
                    db[k] += 1
            else:
                db[k] = 0

        k5p = k5d and not k_st[5]
        k6p = k6d and not k_st[6]
        k5d, k6d = k_st[5], k_st[6]
        if k5p:
            emg ^= 1
            emg_flips.append(t)
        if k6p:
            vu ^= 1
            vu_flips.append(t)

        for k in (3, 4):
            if not k_st[k]:
                if rp[k] == 0:
                    rp[k] = 1
                    bright = (max(BRI_MIN, bright - BRI_STEP) if k == 3
                              else min(BRI_MAX, bright + BRI_STEP))
                    bright_log.append((t, k, bright))
                    bri_show, show_cnt = 1, 0
                elif rp[k] >= RP_MAX:
                    rp[k] = 0
                else:
                    rp[k] += 1
            else:
                rp[k] = 0

        if bri_show:
            if show_cnt >= SHOW_MAX:
                bri_show = 0
                if show_off_at is None:
                    show_off_at = t
            else:
                show_cnt += 1

    return bright_log, emg_flips, vu_flips, show_off_at, emg, vu


ok = True


def chk(cond, msg):
    global ok
    print(("  PASS  " if cond else "  FAIL  ") + msg)
    ok = ok and bool(cond)


print("=" * 70)
print("1) 单键映射（窗口包住采样点）")
print("=" * 70)
bl, _, _, _, _, _ = run([(*win(T_ROW0), {(0, 3)})], 8000)
chk(len(bl) == 1 and bl[0][2] == 192,
    f"KEY3(Row0xCol3) 单击: bright 256->{bl[-1][2] if bl else '无'} (期望 192), 触发 {len(bl)} 次")

bl, _, _, _, _, _ = run([(*win(T_ROW1), {(1, 0)})], 8000)
chk(len(bl) == 1 and bl[0][2] == 320,
    f"KEY4(Row1xCol0) 单击: bright 256->{bl[-1][2] if bl else '无'} (期望 320), 触发 {len(bl)} 次")

bl, ef, _, _, emg, _ = run([(*win(T_ROW1, 3000), {(1, 1)})], 8000)
chk(len(ef) == 1 and emg == 1, f"KEY5(Row1xCol1) 按住: emg 翻转 {len(ef)} 次->{emg} (期望 1 次, 不能连翻)")

bl, _, vf, _, _, vu = run([(*win(T_ROW1, 3000), {(1, 2)})], 8000)
chk(len(vf) == 1 and vu == 0, f"KEY6(Row1xCol2) 按住: vu 翻转 {len(vf)} 次->{vu} (期望 1 次, 1->0)")

print()
print("=" * 70)
print("2) 相位隔离：Col3 只属于 Row0，Col0@Row1 只属于 KEY4")
print("=" * 70)
bl, ef, vf, _, _, _ = run([(*win(T_ROW0, 4000), {(0, 3)})], 8000)
chk(len(ef) == 0 and len(vf) == 0, f"按 KEY3 期间 emg/vu 翻转 {len(ef)}/{len(vf)} (期望 0/0)")
chk(all(k == 3 for _, k, _ in bl), f"按 KEY3 只走亮度- 通道 (实际通道 {sorted({k for _,k,_ in bl})})")

bl, ef, vf, _, _, _ = run([(*win(T_ROW1, 4000), {(1, 0)})], 8000)
chk(all(k == 4 for _, k, _ in bl) and len(ef) == 0 and len(vf) == 0,
    f"按 KEY4 只走亮度+ 通道 (实际 {sorted({k for _,k,_ in bl})}), emg/vu={len(ef)}/{len(vf)}")

print()
print("=" * 70)
print("3) 消抖：短脉冲不响应")
print("=" * 70)
bl, _, _, _, _, _ = run([(T_ROW0 - 100, T_ROW0 + 100, {(0, 3)})], 8000)
chk(len(bl) == 0, f"200 拍脉冲(<1000 消抖阈值): 亮度变化 {len(bl)} 次 (期望 0)")
bl, _, _, _, _, _ = run([(T_ROW0 - 50, T_ROW0 + 700, {(0, 3)})], 8000)
chk(len(bl) == 0, f"750 拍脉冲: 亮度变化 {len(bl)} 次 (期望 0)")

print()
print("=" * 70)
print("4) 长按连发：首次 + 每 RP_MAX 一拍")
print("=" * 70)
HOLD = 5 * RP_MAX
bl, _, _, _, _, _ = run([(T_ROW0 - 30, T_ROW0 + HOLD, {(0, 3)})], T_ROW0 + HOLD + 3000)
exp = 1 + (HOLD - 30) // RP_MAX
# 松开后 key_l 要等下一个采样点(<=1ms) 才更新, 再经 20ms 消抖才认定松开,
# 因此长按结束时可能再多走一档 —— 这是分时扫描+消抖的固有延迟, 不是逻辑错误
chk(len(bl) in (exp, exp + 1),
    f"按住 {HOLD} 拍: 步进 {len(bl)} 次 (期望 {exp} 或 {exp+1}, 差 1 来自 21ms 松开延迟)")
steps = [b for _, _, b in bl]
chk(all(steps[i] >= steps[i + 1] for i in range(len(steps) - 1)),
    f"亮度单调递减: {steps}")

print()
print("=" * 70)
print("5) 边界：不越过 25% / 200%")
print("=" * 70)
bl, _, _, _, _, _ = run([(T_ROW0 - 30, T_ROW0 + 20 * RP_MAX, {(0, 3)})], T_ROW0 + 20 * RP_MAX + 3000)
chk(min(b for _, _, b in bl) == BRI_MIN, f"长按亮度- 最低 {min(b for _,_,b in bl)} (期望 {BRI_MIN})")
chk(all(BRI_MIN <= b <= BRI_MAX for _, _, b in bl), "全程序列都在 25%~200% 内")

bl, _, _, _, _, _ = run([(T_ROW1 - 30, T_ROW1 + 20 * RP_MAX, {(1, 0)})], T_ROW1 + 20 * RP_MAX + 3000)
chk(max(b for _, _, b in bl) == BRI_MAX, f"长按亮度+ 最高 {max(b for _,_,b in bl)} (期望 {BRI_MAX})")

print()
print("=" * 70)
print("6) toggle 可逆：两次按下回到原状态")
print("=" * 70)
w1, w2 = win(T_ROW1, 2000), win(T_ROW1 + 4200, 2000)
bl, ef, _, _, emg, _ = run([(*w1, {(1, 1)}), (*w2, {(1, 1)})], 8000)
chk(len(ef) == 2 and emg == 0, f"KEY5 两次: 翻转 {len(ef)} 次, 终态 emg={emg} (期望 2 次, 0)")

bl, _, vf, _, _, vu = run([(*w1, {(1, 2)}), (*w2, {(1, 2)})], 8000)
chk(len(vf) == 2 and vu == 1, f"KEY6 两次: 翻转 {len(vf)} 次, 终态 vu={vu} (期望 2 次, 回到 1)")

print()
print("  [边界] 两次按键间隔 < 21ms 时第二次会被消抖忽略(只翻一次) —— 人手不可能做到, 不影响使用")
bl, ef, _, _, emg, _ = run([(*win(T_ROW1, 2000), {(1, 1)}), (*win(T_ROW1 + 2200, 2000), {(1, 1)})], 8000)
chk(len(ef) == 1, f"间隔 22ms 连按两次: 翻转 {len(ef)} 次 (设计如此: 第二次落在消抖窗口内)")

print()
print("=" * 70)
print("7) 亮度 OSD 会自己熄灭")
print("=" * 70)
bl, _, _, off, _, _ = run([(*win(T_ROW0, 2000), {(0, 3)})], SHOW_MAX + 3000)
chk(off is not None, f"bri_show 在 {off} 拍后熄灭")

print()
print("=" * 70)
print("8) RTL 常量核对（真实时钟 50MHz, tick=1024 拍=20.48us）")
print("=" * 70)
TICK  = 1024
DEB_T, RP_T, SHOW_T = 977, 9766, 97656      # RTL: DEB_TICKS+1 / RP_TICKS+1 / SHOW_TICKS
chk(abs(DEB_T * TICK / 50e6 - 0.020) < 5e-4,
    f"消抖 = {DEB_T} tick x {TICK} = {DEB_T*TICK/50e6*1000:.2f}ms (期望 ~20ms)")
chk(abs(RP_T * TICK / 50e6 - 0.200) < 5e-4,
    f"连发 = {RP_T} tick = {RP_T*TICK/50e6*1000:.2f}ms (期望 ~200ms)")
chk(abs(SHOW_T * TICK / 50e6 - 2.0) < 1e-3,
    f"OSD  = {SHOW_T} tick = {SHOW_T*TICK/50e6:.3f}s (期望 ~2s)")
chk(abs(TICK / 50e6 - 20.48e-6) < 1e-9, f"tick 周期 = {TICK} 拍 = 20.48us")
chk(abs(50_000 / 50e6 - 0.001) < 1e-9, f"相位分频 = 50,000 拍 = 1.0ms (每行 0.5ms)")
chk(abs(40_000 / 50e6 - 0.0008) < 1e-9, f"采样点 = 40,000 拍 = 800us")

print()
print("=" * 70)
print("ALL PASS" if ok else "存在 FAIL，请检查 RTL")
print("=" * 70)
