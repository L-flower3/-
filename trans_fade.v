//============================================================================
// trans_fade.v — 切图转场: 滑动 / 淡入淡出 / 旋转擦除 三模式 (V34)
//
// 效果:
//   KEY1「下一张」-> 画面整体向下移动, 新图从顶部推入 (dir=1)
//   KEY0「上一张」-> 画面整体向上移动, 新图从底部推入 (dir=0)
//   KEY7          -> 循环切换: 滑动 -> 淡入淡出 -> 旋转擦除 -> 滑动
//
//----------------------------------------------------------------------------
// V34: 增加「旋转擦除」模式 (mode=2)
//
//   一条边界半径绕屏幕中心匀速旋转 360°, 扫过的扇形区域直接显示新图,
//   没扫到的部分保持旧图 —— 观感是"新图被一条转动的分界线擦进来"。
//   方向跟随按键: KEY1(下一张)=顺时针, KEY0(上一张)=逆时针。
//
//   ★ 为什么不做真正的"整幅图像旋转"(几何旋转) ★
//     那需要二维重采样: 输出像素 (x,y) 要取源图 R(θ)·(x,y) 处的值, 读地址
//     在行内是跳跃的, 而本工程 SDRAM 是单条顺序读流(突发式), 一帧只允许一次
//     地址跳转。要做真旋转必须再加一整套随机读通道 + 行缓存 + 后备帧缓存,
//     而本设计只剩 0.18ns 时序余量, 风险不可接受。
//     旋转擦除同样满足"旋转"的视觉语义, 且一个像素周期只读一个地址。
//
//   ★ 为什么参数只有 (起点, 每行增量) 两个数 ★
//     扇形 { 0 <= 角度 < S } 与任意一行的交集都是一段连续区间, 端点 x 随行号
//     线性变化(斜率 = tan 或 cot), 所以整帧边界只由"第 0 行边界 x0"和
//     "每行增量 dx"决定, 读取侧逐行累加即可, 不需要除法、查找表或乘法。
//     象限与角度关系(角度自 12 点方向顺时针量):
//        q0  0..90    上半屏 [320, xb), 下半屏空          xb = 320+(240-y)*tan(a)
//        q1  90..180  上半屏 [320,639], 下半屏 [xb,639)   xb = 320+(y-240)*cot(a)
//        q2  180..270 上半屏 [320,639], 下半屏 [xb,639)   xb = 320-(y-240)*tan(a)
//        q3  270..360 下半屏全满, 上半屏 [0,xb)U[320,639) xb = 320-(240-y)*cot(a)
//     本模块只把 tan/cot 查表 + 起点换算出来, 像素通路零改动。
//
//   时长: 4 象限 x 12 帧 = 48 帧 ≈ 800ms, 每帧转 7.5°。
//   最后一帧强制"整屏新图"(wipe_full), 因为 tan 在 82.5° 之后会饱和,
//   否则最后一帧会留一个扫不到的小楔形。
//
//----------------------------------------------------------------------------
// V32: 增加「淡入淡出」模式 (mode=1)
//
//   ★ 为什么不用真正的叠化 (cross-dissolve) ★
//     叠化需要同一个像素位置上「新图」和「旧图」同时在场, 即一像素周期内读两次
//     SDRAM。本工程 SDRAM 只有单读口(FIFO 单出口), 帧缓存读是"自由跑填 FIFO"
//     的顺序流, 要并行读两条地址流就得再加一整套 frame_fifo_read + FIFO + 仲裁,
//     带宽翻倍、架构大改, 而当前只剩 0.18ns 时序余量, 风险不可接受。
//     所以采用电影/电视里同样标准的「淡出到黑 -> 换图 -> 淡入」(fade-out/fade-in):
//     只需一个数据源, 切换动作发生在全黑帧里, 用户看到的是"暗下去 / 亮起来"。
//
//   ★ 淡变怎么做到几乎不花资源 ★
//     像素乘法放在 bright_ctrl.v 里 —— 那里已经有一条
//         out = rgb * k/256 + offset      (k = 亮度×对比度/256)
//     的慢速预计算通路。淡变只是把 k 和 offset 再乘一个 0/16..16/16 的系数:
//         k' = k * fade / 8 ,  offset' = offset * fade / 8
//     系数每帧才变一次, 于是像素通路上「一个乘法器都不用加」。
//     本模块只负责产出 fade_scale(0..16), 不碰像素: rgb_out = rgb_in 仍然直通。
//
//   渐变档位: 直接用 5bit 计数器 fc 当增益, 0..16 共 17 档, 每档 1 帧。
//             淡出 16 帧 + 淡入 16 帧 = 32 帧 ≈ 534ms (单帧 16.68ms)。
//             ★ 一开始做过 9 档(每档停 2 帧) 的版本, 每档跨 12.5% 亮度, 淡变过程中
//               能看出亮度一级一级地跳; 改成 17 档(每档 6.25%) 后是连续渐变。
//               17 档同时把黑场压到只有 1 帧(16.7ms), 换图那一刻人眼抓不到。
//             时长选 534ms: 250ms 左右的淡变肉眼看接近"闪一下", 1 秒以上又显拖沓;
//             500ms 上下是广播里最常见的淡变时长。
//
//   状态流转:
//     S_IDLE --(有新图 & mode=1)--> S_FADE_OUT (fc=15)
//     S_FADE_OUT: fc 每帧 -1, 到 0 时整屏已全黑
//     S_FADE_IN : 在 fc==0 那一刻把 idx_r 切成新图, fc 每帧 +1, 到 16 回 S_IDLE
//
//----------------------------------------------------------------------------
// V30 相对 V28 的改动 —— 只改「每帧走多少行」, 不动整体架构
//
//   V28: 固定 40 行/帧, 480/40 = 12 帧, 约 200ms 走完
//        每步跳 480 行的 8.3%, 折合 2.9 屏/秒。这个速度下每帧位移量远大于
//        人眼能接受的运动连贯阈值(约 2%~3% 屏高), 主观感受是"跳了几下过去",
//        也就是"卡"。
//
//   V30: 改为 10 行/帧, 480/10 = 48 帧, 约 800ms 走完
//        每步 10 行 = 屏高 2.1%, 落进运动连贯阈值(2%~3%)以内,
//        看起来是连续滚动而不是"跳几下"。480 能被 10 整除, 末步精确落位。
//
//   为什么不加"先快后慢"的缓动:
//     试过 16 行/帧 + 末段 8 行/帧 两档速度, 两档阶跃 = 加速度突变, 切换点会
//     "撞一下", 未必比匀速自然; 真正平滑的 ease-out 要 4~6 档渐变(60~80 LUT),
//     对这块只剩零点几 ns 余量的板子是纯风险。匀速没有加速度突变, 最稳。
//
//   ★ 实测坑位 (改 STEP_ROWS 前必读) ★
//     TD5.6.2 对步长常量的微小差异极其敏感 —— 同一个逻辑只换常量值,
//     综合出的网表和布局解就完全不同, SWNS 在 0.11~0.47ns 之间乱跳:
//         STEP_ROWS=40 -> 3981 slices, SWNS 0.471ns
//         STEP_ROWS=16 -> 4020 slices, SWNS 0.110ns
//         STEP_ROWS=12 -> 4047 slices, SWNS 0.117ns
//         STEP_ROWS=10 -> 4020 slices, SWNS 0.204ns  <-- 本版采用
//     所以调这个参数不能只算数学, 每改一次都必须重编译看 route.qor 的
//     Setup WNS; 低于 0.15ns 在板子上就有偶发不稳的风险。
//
//   其它可选档位 (都取 480 的约数, 否则末步要补差, 会出现不均匀的"尾巴"):
//     8 行/帧  -> 60 帧 / 1000ms  极顺但偏慢
//    10 行/帧  -> 48 帧 /  800ms  默认(已验时序)
//    16 行/帧  -> 30 帧 /  500ms  利落, 阶梯略可见, 但实测 SWNS 仅 0.110ns
//    40 行/帧  -> 12 帧 /  200ms  V28 旧观感("跳几下")
//----------------------------------------------------------------------------
//
//----------------------------------------------------------------------------
// 为什么能做到这么轻 (架构未变):
//   SDRAM 里两个帧缓存首尾相邻 —— BUF0 = 0, BUF1 = 307200, 一帧正好 307200 字。
//   所以"滑动"不需要双帧并行读、不需要行缓冲、不需要像素混合:
//      屏幕第 y 行要么来自旧图、要么来自新图, 同一时刻只读一个地址。
//   只要读序列的起点偏移一个行数, 并在过渡分界处做一次地址跳转即可。
//
// 设 q = 已位移字数 (= 位移行数 * 640), 0 < q < 307200:
//
//   下滑 (dir=1): 读 new[(480-p)..479] 再 old[0..(479-p)]
//                 start_idx = new, start_off = 307200-q, seg_cnt = q, seg -> old
//   上滑 (dir=0): 读 old[p..479] 再 new[0..(p-1)]
//                 start_idx = old, start_off = q,         seg_cnt = 307200-q, seg -> new
//
//   q=0 时两种方向都等价于"整屏旧图", q=307200 时都等价于"整屏新图",
//   因此起止都连续, 没有黑场、没有跳变。
//
//   若两段在 SDRAM 里恰好首尾相接 (new 在前 / new 在后), 跳转可以省掉:
//     下滑且 new=BUF0 -> 起点 BUF0+(307200-q), 读 q 字正好接上 BUF1 = old   -> 无需跳转
//     上滑且 new=BUF1 -> 起点 BUF0+q,          读 307200-q 字正好接上 BUF1  -> 无需跳转
//   统一判据: seg_en = (dir == new_idx[0])
//
// 参数在 vs 上升沿推进, 由 frame_fifo_read 在每帧起始 (S_ACK) 一次性锁存,
// 所以整帧读取过程中参数恒定, 不会出现"读到一半偏移变了"的撕裂。
//
// 时钟域: clk = video_clk 25MHz; new_idx / dir 来自慢变寄存器, 打两拍同步。
//============================================================================
module trans_fade #(
    parameter STEP_ROWS = 10,        // 每帧位移行数 (480/10 = 48 帧 ≈ 800ms)
    parameter OUT_W     = 640,       // 输出宽 (一行像素数)
    parameter OUT_H     = 480        // 输出高 (一帧行数)
)(
    input  wire        clk,          // video_clk 25MHz
    input  wire        rst,          // 高有效复位
    input  wire        vs,           // 场同步
    input  wire        de,           // 数据有效 (本版滑动不需要行内相位, 保留兼容)
    input  wire        disp_on,      // display_valid: 首图提交后为 1
    input  wire [1:0]  new_idx,      // 目标帧索引 (来自 sd_card_bmp, 跨时钟域慢变)
    input  wire        dir,          // 1=下一张(下滑)  0=上一张(上滑)
    input  wire [1:0]  mode,         // 0=滑动  1=淡入淡出  2=旋转擦除 (V34)
    input  wire [23:0] rgb_in,       // 帧缓存输出
    output wire [23:0] rgb_out,      // 转场后 (三种方式都由地址/增益完成, 像素直通)
    output wire [1:0]  idx_out,      // 读起始帧索引 -> read_addr_index
    output wire [20:0] start_off,    // 读起始地址偏移(字) -> 加到 read_addr_0/1
    output wire        seg_en,       // 帧内跳转使能
    output wire [18:0] seg_cnt,      // 跳转点(已读字数)
    output wire        seg_idx,      // 跳转目标帧索引
    output wire [4:0]  fade_scale,   // V32: 淡变系数 0..16 (16=原亮度 0=全黑)
    // V34: 旋转擦除参数 -> frame_fifo_read
    output wire        wipe_en,
    output wire [1:0]  wipe_q,       // 象限 0..3
    output wire signed [19:0] wipe_x0,   // 第 0 行边界 x (Q12.4)
    output wire signed [11:0] wipe_dx,   // 每行边界增量 (Q.4)
    output wire        wipe_dir,     // 1=顺时针 0=逆时针
    output wire        wipe_new_idx, // 新图帧索引
    output wire        wipe_full     // 1: 整屏新图 (最后一帧收尾)
);

localparam [18:0] TOTAL  = OUT_W * OUT_H;             // 307200 字/帧
localparam [18:0] STEP_Q = STEP_ROWS * OUT_W;         // 每帧步长(字) = 10*640 = 6400

//--------------------------------------------------------------------------
// new_idx 跨时钟域同步 (100MHz/50MHz -> 25MHz)
//--------------------------------------------------------------------------
reg [1:0] idx_s1, idx_s2;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        idx_s1 <= 2'd0;
        idx_s2 <= 2'd0;
    end else begin
        idx_s1 <= new_idx;
        idx_s2 <= idx_s1;
    end
end

//--------------------------------------------------------------------------
// 场边界
//--------------------------------------------------------------------------
reg vs_d;
wire vs_rise = vs & ~vs_d;

//--------------------------------------------------------------------------
// 转场状态机 (每帧 vs 上升沿推进一次)
//   V32: 状态从 1bit 扩到 2bit, 增加淡变的两个子状态
//--------------------------------------------------------------------------
localparam [2:0] S_IDLE     = 3'd0;   // 稳定显示
localparam [2:0] S_SLIDE    = 3'd1;   // 滑动中
localparam [2:0] S_FADE_OUT = 3'd2;   // 淡出: 旧图逐渐变暗到全黑
localparam [2:0] S_FADE_IN  = 3'd3;   // 淡入: 新图逐渐变亮到原亮度
localparam [2:0] S_ROT      = 3'd4;   // 旋转擦除 (V34)

reg [2:0]  st;
reg [1:0]  idx_r;               // 当前显示的帧
reg [1:0]  old_i, new_i;        // 本次转场的旧帧/新帧
reg        dir_l;               // 本次转场方向 (锁存, 动画期间不变)
reg [18:0] q;                   // 已位移字数
reg [4:0]  fc;                  // V32: 淡变计数器 0..16, 直接当增益
reg [3:0]  rot_a;               // V34: 象限内角度序号 0..11 (每档 7.5°)
reg [1:0]  rot_q;               // V34: 当前象限 0..3

// mode 来自 top.v 的 video_clk 域两级同步寄存器, 这里再用一拍即可
reg [1:0] mode_s;
always @(posedge clk or posedge rst) begin
    if (rst) mode_s <= 2'd0;
    else     mode_s <= mode;
end

//--------------------------------------------------------------------------
// V34: tan / cot 查表 (Q.4, 角度步进 7.5°)
//   只需 12 档: 0, 7.5, 15, ... 82.5°。90° 处 tan/cot 发散, 取 2047 (=127.9)
//   作为"无穷大"的替身 —— 边界立刻跑到屏外 20 行以内, 视觉上等价于无穷。
//   (取 122 (=7.6) 会在象限交界处留下约 40 行的三角楔形, 太明显)
//--------------------------------------------------------------------------
reg [10:0] tan4, cot4;
always @(*) begin
    case (rot_a)
        4'd0:    begin tan4 = 11'd0;    cot4 = 11'd2047; end
        4'd1:    begin tan4 = 11'd2;    cot4 = 11'd122;  end
        4'd2:    begin tan4 = 11'd4;    cot4 = 11'd60;   end
        4'd3:    begin tan4 = 11'd7;    cot4 = 11'd39;   end
        4'd4:    begin tan4 = 11'd9;    cot4 = 11'd28;   end
        4'd5:    begin tan4 = 11'd12;   cot4 = 11'd21;   end
        4'd6:    begin tan4 = 11'd16;   cot4 = 11'd16;   end
        4'd7:    begin tan4 = 11'd21;   cot4 = 11'd12;   end
        4'd8:    begin tan4 = 11'd28;   cot4 = 11'd9;    end
        4'd9:    begin tan4 = 11'd39;   cot4 = 11'd7;    end
        4'd10:   begin tan4 = 11'd60;   cot4 = 11'd4;    end
        4'd11:   begin tan4 = 11'd122;  cot4 = 11'd2;    end
        default: begin tan4 = 11'd0;    cot4 = 11'd2047; end
    endcase
end

// q0/q2 用 tan, q1/q3 用 cot —— 注意 rot_q 是 2bit: q0=00 q1=01 q2=10 q3=11,
// 所以判据是 rot_q[0] (低位), 不是 rot_q[1]。
wire [10:0] t4     = rot_q[0] ? cot4 : tan4;
wire [18:0] t4x240 = {8'd0, t4} * 19'd240;                // 最大 2047*240 = 491280
// q0/q2: x0 = 320 + 240*T ; q1/q3: x0 = 320 - 240*T   (Q12.4)
wire signed [19:0] x0_calc = rot_q[0] ? (20'sd5120 - {1'b0, t4x240})
                                      : (20'sd5120 + {1'b0, t4x240});
// q0/q2: 每行 -T ; q1/q3: 每行 +T
wire signed [11:0] dx_calc = rot_q[0] ? $signed({1'b0, t4}) : -$signed({1'b0, t4});

// 每帧位移量固定 —— 匀速, 没有加速度突变, 人眼最容易接受
//   (不加"末段减速"是实测取舍: 见文件头注释, 那会让 SWNS 掉到 0.110ns)

always @(posedge clk or posedge rst) begin
    if (rst) begin
        vs_d  <= 1'b0;
        st    <= S_IDLE;
        idx_r <= 2'd0;
        old_i <= 2'd0;
        new_i <= 2'd0;
        dir_l <= 1'b1;
        q     <= 19'd0;
        fc    <= 5'd16;
        rot_a <= 4'd0;
        rot_q <= 2'd0;
    end else begin
        vs_d <= vs;
        if (vs_rise) begin
            case (st)
            S_IDLE: begin
                if (!disp_on) begin
                    // 首图阶段: 索引直接跟随, 不做转场
                    idx_r <= idx_s2;
                    q     <= 19'd0;
                end else if (idx_s2 != idx_r) begin
                    // 新图就绪 -> 按当前模式启动转场
                    old_i <= idx_r;
                    new_i <= idx_s2;
                    dir_l <= dir;
                    if (mode_s == 2'd2) begin
                        // 旋转擦除: 从 0° 开始扫
                        rot_q <= 2'd0;
                        rot_a <= 4'd0;
                        st    <= S_ROT;
                    end else if (mode_s == 2'd1) begin
                        // 淡出: 第一帧就降到 15/16 亮度, 之后每帧 -1 档
                        fc <= 5'd15;
                        st <= S_FADE_OUT;
                    end else begin
                        // 滑动: 第一帧即走一步步长
                        q  <= STEP_Q;
                        st <= S_SLIDE;
                    end
                end
            end

            S_SLIDE: begin
                if (q + STEP_Q >= TOTAL) begin
                    // 位移满一屏: 直接落到纯新图, 回到稳定态
                    // STEP_ROWS 取 480 的约数时 q+STEP_Q 恰好等于 TOTAL, 不会产生"补差尾步"
                    idx_r <= new_i;
                    q     <= 19'd0;
                    st    <= S_IDLE;
                end else begin
                    q <= q + STEP_Q;
                end
            end

            S_FADE_OUT: begin
                // 逐帧压暗; fc 到 0 时整屏全黑, 恰好在这一帧换图(切换动作不可见)
                if (fc == 5'd0) begin
                    idx_r <= new_i;
                    fc    <= 5'd1;
                    st    <= S_FADE_IN;
                end else begin
                    fc <= fc - 5'd1;
                end
            end

            S_FADE_IN: begin
                // 逐帧提亮; fc 到 16 (fade_scale=16) 即恢复原亮度, 回稳定态
                if (fc >= 5'd16) begin
                    st <= S_IDLE;
                end else begin
                    fc <= fc + 5'd1;
                    if (fc == 5'd15) st <= S_IDLE;
                end
            end

            S_ROT: begin
                // 每帧转 7.5°: 12 帧一个象限, 4 象限 = 48 帧 ≈ 800ms
                // 最后一帧 (q3,a11) 用 wipe_full 收尾, 下一帧切到稳定显示新图
                if (rot_a == 4'd11) begin
                    rot_a <= 4'd0;
                    if (rot_q == 2'd3) begin
                        idx_r <= new_i;
                        st    <= S_IDLE;
                    end else begin
                        rot_q <= rot_q + 2'd1;
                    end
                end else begin
                    rot_a <= rot_a + 4'd1;
                end
            end
            endcase
        end
    end
end

//--------------------------------------------------------------------------
// 输出: 起始帧 / 起始偏移 / 跳转参数
//   只有 S_SLIDE 才用地址偏移; 稳定态与淡变态全部回落到
//   "从 idx_r 第一行开始读整帧", 与原逻辑一致
//--------------------------------------------------------------------------
wire sliding = (st == S_SLIDE);
wire [18:0] q_rev = TOTAL - q;          // 反向位移量 (下滑时用作起始偏移)

assign idx_out   = sliding ? (dir_l ? new_i : old_i) : idx_r;
assign start_off = sliding ? (dir_l ? {2'b00, q_rev} : {2'b00, q}) : 21'd0;
assign seg_cnt   = sliding ? (dir_l ? q : q_rev) : 19'd0;
assign seg_idx   = sliding ? (dir_l ? old_i[0] : new_i[0]) : idx_r[0];
assign seg_en    = sliding && (dir_l == new_i[0]);

// 淡变系数: 稳定态/滑动态恒为 16 (不做增益变化), 只有淡变状态才由 fc 决定
//   fc=16 -> 满亮度 ; fc=0 -> 全黑 ; 中间每帧一档, 共 17 档
assign fade_scale = fc;

//--------------------------------------------------------------------------
// V34: 旋转擦除输出
//   st=S_ROT 期间才有效; 其余状态 wipe_en=0, 读侧回到"整帧线性读 idx_r"
//--------------------------------------------------------------------------
assign wipe_en      = (st == S_ROT);
assign wipe_q       = rot_q;
assign wipe_x0      = x0_calc;
assign wipe_dx      = dx_calc;
assign wipe_dir     = dir_l;
assign wipe_new_idx = new_i[0];
// 最后一帧 (q3 的 82.5°) 强制整屏新图: 82.5° 之后 tan 已饱和,
// 不补这一帧会残留一个扫不到的楔形, 且与下一帧的稳定显示对不上
assign wipe_full    = (st == S_ROT) && (rot_q == 2'd3) && (rot_a == 4'd11);

// 像素始终直通: 滑动靠读地址完成, 淡变靠 bright_ctrl 里的增益完成
assign rgb_out = rgb_in;

endmodule
