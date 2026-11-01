# 以芯止戈 · HDMI 多媒体播放系统（定稿 V36）

安路 EG4S20BG256 + TD 6.2.168116（安装目录名为 `TD5.6.2`，实际版本 6.2.168116）。
上电数码管先显示 `36` 两秒，即本版 bit。

## 烧写与重编译

- 烧写文件：`bitstream/sd_hdmi_bmp.bit`（642 428 B，MD5 `cea6f97d5733ead6ce48ebc1db019e00`）
- 重编译：在工程根目录执行
  `D:\Anlogic\TD5.6.2\bin\run.exe build.tcl`
  脚本已固定 `set_param gate map_seed 1`，重跑后时序应与下表一致；若换了种子，必须重看 `route.qor` 的 WNS。
- 图形界面：双击 `sd_hdmi_bmp.al` 打开 TD。

## 当前版本指标（`reports/route.qor` / `reports/sd_hdmi_bmp_gate.area`）

| 项目 | 数值 |
|---|---|
| 建立余量 SWNS | +0.185 ns（0 违例端点） |
| 保持余量 HWNS | +0.011 ns（0 违例端点） |
| slices | 4894 |
| LUT / REG | 8018 / 19600（40.91%）、5308 |
| BRAM / DSP | 33 / 64、13 / 29 |
| IO | 36 / 188 |

## 目录说明

```
sd_hdmi_bmp.al                  TD 工程定义（源文件按类别分组，路径已同步）
build.tcl                       线性全流程批处理（综合→布局→布线→bitgen）
rtl/                            用户 RTL（30 个 .v，含 top.v）
ip/                             9 个 IP：4 个官方加密核(.enc.v) + 3 个 PLL + 2 个异步 FIFO
constraints/                    sd_hdmi_bmp.adc / sd_hdmi_bmp.sdc
bitstream/                      交付用 bit：sd_hdmi_bmp.bit
reports/                        QoR / 面积 / 时序报告（文档里的数字出自这里）
osd/                            字符与应急画面的 ROM 表头文件（.vh）
tools/                          辅助脚本（按键映射仿真、写卡音频等）
doc/                            交付文档
  ├─ 技术文档_以芯止戈_V34_整合版_V5.docx / .pdf    最终技术文档
  ├─ 现场演示视频台词_CHR战队_V1.docx / .pdf        演示视频台词本
  ├─ 现场演示视频台词_纯文本版.txt                  配音用纯文本
  ├─ 按键功能说明.md
  ├─ fig/                      文档插图 PNG（6 张）
  └─ src/                      文档与插图的生成脚本
```

`build.tcl` 的产物已按上述结构写入 `reports/` 与 `bitstream/`；
`sd_hdmi_bmp_Runs/` 是 TD 自动生成的中间目录，重编译会自动重建，因此不纳入版本库（见 `.gitignore`）。

## 备注

- 技术文档 V5 里写的是「TD 5.6.2」、LUT 7959 / 40.61%、SWNS +0.287 ns，那是 V34 那一版的数据；
  V36 实际为 TD 6.2.168116、LUT 8018 / 40.91%、SWNS +0.185 ns。文档按用户要求保持原样未改。
- 旧版本文件、预览图、历史 bit、编译日志已整体移到
  `D:\Work buddy Project\_archive_zuizhong_20261101\`，未删除。
