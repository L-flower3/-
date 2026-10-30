# sd_hdmi_bmp 线性全流程 batch 脚本 (HDMI 音频版: key_next=A10, key_auto=B10 电平轮播
#                       + 官方 HDMI1.4b 发射核输出 48kHz 音频测试音)
# cwd = 工程根目录
import_device eagle_s20.db -package EG4S20BG256
open_project sd_hdmi_bmp.al
commit_param -step design
elaborate -top top
read_adc sd_hdmi_bmp.adc
read_sdc sd_hdmi_bmp.sdc
commit_param -step rtl
insert_debugger
optimize_rtl
report_area -file sd_hdmi_bmp_rtl.area
commit_param -step gate
optimize_gate -packarea sd_hdmi_bmp_gate.area
legalize_phy_inst
update_timing
report_timing_summary -file sd_hdmi_bmp_gate.timing
commit_param -step place
place
update_timing -mode manhattan
report_timing_summary -file sd_hdmi_bmp_place.timing
commit_param -step route
route
update_timing -mode final
report_timing_summary -file sd_hdmi_bmp_pr.timing
commit_param -step bitgen
bitgen -bit sd_hdmi_bmp.bit
puts "BUILD_DONE_OK"