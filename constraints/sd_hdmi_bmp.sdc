# ============================================================================
# 时钟约束 sd_hdmi_bmp.sdc
# 50MHz 输入 -> clk_pll(100M SD时钟 / 100M SDRAM / 100M@180)
#              -> video_pll(25M 像素时钟 / 125M HDMI串行)
# ============================================================================

create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]

# 自动推导两个 PLL 的全部输出时钟
derive_pll_clocks -gen_basic_clock

# 相互独立的时钟域（跨域全部走异步FIFO/多级同步器，属安全CDC）：
#   g1: clk            50MHz  仅复位计数/数码管扫描
#   g2: clk_pll c0    100MHz  SD卡SPI + 帧写入
#   g3: clk_pll c1    100MHz  SDRAM 用户逻辑时钟（frame_read_write 全部在此域）
#   g4: clk_pll c2    100MHz@180  仅接入 sdr_as_ram 硬核的 Sdr_clk_sft
#                        （fanout=1；硬核内 c1/c2 路径为 PHY 签核路径，
#                          M0 官方 7_SDRAM_as_BRAM 例程同样不做同步检查）
#   g5: video_pll c0/c1 25M/125M HDMI 像素与5倍串行时钟（同域，不互切）
#   g6: (v5 已移除音频 PLL 实例，音频时钟为 100MHz 分频，与 sd_card_clk 同域，不另分组)
set_clock_groups -asynchronous \
    -group [get_clocks {clk}] \
    -group [get_clocks {u_clk_pll/pll_inst.clkc[0]}] \
    -group [get_clocks {u_clk_pll/pll_inst.clkc[1]}] \
    -group [get_clocks {u_clk_pll/pll_inst.clkc[2]}] \
    -group [get_clocks {u_video_pll/pll_inst.clkc[0] u_video_pll/pll_inst.clkc[1]}]