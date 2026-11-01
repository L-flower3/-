//============================================================================
// audio_vu.v — 音频可视化: 8 段倍频程频谱 (V33)
//
// ★ V33 变更: 从"音量电平表"升级为"真频谱"。
//
//   V32 及以前的做法(这个区别必须说清楚):
//     每 1024 个采样(约 21ms)记录一个峰值, 8 个峰值滚动移位成 8 根柱子。
//     那 8 根柱子其实是"最近 170ms 的音量时间轴", 跟频率没有任何关系 ——
//     放一段纯人声和放一段纯鼓, 8 根柱子的跳动方式一模一样。
//
//   V33 的做法:
//     8 段并联的 biquad 带通滤波器组, 中心频率按倍频程分布
//     (100 / 200 / 400 / 800 / 1600 / 3200 / 6400 / 11000 Hz),
//     每根柱子的高度 = 该频段的实时能量。贝斯只顶左边几根, 镲片只顶右边几根。
//
//   为什么用滤波器组而不是 FFT / Goertzel:
//     一开始试的是 Goertzel(它本质是 DFT 单频点的高效实现, 只算 8 个频点,
//     理论上比 64 点 FFT 还省)。但实测在这个频段范围下不可用:
//       · 最低频 100Hz 要求极点半径 0.9967, 谐振增益接近 N,
//         1024 点窗内 s 峰值冲到 470 万, 需要 24bit 状态 + 40bit 乘法,
//         单个频段就要 3 个 DSP, 8 段装不下;
//       · 想加阻尼把 Q 拉低, 判别式 c^2-4r 变正 -> 极点跑出单位圆, 直接发散
//         (实测峰值到 10^30 量级);
//       · Q16 定点下 c 约等于 2 的量化误差还会让极点在圆外缓慢漂移,
//         频谱毫无选择性。
//     biquad 的极点严格在圆内(0.776~0.997), 输出与输入同量级, 不存在溢出,
//     而且 25MHz 下 8 段串行只要 40 拍, 采样间隔有 520 拍, 时间非常宽裕。
//     这在声学里就是标准的倍频程(octave band)分析, 不是"取巧的近似"。
//
//   数据源: wav_audio_out 的 48kHz 立体声样本 (audio_valid / audio_l / audio_r)
//   时钟域: video_clk 25MHz (与音频输出/像素流同域, 无跨域问题)
//   显示  : 画面右上角, 位置/柱宽/配色/暗底与 V32 完全一致
//============================================================================
module audio_vu (
    input  wire        clk,          // video_clk 25MHz
    input  wire        rst,
    input  wire        hs,
    input  wire        vs,
    input  wire        de,

    input  wire        audio_valid,  // 48kHz 样本节拍
    input  wire [23:0] audio_l,      // 24bit 左声道 (16bit<<8)
    input  wire [23:0] audio_r,      // 24bit 右声道

    input  wire        enable,       // 0 = 关闭可视化(像素直通), 1 = 显示频谱

    input  wire [23:0] rgb_in,
    output wire [23:0] rgb_out
);

//==========================================================================
// 第一部分: 8 段带通滤波器组
//==========================================================================

//--------------------------------------------------------------------------
// 1.1 频段索引 (要在系数表之前声明)
//--------------------------------------------------------------------------
reg  [2:0] fk_sel;               // 当前处理的频段
reg  [2:0] ph;                   // 拍内相位

//--------------------------------------------------------------------------
// 1.2 单声道带符号取样
//
//   注意: V32 这里用的是 |L|+|R| 的绝对值 —— 那是电平表要的。
//   频谱必须拿到带符号的原始波形, 否则负半周被翻上来, 波形变成全波整流,
//   频谱会凭空多出一倍的直流和二倍频。
//   audio_l[23:8] 就是 16bit 有符号样本 (低 8 位是补零)。
//--------------------------------------------------------------------------
wire signed [15:0] s_l   = audio_l[23:8];
wire signed [15:0] s_r   = audio_r[23:8];
wire signed [16:0] s_sum = s_l + s_r;
wire signed [15:0] smp16 = s_sum >>> 1;      // 平均, 仍是 16bit 有符号
wire signed [7:0]  x_in  = smp16[15:8];      // 降到 8bit: 满幅 ±128

//--------------------------------------------------------------------------
// 1.3 直流扣除
//
//   滤波器本身对直流的稳态增益为 0(分子 1-z^-2 在 z=1 处为零), 但极点在
//   0.9967 附近, 一个直流阶跃会激起很长的瞬态 —— 实测峰值 21000,
//   折合柱高 45, 也就是"开始放歌的第一秒, 8 根柱子一起冲到顶再慢慢落"。
//   所以在入口先减掉慢速估计的直流。时间常数 1024 样本(约 21ms) 比最低
//   频段 100Hz 的周期(10ms) 长, 不会把真正的低频内容当直流减掉。
//
//   dcq 是 Q8 定点 (实际直流 = dcq/256)。必须带小数位, 否则第一步增量
//   127>>>8 = 0, 估计永远停在 0 —— 这个坑调试时踩过一次。
//--------------------------------------------------------------------------
wire signed [15:0] dc_tgt = {x_in, 8'b0};     // x_in * 256

reg signed [16:0] dcq;
always @(posedge clk or posedge rst) begin
    if (rst)              dcq <= 17'sd0;
    else if (audio_valid) dcq <= dcq + ((dc_tgt - dcq) >>> 10);
end

wire signed [7:0] u_sig = x_in - dcq[15:8];   // 去掉直流后的样本

// u 锁存: 串行 40 拍期间 dcq 不变, 但寄存一拍能让乘法器操作数路径更短
reg signed [7:0] u_r;
always @(posedge clk or posedge rst) begin
    if (rst) u_r <= 8'sd0;
    else     u_r <= u_sig;
end

// 一阶差分项 (u[n] - u[n-2]), 用 9bit 防止 127-(-128) 溢出 8bit
reg signed [7:0] rd_x2;
wire signed [8:0] u_diff = {u_r[7], u_r} - {rd_x2[7], rd_x2};

//--------------------------------------------------------------------------
// 1.4 8 段滤波器系数 (Q = 2, 中心频率按倍频程)
//
//   差分方程 (RBJ bandpass, 已除以 a0 归一化):
//     y[n] = b0*(u[n]-u[n-2]) + A1*y[n-1] + A2*y[n-2]
//
//   定点约定:
//     b0 用 Q24 —— 因为 b0 最小只有 0.0033, 用 Q14 会被量化到 53,
//                  再乘 8bit 输入后右移 14 位就直接归零, 滤波器只剩空转谐振。
//                  实测 Q14 版本完全没有频率选择性, 这是第二个坑。
//     A1/A2 用 Q14
//     y 用 Q10 (y_q = y*1024), 21bit 范围 ±1048575, 实测峰值只用到 ±65000
//
//   A1 = 2cos(w0)/(1+alpha),  A2 = -(1-alpha)/(1+alpha),  b0 = alpha/(1+alpha)
//--------------------------------------------------------------------------
reg signed [22:0] b0q;
reg signed [15:0] a1q, a2q;
always @(*) begin
    case (fk_sel)
    3'd0: begin b0q = 23'sd54723;   a1q = 16'sd32658; a2q = -16'sd16277; end //   100 Hz
    3'd1: begin b0q = 23'sd109080;  a1q = 16'sd32544; a2q = -16'sd16171; end //   200 Hz
    3'd2: begin b0q = 23'sd216678;  a1q = 16'sd32300; a2q = -16'sd15961; end //   400 Hz
    3'd3: begin b0q = 23'sd427259;  a1q = 16'sd31759; a2q = -16'sd15550; end //   800 Hz
    3'd4: begin b0q = 23'sd828957;  a1q = 16'sd30468; a2q = -16'sd14765; end //  1600 Hz
    3'd5: begin b0q = 23'sd1548517; a1q = 16'sd27172; a2q = -16'sd13360; end //  3200 Hz
    3'd6: begin b0q = 23'sd2628615; a1q = 16'sd18491; a2q = -16'sd11250; end //  6400 Hz
    default: begin b0q = 23'sd3332439; a1q = 16'sd3428; a2q = -16'sd9875; end // 11000 Hz
    endcase
end

//--------------------------------------------------------------------------
// 1.5 8 组滤波器状态 (展开写, 避免可变索引被综合成 RAM)
//--------------------------------------------------------------------------
reg signed [20:0] y1_0,y1_1,y1_2,y1_3,y1_4,y1_5,y1_6,y1_7;
reg signed [20:0] y2_0,y2_1,y2_2,y2_3,y2_4,y2_5,y2_6,y2_7;
reg signed [7:0]  x2_0,x2_1,x2_2,x2_3,x2_4,x2_5,x2_6,x2_7;
reg signed [13:0] er_0,er_1,er_2,er_3,er_4,er_5,er_6,er_7;

// 读 mux
reg signed [20:0] rd_y1, rd_y2;
reg signed [13:0] rd_er;
always @(*) begin
    case (fk_sel)
    3'd0: begin rd_y1=y1_0; rd_y2=y2_0; rd_x2=x2_0; rd_er=er_0; end
    3'd1: begin rd_y1=y1_1; rd_y2=y2_1; rd_x2=x2_1; rd_er=er_1; end
    3'd2: begin rd_y1=y1_2; rd_y2=y2_2; rd_x2=x2_2; rd_er=er_2; end
    3'd3: begin rd_y1=y1_3; rd_y2=y2_3; rd_x2=x2_3; rd_er=er_3; end
    3'd4: begin rd_y1=y1_4; rd_y2=y2_4; rd_x2=x2_4; rd_er=er_4; end
    3'd5: begin rd_y1=y1_5; rd_y2=y2_5; rd_x2=x2_5; rd_er=er_5; end
    3'd6: begin rd_y1=y1_6; rd_y2=y2_6; rd_x2=x2_6; rd_er=er_6; end
    default: begin rd_y1=y1_7; rd_y2=y2_7; rd_x2=x2_7; rd_er=er_7; end
    endcase
end

//--------------------------------------------------------------------------
// 1.6 串行运算状态机
//
//   每个采样要对 8 个频段各算一次, 每频段 5 拍:
//     PH_A1 : 乘法器取 A1*y1
//     PH_A2 : 取 A2*y2, 同时锁存第一种乘积
//     PH_B0 : 取 b0*(u-x2)
//     PH_P3 : 第三种乘积落一拍
//     PH_WB : 三项相加 + 误差反馈 + 写回状态
//   8*5 = 40 拍。48kHz 采样间隔是 520 拍, 只占 7.7%。
//
//   误差反馈(er): 把 acc>>>14 丢掉的低 14 位余数留到下一次迭代,
//   保证被移位舍掉的量不丢失。没有它的话定点 IIR 会进入极限环 ——
//   实测直流阶跃后 |y| 永久卡在 2719(柱高 21), 静音时 8 根柱子全部半高。
//   加上之后阶跃终值精确回到 0。
//--------------------------------------------------------------------------
localparam PH_A1 = 3'd0, PH_A2 = 3'd1, PH_B0 = 3'd2, PH_P3 = 3'd3, PH_WB = 3'd4;

reg        busy;

reg signed [23:0] m_a, m_b;     // 乘法器操作数
wire signed [47:0] prod = m_a * m_b;

reg signed [39:0] p1, p2, p3;
reg signed [20:0] yq_new;
reg signed [13:0] er_new;

reg  wr_en;
reg  [2:0] wr_k;

wire signed [39:0] acc_sum = p1 + p2 + p3 + {{26{rd_er[13]}}, rd_er};
wire signed [25:0] yq26    = acc_sum >>> 14;   // /16384 -> Q10 的 y

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wr_en <= 1'b0;
        wr_k  <= 3'd0;
    end else begin
        wr_en <= busy && (ph == PH_WB);
        wr_k  <= fk_sel;
    end
end

// 写回
always @(posedge clk or posedge rst) begin
    if (rst) begin
        y1_0<=0;y1_1<=0;y1_2<=0;y1_3<=0;y1_4<=0;y1_5<=0;y1_6<=0;y1_7<=0;
        y2_0<=0;y2_1<=0;y2_2<=0;y2_3<=0;y2_4<=0;y2_5<=0;y2_6<=0;y2_7<=0;
        x2_0<=0;x2_1<=0;x2_2<=0;x2_3<=0;x2_4<=0;x2_5<=0;x2_6<=0;x2_7<=0;
        er_0<=0;er_1<=0;er_2<=0;er_3<=0;er_4<=0;er_5<=0;er_6<=0;er_7<=0;
    end else if (wr_en) begin
        case (wr_k)
        3'd0: begin y2_0<=y1_0; y1_0<=yq_new; x2_0<=u_r; er_0<=er_new; end
        3'd1: begin y2_1<=y1_1; y1_1<=yq_new; x2_1<=u_r; er_1<=er_new; end
        3'd2: begin y2_2<=y1_2; y1_2<=yq_new; x2_2<=u_r; er_2<=er_new; end
        3'd3: begin y2_3<=y1_3; y1_3<=yq_new; x2_3<=u_r; er_3<=er_new; end
        3'd4: begin y2_4<=y1_4; y1_4<=yq_new; x2_4<=u_r; er_4<=er_new; end
        3'd5: begin y2_5<=y1_5; y1_5<=yq_new; x2_5<=u_r; er_5<=er_new; end
        3'd6: begin y2_6<=y1_6; y1_6<=yq_new; x2_6<=u_r; er_6<=er_new; end
        default: begin y2_7<=y1_7; y1_7<=yq_new; x2_7<=u_r; er_7<=er_new; end
        endcase
    end
end

// 主状态机
always @(posedge clk or posedge rst) begin
    if (rst) begin
        busy   <= 1'b0;
        fk_sel <= 3'd0;
        ph     <= PH_A1;
        m_a <= 24'sd0; m_b <= 24'sd0;
        p1  <= 40'sd0; p2 <= 40'sd0; p3 <= 40'sd0;
        yq_new <= 21'sd0;
        er_new <= 14'sd0;
    end else if (!busy) begin
        if (audio_valid) begin
            busy   <= 1'b1;
            fk_sel <= 3'd0;
            ph     <= PH_A1;
        end else begin
            // 空闲时把 yq_new 拉回稳定值, 保证 h_new 不随 fk_sel 抖动
            yq_new <= 21'sd0;
            er_new <= 14'sd0;
        end
    end else begin
        case (ph)
        PH_A1: begin
            m_a <= {{8{a1q[15]}}, a1q};                 // A1 符号扩展到 24bit
            m_b <= {{3{rd_y1[20]}}, rd_y1};             // y1 符号扩展到 24bit
            ph  <= PH_A2;
        end
        PH_A2: begin
            p1  <= prod[39:0];
            m_a <= {{8{a2q[15]}}, a2q};
            m_b <= {{3{rd_y2[20]}}, rd_y2};
            ph  <= PH_B0;
        end
        PH_B0: begin
            p2  <= prod[39:0];
            m_a <= {{1{b0q[22]}}, b0q};                 // b0 符号扩展到 24bit
            m_b <= {{15{u_diff[8]}}, u_diff};           // (u[n] - u[n-2])
            ph  <= PH_P3;
        end
        PH_P3: begin
            p3  <= prod[39:0];
            ph  <= PH_WB;
        end
        default: begin  // PH_WB
            if (yq26 > 40'sd1048575) begin
                yq_new <= 21'sd1048575;                 // 上限饱和
                er_new <= 14'sd0;
            end else if (yq26 < -40'sd1048576) begin
                yq_new <= -21'sd1048576;                // 下限饱和
                er_new <= 14'sd0;
            end else begin
                yq_new <= yq26[20:0];
                // 误差反馈: acc - (yq26<<14) 的低 14 位就等于 acc 的低 14 位
                er_new <= acc_sum[13:0];
            end
            if (fk_sel == 3'd7) begin
                busy <= 1'b0;                           // 8 段算完, 等下一个采样
            end else begin
                fk_sel <= fk_sel + 3'd1;
                ph     <= PH_A1;
            end
        end
        endcase
    end
end

//--------------------------------------------------------------------------
// 1.7 柱高: |y| 的对数刻度 (近似 log2)
//
//   线性刻度下音乐的高频段能量比低频低 20~30dB, 右半边柱子几乎看不见。
//   用 log2 刻度后 8 根柱子的动态范围一致, 和商用频谱仪观感相同。
//
//   映射: |y| < 512 视为噪声门 -> 0
//         否则 h = (msb-9)*8 + msb 下面 3bit   (每 2 倍频程 8 级)
//         实测满幅单音在对应频段得到 55~61, 相邻频段约一半(差 8 级)。
//--------------------------------------------------------------------------
function [5:0] h_of;
    input signed [20:0] y;
    reg [20:0] a;
    reg [4:0]  m;
    reg [2:0]  tl;
    begin
        a = y[20] ? (~y + 21'd1) : y;            // 绝对值
        if (a < 21'd512) begin
            h_of = 6'd0;                         // 噪声门
        end else begin
            if      (a[20]) m = 5'd20;
            else if (a[19]) m = 5'd19;
            else if (a[18]) m = 5'd18;
            else if (a[17]) m = 5'd17;
            else if (a[16]) m = 5'd16;
            else if (a[15]) m = 5'd15;
            else if (a[14]) m = 5'd14;
            else if (a[13]) m = 5'd13;
            else if (a[12]) m = 5'd12;
            else if (a[11]) m = 5'd11;
            else if (a[10]) m = 5'd10;
            else            m = 5'd9;
            case (m)
            5'd20: tl = a[19:17];
            5'd19: tl = a[18:16];
            5'd18: tl = a[17:15];
            5'd17: tl = a[16:14];
            5'd16: tl = a[15:13];
            5'd15: tl = a[14:12];
            5'd14: tl = a[13:11];
            5'd13: tl = a[12:10];
            5'd12: tl = a[11:9];
            5'd11: tl = a[10:8];
            5'd10: tl = a[9:7];
            default: tl = a[8:6];
            endcase
            if (m > 5'd16) h_of = 6'd63;                       // 饱和
            else           h_of = ((m - 5'd9) << 3) + {3'b0, tl};
        end
    end
endfunction

wire [5:0] h_new = h_of(yq_new);

reg [5:0] h_raw_0,h_raw_1,h_raw_2,h_raw_3,h_raw_4,h_raw_5,h_raw_6,h_raw_7;
reg [5:0] h_dsp_0,h_dsp_1,h_dsp_2,h_dsp_3,h_dsp_4,h_dsp_5,h_dsp_6,h_dsp_7;

// 每个频段算完时更新原始值
always @(posedge clk or posedge rst) begin
    if (rst) begin
        h_raw_0<=0;h_raw_1<=0;h_raw_2<=0;h_raw_3<=0;
        h_raw_4<=0;h_raw_5<=0;h_raw_6<=0;h_raw_7<=0;
    end else if (wr_en) begin
        case (wr_k)
        3'd0: h_raw_0 <= h_new;
        3'd1: h_raw_1 <= h_new;
        3'd2: h_raw_2 <= h_new;
        3'd3: h_raw_3 <= h_new;
        3'd4: h_raw_4 <= h_new;
        3'd5: h_raw_5 <= h_new;
        3'd6: h_raw_6 <= h_new;
        default: h_raw_7 <= h_new;
        endcase
    end
end

// 8 段全部更新完 = 一帧频谱边界
//   注意要延后一拍: h_dsp 依赖 h_raw, 而 h_raw_7 正是在 wr_en 那一拍才写入,
//   直接同拍用会拿到上一帧的第 8 根旧值。
reg fe_d;
always @(posedge clk or posedge rst) begin
    if (rst) fe_d <= 1'b0;
    else     fe_d <= wr_en && (wr_k == 3'd7);
end
wire frame_end = fe_d;

// 上升跟手, 下降每帧减 3 (约 0.45 秒落到底), 避免闪成频闪灯
always @(posedge clk or posedge rst) begin
    if (rst) begin
        h_dsp_0<=0;h_dsp_1<=0;h_dsp_2<=0;h_dsp_3<=0;
        h_dsp_4<=0;h_dsp_5<=0;h_dsp_6<=0;h_dsp_7<=0;
    end else if (frame_end) begin
        if (h_raw_0 >= h_dsp_0) h_dsp_0 <= h_raw_0; else if (h_dsp_0 > 6'd3) h_dsp_0 <= h_dsp_0 - 6'd3; else h_dsp_0 <= 6'd0;
        if (h_raw_1 >= h_dsp_1) h_dsp_1 <= h_raw_1; else if (h_dsp_1 > 6'd3) h_dsp_1 <= h_dsp_1 - 6'd3; else h_dsp_1 <= 6'd0;
        if (h_raw_2 >= h_dsp_2) h_dsp_2 <= h_raw_2; else if (h_dsp_2 > 6'd3) h_dsp_2 <= h_dsp_2 - 6'd3; else h_dsp_2 <= 6'd0;
        if (h_raw_3 >= h_dsp_3) h_dsp_3 <= h_raw_3; else if (h_dsp_3 > 6'd3) h_dsp_3 <= h_dsp_3 - 6'd3; else h_dsp_3 <= 6'd0;
        if (h_raw_4 >= h_dsp_4) h_dsp_4 <= h_raw_4; else if (h_dsp_4 > 6'd3) h_dsp_4 <= h_dsp_4 - 6'd3; else h_dsp_4 <= 6'd0;
        if (h_raw_5 >= h_dsp_5) h_dsp_5 <= h_raw_5; else if (h_dsp_5 > 6'd3) h_dsp_5 <= h_dsp_5 - 6'd3; else h_dsp_5 <= 6'd0;
        if (h_raw_6 >= h_dsp_6) h_dsp_6 <= h_raw_6; else if (h_dsp_6 > 6'd3) h_dsp_6 <= h_dsp_6 - 6'd3; else h_dsp_6 <= 6'd0;
        if (h_raw_7 >= h_dsp_7) h_dsp_7 <= h_raw_7; else if (h_dsp_7 > 6'd3) h_dsp_7 <= h_dsp_7 - 6'd3; else h_dsp_7 <= 6'd0;
    end
end

//==========================================================================
// 第二部分: 显示 (与 V32 逐行一致, 只换数据源)
//==========================================================================

//--------------------------------------------------------------------------
// 显示区域 (画面右上角) —— 与 V32 保持一致, 一个像素都没挪
//--------------------------------------------------------------------------
localparam [9:0] X0      = 10'd512;   // 区域左边界
localparam [9:0] YB      = 10'd112;   // 柱底(向下递增)
localparam [9:0] BAR_W   = 10'd12;    // 柱宽
localparam [9:0] BAR_PIT = 10'd15;    // 柱间距(含柱宽)
localparam [9:0] BAR_MAX = 10'd63;    // 最大柱高
localparam [9:0] X1      = X0 + BAR_PIT*8;          // 区域右边界 632

//--------------------------------------------------------------------------
// 像素坐标 (与 de 同相)
//--------------------------------------------------------------------------
reg  de_d, vs_d;
wire de_rise = de & ~de_d;
wire de_fall = ~de & de_d;
wire vs_rise = vs & ~vs_d;

reg [9:0] px, py;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        de_d <= 1'b0; vs_d <= 1'b0;
        px <= 10'd0;  py <= 10'd0;
    end else begin
        de_d <= de;  vs_d <= vs;
        if (vs_rise)       py <= 10'd0;
        else if (de_fall)  py <= (py == 10'd479) ? 10'd0 : py + 10'd1;
        if (de_rise)       px <= 10'd0;
        else if (de)       px <= px + 10'd1;
    end
end

// 柱索引与柱高 (rel = px - X0)
wire in_x   = (px >= X0) && (px < X1);
wire [9:0] rel = px - X0;

reg [2:0] bidx;
always @(*) begin
    if      (rel < 10'd15)  bidx = 3'd0;
    else if (rel < 10'd30)  bidx = 3'd1;
    else if (rel < 10'd45)  bidx = 3'd2;
    else if (rel < 10'd60)  bidx = 3'd3;
    else if (rel < 10'd75)  bidx = 3'd4;
    else if (rel < 10'd90)  bidx = 3'd5;
    else if (rel < 10'd105) bidx = 3'd6;
    else                    bidx = 3'd7;
end

// 柱体宽度内 (每 15px 中前 12px 亮)
wire [9:0] bar_base = {7'b0, bidx} * 10'd15;      // 0,15,...,105 (小常数乘)
wire [9:0] rel_mod  = rel - bar_base;
wire       col_on   = in_x && (rel_mod < BAR_W);

// 该柱高度 = 对应频段的平滑值
reg [5:0] bar_h;
always @(*) begin
    case (bidx)
    3'd0: bar_h = h_dsp_0;
    3'd1: bar_h = h_dsp_1;
    3'd2: bar_h = h_dsp_2;
    3'd3: bar_h = h_dsp_3;
    3'd4: bar_h = h_dsp_4;
    3'd5: bar_h = h_dsp_5;
    3'd6: bar_h = h_dsp_6;
    default: bar_h = h_dsp_7;
    endcase
end

// 柱体像素: y ∈ (YB-bar_h, YB]
wire bar_on = col_on && (py <= YB) && ((py + {4'b0, bar_h}) > YB);

//--------------------------------------------------------------------------
// 颜色: 高度分级 绿(低) / 黄(中) / 红(高)
//--------------------------------------------------------------------------
wire [23:0] bar_color = (py < (YB - 10'd42)) ? 24'hFF3020 :   // 高段 红
                        (py < (YB - 10'd21)) ? 24'hFFD000 :   // 中段 黄
                                               24'h30E030;    // 低段 绿

//--------------------------------------------------------------------------
// 半透明暗底 (提升浅色图片上的可读性)
//--------------------------------------------------------------------------
wire in_bg = (px >= (X0 - 10'd8)) && (px < (X1 + 10'd4)) &&
             (py >= (YB - BAR_MAX - 10'd4)) && (py <= (YB + 10'd4));
wire [23:0] dark = { {1'b0, rgb_in[23:17]},
                     {1'b0, rgb_in[15:9]},
                     {1'b0, rgb_in[7:1]} };

// enable=0 时完全直通(连暗底都不画), 等效于这块可视化不存在
assign rgb_out = (!de || !enable) ? rgb_in :
                 bar_on     ? bar_color :
                 in_bg      ? dark :
                              rgb_in;

endmodule
