# sd_hdmi_bmp 线性全流程 batch 脚本 (HDMI 音频版: key_next=A10, key_auto=B10 电平轮播
#                       + 官方 HDMI1.4b 发射核输出 48kHz 音频测试音)
# cwd = 工程根目录
import_device eagle_s20.db -package EG4S20BG256
open_project sd_hdmi_bmp.al
commit_param -step design
elaborate -top top
read_adc constraints/sd_hdmi_bmp.adc
read_sdc constraints/sd_hdmi_bmp.sdc
commit_param -step rtl
insert_debugger
optimize_rtl
report_area -file reports/sd_hdmi_bmp_rtl.area
commit_param -step gate
# V36: 固定 gate 映射种子 —— 交付的 bit 用 seed 1 (建立余量 0.185ns / 保持 0.011ns),
#      写上这一行才能重编译复现同一个 bit; 换种子可换布局解, 但需重新看 route.qor 的 WNS。
set_param gate map_seed 1
optimize_gate -packarea reports/sd_hdmi_bmp_gate.area
legalize_phy_inst
update_timing
report_timing_summary -file reports/sd_hdmi_bmp_gate.timing
commit_param -step place
place
update_timing -mode manhattan
report_timing_summary -file reports/sd_hdmi_bmp_place.timing
commit_param -step route
route
update_timing -mode final
report_timing_summary -file reports/final_timing.rpt
commit_param -step bitgen
bitgen -bit bitstream/sd_hdmi_bmp.bit
puts "BUILD_DONE_OK"