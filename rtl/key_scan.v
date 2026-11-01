//============================================================================
// key_scan.v — 4x4 矩阵键盘分时扫描 + 消抖 + 按键功能映射
//
// 硬件（EG4S20BG256 核心板原理图 IO.SchDoc）:
//     Key_Row0 = E10    Key_Row1 = C10
//     Key_Col0 = E11    Key_Col1 = D11    Key_Col2 = C11    Key_Col3 = F10
//   矩阵: Row0 x Col0..3 = KEY0..KEY3 (底行左起)
//         Row1 x Col0..3 = KEY4..KEY7 (上一行左起)
//
// 时序: 1kHz 双相位切换 (50MHz/50000)
//   相位A (row0=0, row1=1): 采样 Col0..Col3 -> KEY0..KEY3
//   相位B (row0=1, row1=0): 采样 Col0..Col3 -> KEY4..KEY7
//   采样点取相位内 0.8ms 处(计数 40000, 信号已稳定);
//   非采样相位保持锁存值 -> 下游看到连续稳定电平, 不受分时影响。
//
// 功能分配 (V32):
//   KEY0 = 上一张 (由 top.v 取下降沿)      KEY1 = 下一张
//   KEY2 = 自动轮播 开/关                  (以上三个由 top.v 消抖处理)
//   KEY3 = 当前参数 -                      KEY4 = 当前参数 +
//          当前参数 = 亮度 或 对比度, 由 KEY6 长按切换
//   KEY5 = 应急模式 开/关
//   KEY6 = 短按: 音频可视化 开/关   长按 800ms: 切换「亮度↔对比度」调节模式
//   KEY7 = 切换转场方式 (滑动 ↔ 淡入淡出)
//
// 本模块负责 KEY3/KEY4/KEY5/KEY6/KEY7 的消抖与语义处理:
//   参数调节: 20ms 消抖, 单次按下 25% 一档, 按住 200ms 后连续步进
//   应急:     20ms 消抖, 每次按下(下降沿)翻转一次
//   VU/模式:  20ms 消抖, 松手且不足 800ms 算短按(VU), 满 800ms 算长按(切模式)
//   转场方式: 20ms 消抖, 每次按下(下降沿)翻转一次
//============================================================================
module key_scan (
    input  wire clk,          // 50MHz
    input  wire rst,          // 高有效

    input  wire col0,         // E11 (KEY0 / KEY4)
    input  wire col1,         // D11 (KEY1 / KEY5)
    input  wire col2,         // C11 (KEY2 / KEY6)
    input  wire col3,         // F10 (KEY3 / KEY7)

    output wire row0,         // E10 : 相位A 拉低
    output wire row1,         // C10 : 相位B 拉低

    output reg  key0_l,       // 锁存后给切图逻辑 (按下=0)
    output reg  key1_l,
    output reg  key2_l,
    output reg  key3_l,       // KEY3 当前参数-

    output reg  emg_state,    // KEY5 应急模式状态 (0=正常 1=应急)

    output reg [9:0] bright,  // 画面亮度增益 (256 = 100%)
    output reg       bri_show,// 亮度 OSD 显示使能(调节后保持2秒)

    output reg [9:0] contrast,// 画面对比度增益 (256 = 100%, 128..512 即 50%..200%)
    output reg       con_mode,// 0 = KEY3/4 调亮度, 1 = 调对比度 (KEY6 长按切换)

    output reg       vu_on,   // KEY6 短按: 音频可视化开关 (1=显示右上角 VU 表)

    output reg [1:0] trans_mode // KEY7: 0=滑动 1=淡入淡出 2=旋转擦除 (V34 三态循环)
);

//--------------------------------------------------------------------------
// 1kHz 相位切换: 50MHz / 50000 = 1kHz
//--------------------------------------------------------------------------
reg [15:0] cnt;
reg        phase;              // 0 = 相位A(Row0), 1 = 相位B(Row1)

always @(posedge clk or posedge rst) begin
    if (rst) begin
        cnt   <= 16'd0;
        phase <= 1'b0;
    end else if (cnt >= 16'd49999) begin
        cnt   <= 16'd0;
        phase <= ~phase;
    end else begin
        cnt <= cnt + 16'd1;
    end
end

assign row0 = phase ? 1'b1 : 1'b0;    // 相位A: Row0 低
assign row1 = phase ? 1'b0 : 1'b1;    // 相位B: Row1 低

//--------------------------------------------------------------------------
// 采样锁存 (相位内 0.8ms 处)
//--------------------------------------------------------------------------
reg key4_l, key5_l, key6_l, key7_l;    // 相位B 锁存 (Row1 行)

always @(posedge clk or posedge rst) begin
    if (rst) begin
        key0_l <= 1'b1;
        key1_l <= 1'b1;
        key2_l <= 1'b1;
        key3_l <= 1'b1;
        key4_l <= 1'b1;
        key5_l <= 1'b1;
        key6_l <= 1'b1;
        key7_l <= 1'b1;
    end else if (cnt == 16'd40000) begin
        if (!phase) begin                 // 相位A: Row0 选中 -> KEY0..KEY3
            key0_l <= col0;
            key1_l <= col1;
            key2_l <= col2;
            key3_l <= col3;
        end else begin                    // 相位B: Row1 选中 -> KEY4..KEY7
            key4_l <= col0;
            key5_l <= col1;
            key6_l <= col2;
            key7_l <= col3;
        end
    end
end

//--------------------------------------------------------------------------
// 10bit 节拍分频: 50MHz / 1024 = 48.83kHz (20.48us 一拍)
//   消抖/连发/OSD 计时都改用这个节拍做使能,
//   原来是 4 个 20bit 计数器 + 20bit 比较器 (80 reg + 4x20 LUT),
//   现在只需 4 个 10bit 计数器 (40 reg) —— 省寄存器也省 LUT, 减轻布线拥塞
//--------------------------------------------------------------------------
localparam [9:0] TICK_DIV = 10'd1023;
reg [9:0] tick_cnt;
wire      tick = (tick_cnt == TICK_DIV);

always @(posedge clk or posedge rst) begin
    if (rst)          tick_cnt <= 10'd0;
    else if (tick)    tick_cnt <= 10'd0;
    else              tick_cnt <= tick_cnt + 10'd1;
end

// 节拍数换算: 20ms/20.48us=976.6 -> 977 ; 200ms -> 9766 ; 2s -> 97656
localparam [9:0]  DEB_TICKS  = 10'd976;
localparam [13:0] RP_TICKS   = 14'd9765;
localparam [16:0] SHOW_TICKS = 17'd97656;

//--------------------------------------------------------------------------
// 消抖 (约 20ms), 四个键各一份, 由 tick 使能
//--------------------------------------------------------------------------
reg        k3_st, k4_st, k5_st, k6_st, k7_st;
reg [9:0]  db3, db4, db5, db6, db7;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        k3_st <= 1'b1; k4_st <= 1'b1; k5_st <= 1'b1; k6_st <= 1'b1; k7_st <= 1'b1;
        db3   <= 10'd0; db4 <= 10'd0; db5 <= 10'd0; db6 <= 10'd0; db7 <= 10'd0;
    end else if (tick) begin
        if (key3_l != k3_st) begin
            if (db3 >= DEB_TICKS) begin db3 <= 10'd0; k3_st <= key3_l; end
            else db3 <= db3 + 10'd1;
        end else db3 <= 10'd0;

        if (key4_l != k4_st) begin
            if (db4 >= DEB_TICKS) begin db4 <= 10'd0; k4_st <= key4_l; end
            else db4 <= db4 + 10'd1;
        end else db4 <= 10'd0;

        if (key5_l != k5_st) begin
            if (db5 >= DEB_TICKS) begin db5 <= 10'd0; k5_st <= key5_l; end
            else db5 <= db5 + 10'd1;
        end else db5 <= 10'd0;

        if (key6_l != k6_st) begin
            if (db6 >= DEB_TICKS) begin db6 <= 10'd0; k6_st <= key6_l; end
            else db6 <= db6 + 10'd1;
        end else db6 <= 10'd0;

        if (key7_l != k7_st) begin
            if (db7 >= DEB_TICKS) begin db7 <= 10'd0; k7_st <= key7_l; end
            else db7 <= db7 + 10'd1;
        end else db7 <= 10'd0;
    end
end

//--------------------------------------------------------------------------
// 下降沿单拍脉冲 (消抖后电平再取边沿, 保证一次按键只触发一次)
//--------------------------------------------------------------------------
reg k5_st_d, k7_st_d;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        k5_st_d <= 1'b1;
        k7_st_d <= 1'b1;
    end else begin
        k5_st_d <= k5_st;
        k7_st_d <= k7_st;
    end
end
wire k5_press = k5_st_d & ~k5_st;     // KEY5 按下(下降沿) -> 应急 切换
wire k7_press = k7_st_d & ~k7_st;     // KEY7 按下(下降沿) -> 转场方式 切换

//--------------------------------------------------------------------------
// KEY5 应急模式 toggle
//--------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)             emg_state <= 1'b0;
    else if (k5_press)   emg_state <= ~emg_state;
end

//--------------------------------------------------------------------------
// KEY7 转场方式循环: 滑动 -> 淡入淡出 -> 旋转擦除 -> 滑动 (V34)
//--------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)             trans_mode <= 2'd0;
    else if (k7_press)   trans_mode <= (trans_mode == 2'd2) ? 2'd0 : (trans_mode + 2'd1);
end

//--------------------------------------------------------------------------
// KEY6 双功能: 短按 = 音频可视化开关 / 长按 800ms = 切换「亮度↔对比度」调节模式
//
//   为什么短按要等到松手才生效:
//     若按下即翻转 VU, 那么长按时 VU 会被顺带翻一次, 用户会看到"切个模式把
//     VU 表关了"。所以改成松手判定——按住不足 800ms 才当短按。
//     正常点按 100~200ms 就松手, 松手瞬间生效, 手感上察觉不到延迟。
//   长按到 800ms 立即触发一次模式切换, 由 lp6_fired 锁死, 继续按住不会重复触发;
//   松手时 lp6_fired=1 则不再产生短按动作。
//--------------------------------------------------------------------------
localparam [15:0] LP_TICKS = 16'd39062;   // 800ms / 20.48us

reg [15:0] lp6;
reg        lp6_fired;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        lp6       <= 16'd0;
        lp6_fired <= 1'b0;
        vu_on     <= 1'b1;                // 上电默认开启 VU
        con_mode  <= 1'b0;                // 上电默认调亮度
    end else if (tick) begin
        if (!k6_st) begin                 // 按住
            if (!lp6_fired) begin
                if (lp6 >= LP_TICKS) begin
                    lp6_fired <= 1'b1;
                    con_mode  <= ~con_mode;   // 长按 -> 切换调节模式
                end else begin
                    lp6 <= lp6 + 16'd1;
                end
            end
        end else begin                    // 松手
            if (!lp6_fired && (lp6 != 16'd0)) begin
                vu_on <= ~vu_on;          // 短按 -> VU 开关
            end
            lp6       <= 16'd0;
            lp6_fired <= 1'b0;
        end
    end
end

//--------------------------------------------------------------------------
// 画面参数调节: KEY3(-) / KEY4(+), 按 con_mode 决定调亮度还是对比度
//   每步 25%, 按住 200ms 后连续步进; 调节后 bri_show 保持 2 秒
//   亮度    64..512 (25%..200%)   对比度 128..512 (50%..200%)
//   两者都用 256 = 100% 的增益表述, 所以 OSD 百分比算法可以共用
//--------------------------------------------------------------------------
localparam [9:0] BRI_MIN  = 10'd64;    // 亮度下限 25%
localparam [9:0] BRI_MAX  = 10'd512;   // 亮度上限 200%
localparam [9:0] CON_MIN  = 10'd128;   // 对比度下限 50%
localparam [9:0] CON_MAX  = 10'd512;   // 对比度上限 200%
localparam [9:0] ADJ_STEP = 10'd64;    // 每档 25%

reg [13:0] rp3, rp4;          // 长按重复计数 (200ms = 9766 个 tick)
reg [16:0] show_cnt;          // OSD 显示计时 (2s = 97656 个 tick)

wire k3_press = ~k3_st;       // 按住(低有效)
wire k4_press = ~k4_st;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bright    <= 10'd256;
        contrast  <= 10'd256;
        bri_show  <= 1'b0;
        rp3 <= 14'd0; rp4 <= 14'd0;
        show_cnt  <= 17'd0;
    end else if (tick) begin
        // ---- KEY3 (当前参数 -) ----
        if (k3_press) begin
            if (rp3 == 14'd0) begin
                rp3 <= 14'd1;
                if (con_mode) begin
                    if (contrast > CON_MIN + ADJ_STEP) contrast <= contrast - ADJ_STEP;
                    else                               contrast <= CON_MIN;
                end else begin
                    if (bright > BRI_MIN + ADJ_STEP)   bright <= bright - ADJ_STEP;
                    else                               bright <= BRI_MIN;
                end
                bri_show <= 1'b1;
                show_cnt <= 17'd0;
            end else if (rp3 >= RP_TICKS) begin      // 200ms 到 -> 下一个 tick 再走一档
                rp3 <= 14'd0;
            end else begin
                rp3 <= rp3 + 14'd1;
            end
        end else rp3 <= 14'd0;

        // ---- KEY4 (当前参数 +) ----
        if (k4_press) begin
            if (rp4 == 14'd0) begin
                rp4 <= 14'd1;
                if (con_mode) begin
                    if (contrast < CON_MAX - ADJ_STEP) contrast <= contrast + ADJ_STEP;
                    else                               contrast <= CON_MAX;
                end else begin
                    if (bright < BRI_MAX - ADJ_STEP)   bright <= bright + ADJ_STEP;
                    else                               bright <= BRI_MAX;
                end
                bri_show <= 1'b1;
                show_cnt <= 17'd0;
            end else if (rp4 >= RP_TICKS) begin
                rp4 <= 14'd0;
            end else begin
                rp4 <= rp4 + 14'd1;
            end
        end else rp4 <= 14'd0;

        // ---- OSD 显示保持 2 秒 ----
        if (bri_show) begin
            if (show_cnt >= SHOW_TICKS) bri_show <= 1'b0;
            else                        show_cnt <= show_cnt + 17'd1;
        end
    end
end

endmodule
