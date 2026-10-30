`timescale 1ns / 1ps
//============================================================================
// 模块名称 : top  (版本 V34)
// 功能描述 : TF卡读取 BMP(640x480/1280x960 x24bit) -> SDRAM 帧缓存 -> HDMI 显示
//            扫描前 4 张 BMP, KEY0 上一张 / KEY1 下一张 / KEY2 自动轮播；安路 EG4S20BG256 + M0 底板
//            HDMI 输出带 TF 卡 WAV 音频 (48000Hz/16bit/双声道, 播完无缝循环)
//            （官方 HDMI1.4b Transmitter 核 + TF 卡 WAV 流式播放 + ACR，
//              替换 v6 内部 I2S 测试音，实现真实音画同步播放）
// V26 变更 : 修复 sd_rst_cnt 位宽(1bit->32bit)看门狗死锁bug; 开机2秒数码管显示版本号
// V28 变更 : 切图转场由"渐黑+行扫描淡入"改为**方向性整帧滑动** ——
//            KEY1 下一张 = 画面下移/新图从顶部推入, KEY0 上一张 = 画面上移/新图从底部推入。
//            利用两个帧缓存在 SDRAM 中首尾相邻的特性, 只需给读地址加行偏移 + 帧内一次跳转,
//            不增加行缓冲/除法器/乘法器 (DSP 由 7 降为 6, 时序余量 0.124ns -> 0.184ns)。
// V29 变更 : 按键重新分配。KEY3 亮度- / KEY4 亮度+ / KEY5 应急 / KEY6 音频可视化 开/关。
//            新增 KEY3 引脚 (Col3 = F10, 来自核心板原理图 IO.SchDoc),
//            audio_vu 增加 enable 端口, 关闭时像素完全直通; 数码管版本号 28 -> 29。
// V30 变更 : 滑动转场"卡顿"优化。V28 是 40 行/帧 x 12 帧 (200ms), 每帧跳屏高 8.3%,
//            远超运动连贯阈值(2%~3%), 主观就是"跳几下就过去了"。
//            V30 改为 10 行/帧 (2.1% 屏高) x 48 帧 ≈ 800ms, 匀速滚动, 480/10 整除
//            所以末帧精确落位。逻辑上零新增(纯参数)。
//            踩坑记录: 步长常量一变, TD 的综合映射和布局解就变, SWNS 在
//            0.11~0.47ns 之间跳 (40->0.471 / 16->0.110 / 12->0.117 / 10->0.204),
//            所以 10 行是"最平滑且余量可接受"的那个点, 不是随手取的。
//            数码管版本号 29 -> 30。
// V31 变更 : 补上"对比度调节"(赛题扩展要求4 的明文项)。KEY6 从单一 VU 开关改为双功能:
//            短按仍是 VU 开关, 长按 800ms 切换「亮度↔对比度」调节模式;
//            KEY3/KEY4 变成"当前参数 -/+", 左上角第二行随之显示 BRI 或 CON。
//            对比度按 out=(rgb-128)*c/256+128 实现, 与亮度合并成一次
//            out = rgb*k/256 + offset (k=bright*contrast/256, offset=(256-contrast)/2),
//            像素通路只多一次加法与饱和。数码管版本号 30 -> 31。
// V32 变更 : 转场支持「淡入淡出」, 由新增的 KEY7 (Row1 x Col3 = C10 x F10) 切换
//            滑动 <-> 淡变, 上电默认滑动 (与之前行为一致)。左上角新增第三行
//            OSD 显示当前转场方式 "SLIDE" / "FADE"。
//            ★ 淡变用"淡出到黑 -> 换图 -> 淡入"而非叠化: 叠化要同一像素位置新旧
//              两图同时在读, 即 SDRAM 双读流, 本工程单读口做不到 (要再加一整套
//              fifo_read + FIFO + 仲裁), 而余量只有 0.18ns, 风险不可接受。
//            ★ 淡变的乘法完全复用 bright_ctrl 里已有的 k/offset 慢速通路
//              (k' = k*fade/16), 像素通路上零新增乘法器; trans_fade 只输出
//              fade_scale(0..16), 像素仍直通。一个转场 32 帧 ≈ 534ms。
//            ★ 顺手治了一条老毛病: bmp_read 里 file_len->(+511>>9)->(+scan_sector)
//              ->(>scan_max_sector)->scan_done 是三条 32bit 运算串起来的链,
//              100MHz 域实测 9.999ns/10ns。把 file_sector_count 单独打一拍
//              (file_len 在 header 第 2~5 字节就稳定, 实用点在 512 字节后,
//              滞后一拍无影响) 后, Setup WNS 从 -0.279ns 回到 +0.566ns。
//            数码管版本号 31 -> 32。
// V33 变更 : 音频可视化从"音量电平表"升级为"真频谱"。
//            V32 的 8 根柱子是 8 个时间片的峰值滚动(音量时间轴), 与频率无关。
//            V33 换成 8 段 biquad 倍频程带通滤波器组
//            (100/200/400/800/1600/3200/6400/11000 Hz, Q=2),
//            每根柱子 = 该频段实时能量。显示位置/柱宽/配色/按键全部不变,
//            audio_vu 端口未动, 所以本文件除了版本号没有任何改动。
//            数码管版本号 32 -> 33。
// V34 变更 : 新增第三种转场「旋转擦除」。KEY7 由两态改为三态循环
//            (滑动 -> 淡入淡出 -> 旋转擦除 -> 滑动), 左上角第三行显示 ROTATE。
//            一条边界半径绕屏幕中心匀速旋转 360°(48 帧 ≈ 800ms), 扫过的扇形
//            区域显示新图, 未扫到的保持旧图; 方向跟随按键 (KEY1 顺时针 /
//            KEY0 逆时针)。读取侧只能在突发边界换源帧, 因此把读突发由 128 字
//            降到 16 字(16 像素), 边界横向量化误差 2.5% 屏宽, 吞吐仍有余量。
//            像素通路零改动: 只改读地址, 不动 rgb 数据路径。
//            数码管版本号 33 -> 34。
//============================================================================
module top(
    input        clk,        // 50MHz 有源时钟 (R7)
    input        rst_n,      // SW0 拨码开关, 低有效复位 (A9, PULLUP)

    // 按键：核心板 4x4 矩阵键盘（Row0/Row1 分时拉低, Col0..Col3 上拉采样）
    //   KEY0(E11) 上一张   KEY1(D11) 下一张   KEY2(C11) 自动轮播
    //   KEY3(F10) 亮度-    KEY4(C10×E11) 亮度+  KEY5(C10×D11) 应急  KEY6(C10×C11) 音频可视化
    input        key0,       // KEY0 (列E11): 上一张
    input        key1,       // KEY1 (列D11): 下一张
    input        key2,       // KEY2 (列C11): 自动轮播 开/关
    input        key3,       // KEY3 (列F10): 亮度 -
    output       key_row,    // 矩阵键盘行驱动 Row0 (E10)
    output       key_row1,   // 矩阵键盘行驱动 Row1 (C10) -> KEY4/KEY5/KEY6

    // MicroSD 卡 SPI
    output       sd_sck,     // SD SPI 时钟 (F15)
    output       sd_cs_n,    // SD 片选 (F13)
    output       sd_mosi,    // SD MOSI (F14)
    input        sd_miso,    // SD MISO (D14)

    // HDMI 差分输出 (TMDS, 带音频数据岛)
    output       HDMI_CLK_P, // P1
    output       HDMI_D2_P,  // J3
    output       HDMI_D1_P,  // P4
    output       HDMI_D0_P,  // N1

    // 调试 LED (高电平点亮)
    output [7:0] led,

    // 4 位数码管 (共阴, 位选低有效, 段选高有效)
    output [3:0] seg_sel,
    output [7:0] seg_led
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter FRAME_PIXELS  = 24'd307200;   // 640*480
parameter BUF0_ADDR     = 24'd0;
parameter BUF1_ADDR     = FRAME_PIXELS;

//--------------------- 时钟/复位 ---------------------
wire sd_card_clk;              // clk_pll clk0 = 100MHz (SD卡 + 帧写入时钟域)
wire ext_mem_clk;              // 100MHz SDRAM 时钟
wire ext_mem_clk_sft;          // 100MHz @180 相移
wire video_clk;                // 25MHz 像素时钟
wire hdmi_5x_clk;              // 125MHz 5x 串行时钟
wire clk_pll_lock;
wire video_pll_lock;
wire rst_all;

reg [7:0] rst_cnt;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)            rst_cnt <= 8'd0;
    else if (!rst_cnt[7])  rst_cnt <= rst_cnt + 8'd1;
end

wire pll_rst = !rst_cnt[7];    // 上电复位脉冲 (高有效)

clk_pll u_clk_pll(
    .refclk   (clk),
    .reset    (pll_rst),
    .extlock  (clk_pll_lock),
    .clk0_out (sd_card_clk),
    .clk1_out (ext_mem_clk),
    .clk2_out (ext_mem_clk_sft)
);

video_pll u_video_pll(
    .refclk   (clk),
    .reset    (pll_rst),
    .extlock  (video_pll_lock),
    .clk0_out (video_clk),
    .clk1_out (hdmi_5x_clk)
);

// 整机复位链：只依赖主 PLL(SD/帧缓存) 与视频 PLL(HDMI 像素)，**不含音频 PLL**。
//   WAV 音频由 TF 卡流式读取，无独立音频 PLL。
assign rst_all = (!clk_pll_lock) | (!video_pll_lock) | (!rst_n);

//--------------------- 矩阵键盘分时扫描 + 消抖 ---------------------
//  Row0(E10)/Row1(C10) 1kHz 交替拉低; Col0/1/2/3 = E11/D11/C11/F10
//  相位A (Row0) -> KEY0/KEY1/KEY2 (切图/轮播) + KEY3 (当前参数-)
//  相位B (Row1) -> KEY4 (当前参数+) / KEY5 (应急) / KEY6 (短按 VU, 长按切模式)
//                  / KEY7 (切换转场方式)
wire key0_l, key1_l, key2_l, key3_l;
wire emg_state;
wire vu_on;                  // KEY6 短按: 音频可视化开关
wire [9:0] bright_val;       // 亮度增益 (256=100%) —— 必须在 key_scan 实例前声明
wire [9:0] contrast_val;     // 对比度增益 (256=100%, 128..512 即 50%..200%)
wire       con_mode;         // 0=KEY3/4 调亮度  1=调对比度 (KEY6 长按切换)
wire       bri_show;         // 参数 OSD 使能窗口
wire [1:0] trans_mode_raw;   // KEY7: 转场方式 (50MHz 域) 0=滑动 1=淡变 2=旋转 (V34)

key_scan u_key_scan (
    .clk       (clk),
    .rst       (rst_all),
    .col0      (key0),
    .col1      (key1),
    .col2      (key2),
    .col3      (key3),
    .row0      (key_row),
    .row1      (key_row1),
    .key0_l    (key0_l),
    .key1_l    (key1_l),
    .key2_l    (key2_l),
    .key3_l    (key3_l),
    .emg_state (emg_state),
    .bright    (bright_val),
    .bri_show  (bri_show),
    .contrast  (contrast_val),
    .con_mode  (con_mode),
    .vu_on     (vu_on),
    .trans_mode(trans_mode_raw)
);

//--------------------- SD 读取 -> 帧写入 ---------------------
wire        Sdr_init_done;
wire        Sdr_init_ref_vld;
wire        Sdr_busy;

wire [3:0]  state_code;
wire        display_valid;
wire        img_is_1280;       // 当前显示图分辨率 (100MHz 域, 来自 sd_card_bmp)

wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        frame_write_finish;
reg         frame_write_toggle_mem;

wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;

// mem_clk 域把 write_finish 单拍转 toggle，供 sd_card_clk(=50MHz) 域可靠同步
always @(posedge ext_mem_clk or posedge rst_all) begin
    if (rst_all)              frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish) frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

// WAV 音频 FIFO 读侧 / 状态 (在 u_sd_card_bmp 实例之前声明)
wire [31:0] wav_fifo_dout;
wire        wav_fifo_empty;
wire [9:0]  wav_fifo_rdusedw;
wire        wav_fifo_re;
wire        wav_found;
wire        wav_playing;
wire        sd_init_status;   // SD 卡初始化完成 (led6 诊断)

sd_card_bmp #(
    .CLK_FREQ_HZ       (100_000_000),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (3'd4)          // 扫描前 4 张 BMP, 确保 640/1280 两种分辨率都能被找到
) u_sd_card_bmp(
    .clk               (sd_card_clk),  // 100MHz SD 卡 + 帧写入时钟域
    .rst               (rst_all),
    .key_prev          (key0_l | emg_state),   // 应急时锁定         // KEY0: 上一张
    .key_next          (key1_l | emg_state),         // KEY1: 下一张
    .key_auto          (key2_l | emg_state),         // KEY2: 自动轮播 开/关
    .bmp_width         (16'd640),
    .bmp_height        (16'd480),
    .display_valid     (display_valid),
    .state_code        (state_code),
    .write_finish_toggle(frame_write_toggle_mem),
    .write_buf_idx     (write_buf_idx),
    .disp_buf_idx      (disp_buf_idx),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .SD_nCS            (sd_cs_n),
    .SD_DCLK           (sd_sck),
    .SD_MOSI           (sd_mosi),
    .SD_MISO           (sd_miso),
    .fifo_rclk         (video_clk),
    .wav_fifo_re       (wav_fifo_re),
    .wav_fifo_dout     (wav_fifo_dout),
    .wav_fifo_empty    (wav_fifo_empty),
    .wav_fifo_rdusedw  (wav_fifo_rdusedw),
    .wav_found         (wav_found),
    .wav_playing       (wav_playing),
    .sd_init_status    (sd_init_status),
    .img_is_1280       (img_is_1280)
);

//--------------------- 视频时序 + 帧读取 ---------------------
wire        video_read_req;
wire        video_read_req_ack;
wire        video_read_en;
wire [31:0] video_read_data;
wire        hs_0, vs_0, de_0;
wire        hs, vs, de;
wire [23:0] vout_data_raw;
wire [23:0] vout_bri;        // 亮度调节后(送转场层)
wire [23:0] vout_faded;      // 转场后(送字幕层)
wire [23:0] vout_av;         // VU表后(送应急层)
wire        audio_valid;     // 48kHz 音频帧节拍(由 wav_audio_out 产生)
wire [23:0] audio_left_data; // WAV 左声道
wire [23:0] audio_right_data;// WAV 右声道
wire [23:0] vout_data;
wire [1:0]  disp_idx_used;   // 经转场状态机延时后的显示缓冲索引

video_timing_data u_vtiming(
    .video_clk   (video_clk),
    .rst         (rst_all),
    .read_req    (video_read_req),
    .read_req_ack(video_read_req_ack),
    .hs          (hs_0),
    .vs          (vs_0),
    .de          (de_0)
);

video_delay u_vdelay(
    .video_clk (video_clk),
    .rst       (rst_all),
    .read_en   (video_read_en),
    .read_data (video_read_data[31:8]),
    .hs        (hs_0),
    .vs        (vs_0),
    .de        (de_0),
    .hs_r      (hs),
    .vs_r      (vs),
    .de_r      (de),
    .vout_data (vout_data_raw)
);

//--------------------- 分辨率标志跨时钟域同步 (100MHz -> 25MHz) ---------------------
reg [2:0] is1280_sync;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) is1280_sync <= 3'b000;
    else         is1280_sync <= {is1280_sync[1:0], img_is_1280};
end
wire is_1280_video = is1280_sync[2];

//--------------------- 转场方式跨时钟域同步 (50MHz -> 25MHz) ---------------------
//  KEY7 在 50MHz 域改 trans_mode_raw (2bit 慢变), 这里打两拍再用
reg [1:0] tmode_s1, tmode_s2;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        tmode_s1 <= 2'd0;
        tmode_s2 <= 2'd0;
    end else begin
        tmode_s1 <= trans_mode_raw;
        tmode_s2 <= tmode_s1;
    end
end
wire [1:0] trans_mode_v = tmode_s2;

// V34: 旋转擦除参数 (trans_fade <-> frame_read_write)
wire        wipe_en_w;
wire [1:0]  wipe_q_w;
wire signed [19:0] wipe_x0_w;
wire signed [11:0] wipe_dx_w;
wire        wipe_dir_w;
wire        wipe_new_idx_w;
wire        wipe_full_w;

// 淡变系数由 trans_fade 产生 (0..8), 送 brightness 层当增益用
//   ★ 注意方向: bright_ctrl 在数据通路上位于 trans_fade 之前, 但这里只是把
//     "慢变的系数" 回头喂给它, 不构成组合环 —— fade_scale 只依赖转场状态机,
//     不依赖任何像素值, 且每场才变一次。
wire [4:0] fade_scale;

// 亮度/对比度调节: 只作用于图片画面
//   亮度 25%~200%, 对比度 50%~200%, 256 = 100%
//   左上角常显两行状态栏: "640x480"(分辨率) / "BRI 100%" 或 "CON 100%"(当前参数)
//   两个参数在 bright_ctrl 里合并为 out = rgb*k/256 + offset 一次算完
bright_ctrl #(
    .ALWAYS_ON (1)
) u_bright_ctrl (
    .clk      (video_clk),
    .rst      (rst_all),
    .hs       (hs),
    .vs       (vs),
    .de       (de),
    .bright   (bright_val),
    .contrast (contrast_val),
    .con_mode (con_mode),
    .fade     (fade_scale),
    .trans_mode (trans_mode_v),
    .show     (display_valid),
    .bri_show (bri_show),
    .is_1280  (is_1280_video),
    .rgb_in   (vout_data_raw),
    .rgb_out  (vout_bri)
);

//--------------------- 切图滑动转场 (方向由按键决定) ---------------------
//  KEY1「下一张」-> 画面下移, 新图从顶部推入
//  KEY0「上一张」-> 画面上移, 新图从底部推入
//  KEY0/KEY1 是 50MHz 域锁存电平, 先同步到 sd_card_clk 域取下降沿(按下),
//  锁成 slide_dir 慢变电平, 再同步到 video_clk 域给转场状态机用。
reg k0_s1, k0_s2, k1_s1, k1_s2;
reg slide_dir_sd;
always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
        k0_s1 <= 1'b1; k0_s2 <= 1'b1;
        k1_s1 <= 1'b1; k1_s2 <= 1'b1;
        slide_dir_sd <= 1'b1;                 // 默认: 下一张方向(下滑), 自动轮播沿用它
    end else begin
        k0_s1 <= key0_l;  k0_s2 <= k0_s1;
        k1_s1 <= key1_l;  k1_s2 <= k1_s1;
        if      (k1_s2 & ~k1_s1) slide_dir_sd <= 1'b1;   // KEY1 按下 -> 下滑
        else if (k0_s2 & ~k0_s1) slide_dir_sd <= 1'b0;   // KEY0 按下 -> 上滑
    end
end

reg [1:0] dir_sync;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) dir_sync <= 2'b11;
    else         dir_sync <= {dir_sync[0], slide_dir_sd};
end
wire slide_dir = dir_sync[1];

wire [20:0] rd_start_off;     // 读起始地址偏移(字)
wire        rd_seg_en;        // 帧内跳转使能
wire [18:0] rd_seg_cnt;       // 跳转点
wire        rd_seg_idx;       // 跳转目标帧

// 两个帧缓存在 SDRAM 中首尾相邻, 起始偏移统一加到两个基址上
wire [20:0] rd_base0    = BUF0_ADDR + rd_start_off;
wire [20:0] rd_base1    = BUF1_ADDR + rd_start_off;
wire [20:0] rd_seg_addr = rd_seg_idx ? BUF1_ADDR : BUF0_ADDR;

// 放在字幕层之前: 画面参与滑动, 字幕保持常亮
trans_fade #(
    // V30 平滑参数: 10 行/帧 (= 屏高 2.1%) x 48 帧, 总时长约 800ms
    //   480/10 = 48 整数帧, 末帧精确落到整数屏, 无补差尾步。
    // V28 旧参数: STEP_ROWS=40 (12 帧/200ms, 每步跳 8.3% 屏高, 观感是"跳几下")
    // ⚠ 这里改数必须重编译看 SWNS: 实测 STEP 常量一变, TD 的布局解就变,
    //   SWNS 会在 0.11~0.47ns 之间跳 (40->0.471, 16->0.110, 12->0.117, 10->0.204)
    .STEP_ROWS (10),                  // 每帧位移行数 (屏高 2.1%, 48 帧)
    .OUT_W     (640),
    .OUT_H     (480)
) u_trans_fade (
    .clk       (video_clk),
    .rst       (rst_all),
    .vs        (vs),
    .de        (de),
    .disp_on   (display_valid),
    .new_idx   (disp_buf_idx),
    .dir       (slide_dir),
    .mode      (trans_mode_v),
    .rgb_in    (vout_bri),
    .rgb_out   (vout_faded),
    .idx_out   (disp_idx_used),
    .start_off (rd_start_off),
    .seg_en    (rd_seg_en),
    .seg_cnt   (rd_seg_cnt),
    .seg_idx   (rd_seg_idx),
    .fade_scale(fade_scale),
    .wipe_en      (wipe_en_w),
    .wipe_q       (wipe_q_w),
    .wipe_x0      (wipe_x0_w),
    .wipe_dx      (wipe_dx_w),
    .wipe_dir     (wipe_dir_w),
    .wipe_new_idx (wipe_new_idx_w),
    .wipe_full    (wipe_full_w)
);

wire [23:0] vout_osd;

// 首图提交前黑屏, 提交后显示; 底部叠加滚动字幕"同守一片蓝天，共护世界和平"
osd_scroll #(
    .SCROLL_STEP(1)
) u_osd_scroll (
    .clk    (video_clk),
    .rst    (rst_all),
    .hs     (hs),
    .vs     (vs),
    .de     (de),
    .en_v   (display_valid),
    .rgb_in (vout_faded),
    .rgb_out(vout_osd)
);

//--------------------- 应急警报音 (DDS 方波, 800/600Hz 每0.35s交替) ---------------------
reg [23:0] al_ph;         // 相位累加器
reg [15:0] al_tcnt;       // 0.35s 切换计数 (48kHz)
reg        al_alt;

always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        al_ph   <= 24'd0;
        al_tcnt <= 16'd0;
        al_alt  <= 1'b0;
    end else if (audio_valid) begin
        // 800Hz: 279620, 600Hz: 209715  (inc = f/48000 * 2^24)
        al_ph <= al_ph + (al_alt ? 24'd279620 : 24'd209715);
        if (al_tcnt >= 16'd16800) begin
            al_tcnt <= 16'd0;
            al_alt  <= ~al_alt;
        end else begin
            al_tcnt <= al_tcnt + 16'd1;
        end
    end
end

wire [23:0] alarm_sample = al_ph[23] ? 24'h7FFF00 : 24'h800000;   // 方波 ±full

// 应急时: 音源切警报; 平时: TF 卡 WAV
wire [23:0] audio_l_core = emg_state ? alarm_sample : audio_left_data;
wire [23:0] audio_r_core = emg_state ? alarm_sample : audio_right_data;

// 右上角 8 柱音量电平表 (音频可视化, 实时跟随 WAV 音量)
//   KEY6 控制开/关; vu_on 在 50MHz 域, 单 bit 慢变化信号打两拍同步到 video_clk
reg vu_on_v1, vu_on_v2;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        vu_on_v1 <= 1'b1;
        vu_on_v2 <= 1'b1;
    end else begin
        vu_on_v1 <= vu_on;
        vu_on_v2 <= vu_on_v1;
    end
end

// VU 表在淡变期间暂时隐去: VU 表位于亮度/淡变层之后, 不受 fade 影响,
// 若不管它, 淡到全黑那一帧右上角会孤零零留一块彩色柱子。让它在转场期间
// 直通(等于不存在), 那块区域就跟着画面一起变暗, 视觉上干净。
wire vu_gate = vu_on_v2 & (fade_scale == 5'd16);

audio_vu u_audio_vu (
    .clk         (video_clk),
    .rst         (rst_all),
    .hs          (hs),
    .vs          (vs),
    .de          (de),
    .audio_valid (audio_valid),
    .audio_l     (audio_l_core),
    .audio_r     (audio_r_core),
    .enable      (vu_gate),
    .rgb_in      (vout_osd),
    .rgb_out     (vout_av)
);


// 应急画面(最上层): 平时直通, 应急时全屏覆盖(绿色安全出口标志)
emergency_mode u_emergency_mode (
    .clk    (video_clk),
    .rst    (rst_all),
    .hs     (hs),
    .vs     (vs),
    .de     (de),
    .emg_on (emg_state),
    .rgb_in (vout_av),
    .rgb_out(vout_data)
);

//--------------------- 三时钟域帧缓存 (写100M/读25M/SDRAM 100M) ---------------------
wire [ADDR_BITS-1:0]     App_rd_addr;
wire [ADDR_BITS-1:0]     App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0]               App_wr_dm;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_rd_en, App_wr_en, Sdr_rd_en;

frame_read_write #(
    .WRITE_V_FLIP (1),               // 垂直翻转抵消 BMP bottom-up
    .FRAME_WIDTH  (640),
    .FRAME_HEIGHT (480)
) u_frame_rw(
    .mem_clk          (ext_mem_clk),
    .rst              (rst_all),
    .Sdr_init_done    (Sdr_init_done),
    .Sdr_init_ref_vld (Sdr_init_ref_vld),
    .Sdr_busy         (Sdr_busy),
    .App_rd_en        (App_rd_en),
    .App_rd_addr      (App_rd_addr),
    .Sdr_rd_en        (Sdr_rd_en),
    .Sdr_rd_dout      (Sdr_rd_dout),

    .read_clk         (video_clk),
    .read_req         (video_read_req),
    .read_req_ack     (video_read_req_ack),
    .read_finish      (),
    .read_addr_0      (rd_base0),
    .read_addr_1      (rd_base1),
    .read_addr_2      (21'd0),
    .read_addr_3      (21'd0),
    .read_addr_index  (disp_idx_used),
    .read_len         (FRAME_PIXELS),
    .read_en          (video_read_en),
    .read_data        (video_read_data),
    .rd_seg_en        (rd_seg_en),
    .rd_seg_cnt       (rd_seg_cnt),
    .rd_seg_addr      (rd_seg_addr),
    .rd_wipe_en       (wipe_en_w),
    .rd_wipe_q        (wipe_q_w),
    .rd_wipe_x0       (wipe_x0_w),
    .rd_wipe_dx       (wipe_dx_w),
    .rd_wipe_dir      (wipe_dir_w),
    .rd_wipe_new_idx  (wipe_new_idx_w),
    .rd_wipe_full     (wipe_full_w),

    .App_wr_en        (App_wr_en),
    .App_wr_addr      (App_wr_addr),
    .App_wr_din       (App_wr_din),
    .App_wr_dm        (App_wr_dm),

    .write_clk        (sd_card_clk), // = 100MHz, 与 SD 卡时钟同域
    .write_req        (sd_card_write_req),
    .write_req_ack    (sd_card_write_req_ack),
    .write_finish     (frame_write_finish),
    .write_addr_0     (BUF0_ADDR),
    .write_addr_1     (BUF1_ADDR),
    .write_addr_2     (24'd0),
    .write_addr_3     (24'd0),
    .write_addr_index (write_buf_idx),
    .write_len        (FRAME_PIXELS),
    .write_en         (sd_card_write_en),
    .write_data       (sd_card_write_data)
);

//--------------------- SDRAM 硬核 ---------------------
wire        SDRAM_CLK;
wire        SDR_RAS, SDR_CAS, SDR_WE;
wire [1:0]  SDR_BA;
wire [10:0] SDR_ADDR;
wire [3:0]  SDR_DM;
wire [31:0] SDR_DQ;

sdr_as_ram #(.self_refresh_open(1'b1)) u_sdr_as_ram(
    .Sdr_clk          (ext_mem_clk),
    .Sdr_clk_sft      (ext_mem_clk_sft),
    .Rst              (rst_all),
    .Sdr_init_done    (Sdr_init_done),
    .Sdr_init_ref_vld (Sdr_init_ref_vld),
    .Sdr_busy         (Sdr_busy),
    .App_ref_req      (1'b0),
    .App_wr_en        (App_wr_en),
    .App_wr_addr      (App_wr_addr),
    .App_wr_dm        (App_wr_dm),
    .App_wr_din       (App_wr_din),
    .App_rd_en        (App_rd_en),
    .App_rd_addr      (App_rd_addr),
    .Sdr_rd_en        (Sdr_rd_en),
    .Sdr_rd_dout      (Sdr_rd_dout),
    .SDRAM_CLK        (SDRAM_CLK),
    .SDR_RAS          (SDR_RAS),
    .SDR_CAS          (SDR_CAS),
    .SDR_WE           (SDR_WE),
    .SDR_BA           (SDR_BA),
    .SDR_ADDR         (SDR_ADDR),
    .SDR_DM           (SDR_DM),
    .SDR_DQ           (SDR_DQ)
);

EG_PHY_SDRAM_2M_32 u_sdram_phy(
    .clk   (SDRAM_CLK),
    .ras_n (SDR_RAS),
    .cas_n (SDR_CAS),
    .we_n  (SDR_WE),
    .addr  (SDR_ADDR[10:0]),
    .ba    (SDR_BA),
    .dq    (SDR_DQ),
    .cs_n  (1'b0),
    .dm0   (SDR_DM[0]),
    .dm1   (SDR_DM[1]),
    .dm2   (SDR_DM[2]),
    .dm3   (SDR_DM[3]),
    .cke   (1'b1)
);

//--------------------- TF 卡 WAV 音频 -> 并行音频 + ACR ---------------------
wire        acr_valid;
wire [19:0] acr_cts;
wire [19:0] acr_n;

// 音频 FIFO 读侧 (video_clk 域): 精确 48kHz 采样率 + 16bit->24bit 扩展
// (wav_fifo_dout/empty/rdusedw/re、wav_found、wav_playing、sd_init_status 已在 u_sd_card_bmp 前声明)

// WAV 播放输出: display_valid(首图提交)后出声; FIFO 空补零静音但保持帧节奏(ACR 稳定)


wav_audio_out u_wav_audio_out(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .display_valid     (display_valid & ~emg_state),   // 应急时冻结, 退出后音乐续播
    .fifo_dout         (wav_fifo_dout),
    .fifo_empty        (wav_fifo_empty),
    .fifo_rdusedw      (wav_fifo_rdusedw),
    .wav_fifo_re       (wav_fifo_re),
    .audio_valid       (audio_valid),
    .audio_left_data   (audio_left_data),
    .audio_right_data  (audio_right_data)
);

// ACR: N=6144，CTS 按实际 video_clk 周期自动测量
audio_arc_calculate #(
    .ACR_N (6144)
) u_audio_arc_calculate (
    .I_clk         (video_clk),
    .I_rst         (rst_all),
    .I_audio_valid (audio_valid),
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

//--------------------- RGB/DE -> AXI4-Stream 视频 ---------------------
wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_all),
    .I_vs          (vs),
    .I_de          (de),
    .I_rgb         (vout_data),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

//--------------------- HDMI 1.4b 发射（官方加密核: 视频+音频数据岛） ---------------------
wire [9:0] tmds_ch0_data;
wire [9:0] tmds_ch1_data;
wire [9:0] tmds_ch2_data;
wire [9:0] tmds_clk_data;
wire       ddc_sda_unused;

hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE            ( "EG"       ),
    .HTOTAL            ( 800        ),
    .HSA               ( 96         ),
    .HFP               ( 16         ),
    .HBP               ( 48         ),
    .HACTIVE           ( 640        ),
    .VTOTAL            ( 525        ),
    .VSA               ( 2          ),
    .VFP               ( 10         ),
    .VBP               ( 33         ),
    .VACTIVE           ( 480        ),
    .VIDEO_VIC         ( 1          ),
    .VIDEO_TPG         ( "Disable"  ),
    .VIDEO_FORMAT      ( "RGB"      ),
    .AUDIO_SAMPLE_RATE ( "48K"      ),
    .IIC_SCL_DIV       ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_all),
    .I_edid_read_trig   (1'b0),              // 底板 HDMI 口无 DDC 引线(原理图 NC)，不读 EDID
    .O_edid_read_valid  (),
    .O_edid_read_data   (),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid),
    .I_audio_left_data  (audio_l_core),
    .I_audio_right_data (audio_r_core),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (),                  // 无 DDC 引线，不接
    .IO_ddc_sda         (ddc_sda_unused),    // 无 DDC 引线，悬空

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

//--------------------- HDMI PHY: 10bit 并行 -> 5x DDR -> TMDS 差分对 ---------------------
hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi_phy(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_all),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

//--------------------- 调试指示 ---------------------
assign led[0]   = display_valid;       // 图片已显示
assign led[1]   = Sdr_init_done;       // SDRAM 初始化完成
assign led[2]   = clk_pll_lock;        // SDRAM PLL 锁定
assign led[3]   = video_pll_lock;      // 视频 PLL 锁定
assign led[4]   = wav_found;           // WAV 已定位
assign led[5]   = wav_playing;         // WAV 播放中
assign led[6]   = sd_init_status;      // SD 卡初始化完成
assign led[7]   = state_code[0];       // SD 状态机最低位

// 数码管: 开机前 2 秒显示版本号 "34" (V34), 之后显示 state_code
//   版本号用于区分不同 bit 文件, 避免多版本混淆
reg [26:0] ver_cnt;       // 2s @50MHz = 100,000,000 周期, 需 27 位
reg        ver_show;      // 1=显示版本号, 0=显示 state_code
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ver_cnt  <= 27'd0;
        ver_show <= 1'b1;
    end else if (ver_show) begin
        if (ver_cnt >= 27'd100_000_000)  // 50MHz * 2s
            ver_show <= 1'b0;
        else
            ver_cnt  <= ver_cnt + 27'd1;
    end
end

wire [7:0] seg_code;
hex7seg u_hex7seg(.hex(state_code), .seg(seg_code));

// 版本号段码: 共阴段选高有效, 3=0x4F / 4=0x66  (V34 显示 "34")
localparam SEG_3 = 8'h4F;
localparam SEG_4 = 8'h66;

seg4_scan u_seg4(
    .clk     (clk),
    .rst_n   (rst_n),
    .disp3   (8'h00),
    .disp2   (8'h00),
    .disp1   (ver_show ? SEG_3 : 8'h00),
    .disp0   (ver_show ? SEG_4 : seg_code),
    .seg_sel (seg_sel),
    .seg_led (seg_led)
);

endmodule

//============================================================================
// 4bit 十六进制 -> 7 段码 (共阴, 段选高有效: seg[0]=a ... seg[6]=g, seg[7]=dp)
//============================================================================
module hex7seg(
    input      [3:0] hex,
    output reg [7:0] seg
);
always @* begin
    case (hex)
        4'h0: seg = 8'h3F;
        4'h1: seg = 8'h06;
        4'h2: seg = 8'h5B;
        4'h3: seg = 8'h4F;
        4'h4: seg = 8'h66;
        4'h5: seg = 8'h6D;
        4'h6: seg = 8'h7D;
        4'h7: seg = 8'h07;
        4'h8: seg = 8'h7F;
        4'h9: seg = 8'h6F;
        4'hA: seg = 8'h77;
        4'hB: seg = 8'h7C;
        4'hC: seg = 8'h39;
        4'hD: seg = 8'h5E;
        4'hE: seg = 8'h79;
        4'hF: seg = 8'h71;
        default: seg = 8'h00;
    endcase
end
endmodule