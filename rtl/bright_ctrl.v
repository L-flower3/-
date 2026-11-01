//============================================================================
// bright_ctrl.v — 画面亮度/对比度调节 + 淡变增益 + 左上角三行 OSD 状态栏
//
// 亮度:   out = rgb * bright / 256              (256=100%, 64..512 即 25%..200%)
// 对比度: out = (rgb - 128) * contrast / 256 + 128   (256=100%, 128..512 即 50%..200%)
//
// 两者合并为一个线性变换, 避免每像素做两遍:
//       out = rgb * k / 256 + offset
//       k      = bright * contrast / 256                     (增益)
//       offset = (256 - contrast) / 2                        (偏移, 可为负)
//
// V32 增加淡变(fade): 把 k 和 offset 再乘一个 0/16..16/16 的系数
//       k'      = k      * fade / 16
//       offset' = offset * fade / 16
//   淡变系数每帧才变一次, 所以这一次乘法发生在"慢速预计算"通路里,
//   像素通路上一个乘法器都没增加 —— 这是 V32 能把淡变塞进现有资源的关键。
//   fade=16 时 k'=k、offset'=offset, 与原逻辑逐位等价。
//
// 只作用于图片画面(插在转场之前), 不影响字幕/VU表/应急画面
//
// OSD : 左上角三行 (8x16 等宽字符)
//         行1  "640x480"     —— 图片分辨率
//         行2  "BRI 100%" / "CON 100%" —— 当前调节的参数与数值
//         行3  "SLIDE" / "FADE"       —— 当前转场方式 (KEY7 切换)
//       ALWAYS_ON=1: 有图即常显 (默认, 类监视器信息角标)
//       ALWAYS_ON=0: 仅在调节参数后 2 秒内显示 (不干扰观演)
//============================================================================
module bright_ctrl #(
    parameter ALWAYS_ON = 1
)(
    input  wire        clk,       // video_clk 25MHz
    input  wire        rst,
    input  wire        hs,
    input  wire        vs,
    input  wire        de,
    input  wire [9:0]  bright,    // 亮度增益 (256 = 100%)
    input  wire [9:0]  contrast,  // 对比度增益 (256 = 100%)
    input  wire        con_mode,  // 0 = OSD 显示 BRI, 1 = 显示 CON
    input  wire [4:0]  fade,      // V32: 淡变系数 0..16 (16=原亮度, 0=全黑)
    input  wire [1:0]  trans_mode,// 0 = 滑动转场, 1 = 淡入淡出, 2 = 旋转擦除 (V34)
    input  wire        show,      // OSD 总使能 (接 display_valid: 有图才显示)
    input  wire        bri_show,  // 参数调节后 2 秒窗口 (ALWAYS_ON=0 时用)
    input  wire        is_1280,   // 当前图分辨率: 1=1280x960, 0=640x480
    input  wire [23:0] rgb_in,
    output wire [23:0] rgb_out
);

wire osd_en = ALWAYS_ON ? show : (show & bri_show);

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
        de_d <= 1'b0; vs_d <= 1'b0; px <= 10'd0; py <= 10'd0;
    end else begin
        de_d <= de; vs_d <= vs;
        if (vs_rise)      py <= 10'd0;
        else if (de_fall) py <= (py == 10'd479) ? 10'd0 : py + 10'd1;
        if (de_rise)      px <= 10'd0;
        else if (de)      px <= px + 10'd1;
    end
end

//--------------------------------------------------------------------------
// 亮度与对比度合并成一条线性变换: out = rgb * k/256 + offset
//   k      = bright * contrast / 256       (增益, 256=既不过亮也不过暗)
//   offset = (256 - contrast) / 2          (围绕中灰 128 的支点偏移, 可为负)
//   k / offset 只随按键参数变化, 参数不变时恒定 —— 相当于预计算,
//   像素通路只需一次乘法 + 一次加法 + 饱和, 不必再串第二级乘法器。
//
//   V32 淡变: k' = k*fade/16, offset' = offset*fade/16
//     fade 是 5bit 慢变(每帧一次), 这里 11x5 / 10x5 的小乘法同样落在慢速通路,
//     不进像素运算链; fade=16 时为恒等变换(>>4 正好除回去)。
//--------------------------------------------------------------------------
wire [19:0] k_mul = bright * contrast;        // 10x10 -> 20bit
wire [10:0] k_raw = k_mul[18:8];              // /256, 最大 512*512/256 = 1024

wire [15:0] kf_mul = k_raw * fade;            // 11x5 -> 16bit
wire [10:0] k     = kf_mul[14:4];             // /16, fade=16 时等于 k_raw

wire        off_neg = (contrast >= 10'd256);  // 对比度 >100% 时段偏移为负
wire [9:0]  off_raw = off_neg ? ((contrast - 10'd256) >> 1)
                              : ((10'd256 - contrast) >> 1);

wire [14:0] off_mul = off_raw * fade;         // 10x5 -> 15bit
wire [9:0]  off_mag = off_mul[13:4];          // /16, fade=16 时等于 off_raw

//--------------------------------------------------------------------------
// k / offset 打一拍再用
//   bright*contrast -> *fade -> 8x11 乘像素 -> 加法 -> 饱和, 整串是纯组合的,
//   25MHz(40ns) 下虽然还过得去, 但它和 bmp_read 那条关键路径抢布线资源。
//   k/offset 只在按按键或换帧时才变, 多一拍(40ns)延迟肉眼不可能察觉,
//   打拍等于把这条长链砍成两段, 是"零代价换时序"。
//--------------------------------------------------------------------------
reg [10:0] k_r;
reg [9:0]  off_r;
reg        off_neg_r;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        k_r       <= 11'd256;      // 复位时 100% 亮度/对比度
        off_r     <= 10'd0;
        off_neg_r <= 1'b0;
    end else begin
        k_r       <= k;
        off_r     <= off_mag;
        off_neg_r <= off_neg;
    end
end

wire [18:0] mul_r = rgb_in[23:16] * k_r;      // 8x11 -> 19bit
wire [18:0] mul_g = rgb_in[15:8]  * k_r;
wire [18:0] mul_b = rgb_in[7:0]   * k_r;

wire [10:0] gr = mul_r[18:8];                 // /256, 最大 1020
wire [10:0] gg = mul_g[18:8];
wire [10:0] gb = mul_b[18:8];

// 加/减偏移: 减法结果为负时 12bit 补码的 bit11=1 -> 直接判负
wire [11:0] ar = off_neg_r ? ({1'b0, gr} - {2'b0, off_r}) : ({1'b0, gr} + {2'b0, off_r});
wire [11:0] ag = off_neg_r ? ({1'b0, gg} - {2'b0, off_r}) : ({1'b0, gg} + {2'b0, off_r});
wire [11:0] ab = off_neg_r ? ({1'b0, gb} - {2'b0, off_r}) : ({1'b0, gb} + {2'b0, off_r});

wire [23:0] adj = { ar[11] ? 8'h00 : (ar[10:8] != 3'd0) ? 8'hFF : ar[7:0],
                    ag[11] ? 8'h00 : (ag[10:8] != 3'd0) ? 8'hFF : ag[7:0],
                    ab[11] ? 8'h00 : (ab[10:8] != 3'd0) ? 8'hFF : ab[7:0] };

//--------------------------------------------------------------------------
// 参数百分比: pct = val*100/256   (64->25, 256->100, 512->200)
//   val 取当前模式对应的参数, 这样 BRI 行的算法可以直接复用到 CON 行
//   百位 h / 十位 t (rem*205>>11 近似 /10) / 个位 u
//--------------------------------------------------------------------------
wire [9:0]  cur_val = con_mode ? contrast : bright;
wire [17:0] pct_mul = cur_val * 8'd100;
wire [15:0] pct     = pct_mul >> 8;
wire [1:0]  h    = (pct >= 16'd200) ? 2'd2 : (pct >= 16'd100) ? 2'd1 : 2'd0;
wire [9:0]  h100 = (h == 2'd2) ? 10'd200 : (h == 2'd1) ? 10'd100 : 10'd0;
wire [6:0]  rem  = pct - h100;
wire [15:0] t_mul = rem * 8'd205;
wire [3:0]  t     = t_mul >> 11;
wire [7:0]  t10  = {4'b0, t} * 8'd10;
wire [7:0]  u8   = {1'b0, rem} - t10;
wire [3:0]  u    = u8[3:0];

//--------------------------------------------------------------------------
// 字库: 0-9 数字(x='0'..'9' 索引 0..9), 10='x' 11='B' 12='R' 13='I'
//       14='%' 15=SP 16='C' 17='O' 18='N' 19='S' 20='L' 21='D'
//       22='E' 23='F' 24='A' 25='T'   共 26 字符 x 16 行 x 8bit
//       (16..18 是 V31 对比度 OSD 新增; 19..24 是 V32 转场名 OSD 新增;
//        25 是 V34 "ROTATE" 新增)
//--------------------------------------------------------------------------
reg [7:0] chr_rom [0:415];
initial begin
    chr_rom[  0] = 8'h00;  // '0'
    chr_rom[  1] = 8'h00;
    chr_rom[  2] = 8'h00;
    chr_rom[  3] = 8'h3C;
    chr_rom[  4] = 8'h26;
    chr_rom[  5] = 8'h46;
    chr_rom[  6] = 8'h4A;
    chr_rom[  7] = 8'h52;
    chr_rom[  8] = 8'h62;
    chr_rom[  9] = 8'h64;
    chr_rom[ 10] = 8'h3C;
    chr_rom[ 11] = 8'h00;
    chr_rom[ 12] = 8'h00;
    chr_rom[ 13] = 8'h00;
    chr_rom[ 14] = 8'h00;
    chr_rom[ 15] = 8'h00;
    chr_rom[ 16] = 8'h00;  // '1'
    chr_rom[ 17] = 8'h00;
    chr_rom[ 18] = 8'h00;
    chr_rom[ 19] = 8'h30;
    chr_rom[ 20] = 8'h50;
    chr_rom[ 21] = 8'h10;
    chr_rom[ 22] = 8'h10;
    chr_rom[ 23] = 8'h10;
    chr_rom[ 24] = 8'h10;
    chr_rom[ 25] = 8'h10;
    chr_rom[ 26] = 8'h7C;
    chr_rom[ 27] = 8'h00;
    chr_rom[ 28] = 8'h00;
    chr_rom[ 29] = 8'h00;
    chr_rom[ 30] = 8'h00;
    chr_rom[ 31] = 8'h00;
    chr_rom[ 32] = 8'h00;  // '2'
    chr_rom[ 33] = 8'h00;
    chr_rom[ 34] = 8'h00;
    chr_rom[ 35] = 8'h38;
    chr_rom[ 36] = 8'h44;
    chr_rom[ 37] = 8'h04;
    chr_rom[ 38] = 8'h04;
    chr_rom[ 39] = 8'h08;
    chr_rom[ 40] = 8'h10;
    chr_rom[ 41] = 8'h20;
    chr_rom[ 42] = 8'h7C;
    chr_rom[ 43] = 8'h00;
    chr_rom[ 44] = 8'h00;
    chr_rom[ 45] = 8'h00;
    chr_rom[ 46] = 8'h00;
    chr_rom[ 47] = 8'h00;
    chr_rom[ 48] = 8'h00;  // '3'
    chr_rom[ 49] = 8'h00;
    chr_rom[ 50] = 8'h00;
    chr_rom[ 51] = 8'h78;
    chr_rom[ 52] = 8'h04;
    chr_rom[ 53] = 8'h04;
    chr_rom[ 54] = 8'h38;
    chr_rom[ 55] = 8'h04;
    chr_rom[ 56] = 8'h04;
    chr_rom[ 57] = 8'h04;
    chr_rom[ 58] = 8'h78;
    chr_rom[ 59] = 8'h00;
    chr_rom[ 60] = 8'h00;
    chr_rom[ 61] = 8'h00;
    chr_rom[ 62] = 8'h00;
    chr_rom[ 63] = 8'h00;
    chr_rom[ 64] = 8'h00;  // '4'
    chr_rom[ 65] = 8'h00;
    chr_rom[ 66] = 8'h00;
    chr_rom[ 67] = 8'h18;
    chr_rom[ 68] = 8'h38;
    chr_rom[ 69] = 8'h28;
    chr_rom[ 70] = 8'h48;
    chr_rom[ 71] = 8'h88;
    chr_rom[ 72] = 8'hFE;
    chr_rom[ 73] = 8'h08;
    chr_rom[ 74] = 8'h08;
    chr_rom[ 75] = 8'h00;
    chr_rom[ 76] = 8'h00;
    chr_rom[ 77] = 8'h00;
    chr_rom[ 78] = 8'h00;
    chr_rom[ 79] = 8'h00;
    chr_rom[ 80] = 8'h00;  // '5'
    chr_rom[ 81] = 8'h00;
    chr_rom[ 82] = 8'h00;
    chr_rom[ 83] = 8'h7C;
    chr_rom[ 84] = 8'h40;
    chr_rom[ 85] = 8'h40;
    chr_rom[ 86] = 8'h78;
    chr_rom[ 87] = 8'h04;
    chr_rom[ 88] = 8'h04;
    chr_rom[ 89] = 8'h0C;
    chr_rom[ 90] = 8'h78;
    chr_rom[ 91] = 8'h00;
    chr_rom[ 92] = 8'h00;
    chr_rom[ 93] = 8'h00;
    chr_rom[ 94] = 8'h00;
    chr_rom[ 95] = 8'h00;
    chr_rom[ 96] = 8'h00;  // '6'
    chr_rom[ 97] = 8'h00;
    chr_rom[ 98] = 8'h00;
    chr_rom[ 99] = 8'h1C;
    chr_rom[100] = 8'h20;
    chr_rom[101] = 8'h40;
    chr_rom[102] = 8'h5C;
    chr_rom[103] = 8'h62;
    chr_rom[104] = 8'h42;
    chr_rom[105] = 8'h42;
    chr_rom[106] = 8'h3C;
    chr_rom[107] = 8'h00;
    chr_rom[108] = 8'h00;
    chr_rom[109] = 8'h00;
    chr_rom[110] = 8'h00;
    chr_rom[111] = 8'h00;
    chr_rom[112] = 8'h00;  // '7'
    chr_rom[113] = 8'h00;
    chr_rom[114] = 8'h00;
    chr_rom[115] = 8'h7E;
    chr_rom[116] = 8'h02;
    chr_rom[117] = 8'h04;
    chr_rom[118] = 8'h0C;
    chr_rom[119] = 8'h08;
    chr_rom[120] = 8'h18;
    chr_rom[121] = 8'h10;
    chr_rom[122] = 8'h30;
    chr_rom[123] = 8'h00;
    chr_rom[124] = 8'h00;
    chr_rom[125] = 8'h00;
    chr_rom[126] = 8'h00;
    chr_rom[127] = 8'h00;
    chr_rom[128] = 8'h00;  // '8'
    chr_rom[129] = 8'h00;
    chr_rom[130] = 8'h00;
    chr_rom[131] = 8'h38;
    chr_rom[132] = 8'h44;
    chr_rom[133] = 8'h64;
    chr_rom[134] = 8'h38;
    chr_rom[135] = 8'h6C;
    chr_rom[136] = 8'h44;
    chr_rom[137] = 8'h44;
    chr_rom[138] = 8'h38;
    chr_rom[139] = 8'h00;
    chr_rom[140] = 8'h00;
    chr_rom[141] = 8'h00;
    chr_rom[142] = 8'h00;
    chr_rom[143] = 8'h00;
    chr_rom[144] = 8'h00;  // '9'
    chr_rom[145] = 8'h00;
    chr_rom[146] = 8'h00;
    chr_rom[147] = 8'h3C;
    chr_rom[148] = 8'h42;
    chr_rom[149] = 8'h42;
    chr_rom[150] = 8'h46;
    chr_rom[151] = 8'h3A;
    chr_rom[152] = 8'h02;
    chr_rom[153] = 8'h04;
    chr_rom[154] = 8'h38;
    chr_rom[155] = 8'h00;
    chr_rom[156] = 8'h00;
    chr_rom[157] = 8'h00;
    chr_rom[158] = 8'h00;
    chr_rom[159] = 8'h00;
    chr_rom[160] = 8'h00;  // 'x'
    chr_rom[161] = 8'h00;
    chr_rom[162] = 8'h00;
    chr_rom[163] = 8'h00;
    chr_rom[164] = 8'h00;
    chr_rom[165] = 8'h66;
    chr_rom[166] = 8'h2C;
    chr_rom[167] = 8'h18;
    chr_rom[168] = 8'h28;
    chr_rom[169] = 8'h64;
    chr_rom[170] = 8'hC6;
    chr_rom[171] = 8'h00;
    chr_rom[172] = 8'h00;
    chr_rom[173] = 8'h00;
    chr_rom[174] = 8'h00;
    chr_rom[175] = 8'h00;
    chr_rom[176] = 8'h00;  // 'B'
    chr_rom[177] = 8'h00;
    chr_rom[178] = 8'h00;
    chr_rom[179] = 8'h78;
    chr_rom[180] = 8'h44;
    chr_rom[181] = 8'h44;
    chr_rom[182] = 8'h78;
    chr_rom[183] = 8'h44;
    chr_rom[184] = 8'h44;
    chr_rom[185] = 8'h44;
    chr_rom[186] = 8'h78;
    chr_rom[187] = 8'h00;
    chr_rom[188] = 8'h00;
    chr_rom[189] = 8'h00;
    chr_rom[190] = 8'h00;
    chr_rom[191] = 8'h00;
    chr_rom[192] = 8'h00;  // 'R'
    chr_rom[193] = 8'h00;
    chr_rom[194] = 8'h00;
    chr_rom[195] = 8'h78;
    chr_rom[196] = 8'h44;
    chr_rom[197] = 8'h44;
    chr_rom[198] = 8'h44;
    chr_rom[199] = 8'h78;
    chr_rom[200] = 8'h4C;
    chr_rom[201] = 8'h44;
    chr_rom[202] = 8'h46;
    chr_rom[203] = 8'h00;
    chr_rom[204] = 8'h00;
    chr_rom[205] = 8'h00;
    chr_rom[206] = 8'h00;
    chr_rom[207] = 8'h00;
    chr_rom[208] = 8'h00;  // 'I'
    chr_rom[209] = 8'h00;
    chr_rom[210] = 8'h00;
    chr_rom[211] = 8'h7C;
    chr_rom[212] = 8'h10;
    chr_rom[213] = 8'h10;
    chr_rom[214] = 8'h10;
    chr_rom[215] = 8'h10;
    chr_rom[216] = 8'h10;
    chr_rom[217] = 8'h10;
    chr_rom[218] = 8'h7C;
    chr_rom[219] = 8'h00;
    chr_rom[220] = 8'h00;
    chr_rom[221] = 8'h00;
    chr_rom[222] = 8'h00;
    chr_rom[223] = 8'h00;
    chr_rom[224] = 8'h00;  // '%'
    chr_rom[225] = 8'h00;
    chr_rom[226] = 8'hE2;
    chr_rom[227] = 8'hA4;
    chr_rom[228] = 8'hA8;
    chr_rom[229] = 8'hE8;
    chr_rom[230] = 8'h10;
    chr_rom[231] = 8'h2E;
    chr_rom[232] = 8'h2A;
    chr_rom[233] = 8'h4A;
    chr_rom[234] = 8'h8E;
    chr_rom[235] = 8'h00;
    chr_rom[236] = 8'h00;
    chr_rom[237] = 8'h00;
    chr_rom[238] = 8'h00;
    chr_rom[239] = 8'h00;
    chr_rom[240] = 8'h00;  // 'SP'
    chr_rom[241] = 8'h00;
    chr_rom[242] = 8'h00;
    chr_rom[243] = 8'h00;
    chr_rom[244] = 8'h00;
    chr_rom[245] = 8'h00;
    chr_rom[246] = 8'h00;
    chr_rom[247] = 8'h00;
    chr_rom[248] = 8'h00;
    chr_rom[249] = 8'h00;
    chr_rom[250] = 8'h00;
    chr_rom[251] = 8'h00;
    chr_rom[252] = 8'h00;
    chr_rom[253] = 8'h00;
    chr_rom[254] = 8'h00;
    chr_rom[255] = 8'h00;

    // ---- V31 新增三个字符: 'C' 'O' 'N' (对比度 OSD "CON nnn%") ----
    chr_rom[256] = 8'h00;  // 'C'
    chr_rom[257] = 8'h00;
    chr_rom[258] = 8'h00;
    chr_rom[259] = 8'h3C;
    chr_rom[260] = 8'h42;
    chr_rom[261] = 8'h40;
    chr_rom[262] = 8'h40;
    chr_rom[263] = 8'h40;
    chr_rom[264] = 8'h40;
    chr_rom[265] = 8'h42;
    chr_rom[266] = 8'h3C;
    chr_rom[267] = 8'h00;
    chr_rom[268] = 8'h00;
    chr_rom[269] = 8'h00;
    chr_rom[270] = 8'h00;
    chr_rom[271] = 8'h00;
    chr_rom[272] = 8'h00;  // 'O'
    chr_rom[273] = 8'h00;
    chr_rom[274] = 8'h00;
    chr_rom[275] = 8'h3C;
    chr_rom[276] = 8'h42;
    chr_rom[277] = 8'h42;
    chr_rom[278] = 8'h42;
    chr_rom[279] = 8'h42;
    chr_rom[280] = 8'h42;
    chr_rom[281] = 8'h42;
    chr_rom[282] = 8'h3C;
    chr_rom[283] = 8'h00;
    chr_rom[284] = 8'h00;
    chr_rom[285] = 8'h00;
    chr_rom[286] = 8'h00;
    chr_rom[287] = 8'h00;
    chr_rom[288] = 8'h00;  // 'N'
    chr_rom[289] = 8'h00;
    chr_rom[290] = 8'h00;
    chr_rom[291] = 8'h42;
    chr_rom[292] = 8'h62;
    chr_rom[293] = 8'h52;
    chr_rom[294] = 8'h4A;
    chr_rom[295] = 8'h46;
    chr_rom[296] = 8'h42;
    chr_rom[297] = 8'h42;
    chr_rom[298] = 8'h42;
    chr_rom[299] = 8'h00;
    chr_rom[300] = 8'h00;
    chr_rom[301] = 8'h00;
    chr_rom[302] = 8'h00;
    chr_rom[303] = 8'h00;

    // ---- V32 新增六个字符: 'S' 'L' 'D' 'E' 'F' 'A' (转场名 OSD) ----
    chr_rom[304] = 8'h00;  // 'S'
    chr_rom[305] = 8'h00;
    chr_rom[306] = 8'h00;
    chr_rom[307] = 8'h3C;
    chr_rom[308] = 8'h42;
    chr_rom[309] = 8'h40;
    chr_rom[310] = 8'h3C;
    chr_rom[311] = 8'h02;
    chr_rom[312] = 8'h02;
    chr_rom[313] = 8'h42;
    chr_rom[314] = 8'h3C;
    chr_rom[315] = 8'h00;
    chr_rom[316] = 8'h00;
    chr_rom[317] = 8'h00;
    chr_rom[318] = 8'h00;
    chr_rom[319] = 8'h00;
    chr_rom[320] = 8'h00;  // 'L'
    chr_rom[321] = 8'h00;
    chr_rom[322] = 8'h00;
    chr_rom[323] = 8'h40;
    chr_rom[324] = 8'h40;
    chr_rom[325] = 8'h40;
    chr_rom[326] = 8'h40;
    chr_rom[327] = 8'h40;
    chr_rom[328] = 8'h40;
    chr_rom[329] = 8'h40;
    chr_rom[330] = 8'h7E;
    chr_rom[331] = 8'h00;
    chr_rom[332] = 8'h00;
    chr_rom[333] = 8'h00;
    chr_rom[334] = 8'h00;
    chr_rom[335] = 8'h00;
    chr_rom[336] = 8'h00;  // 'D'
    chr_rom[337] = 8'h00;
    chr_rom[338] = 8'h00;
    chr_rom[339] = 8'h78;
    chr_rom[340] = 8'h44;
    chr_rom[341] = 8'h44;
    chr_rom[342] = 8'h44;
    chr_rom[343] = 8'h44;
    chr_rom[344] = 8'h44;
    chr_rom[345] = 8'h44;
    chr_rom[346] = 8'h78;
    chr_rom[347] = 8'h00;
    chr_rom[348] = 8'h00;
    chr_rom[349] = 8'h00;
    chr_rom[350] = 8'h00;
    chr_rom[351] = 8'h00;
    chr_rom[352] = 8'h00;  // 'E'
    chr_rom[353] = 8'h00;
    chr_rom[354] = 8'h00;
    chr_rom[355] = 8'h7E;
    chr_rom[356] = 8'h40;
    chr_rom[357] = 8'h40;
    chr_rom[358] = 8'h7C;
    chr_rom[359] = 8'h40;
    chr_rom[360] = 8'h40;
    chr_rom[361] = 8'h40;
    chr_rom[362] = 8'h7E;
    chr_rom[363] = 8'h00;
    chr_rom[364] = 8'h00;
    chr_rom[365] = 8'h00;
    chr_rom[366] = 8'h00;
    chr_rom[367] = 8'h00;
    chr_rom[368] = 8'h00;  // 'F'
    chr_rom[369] = 8'h00;
    chr_rom[370] = 8'h00;
    chr_rom[371] = 8'h7E;
    chr_rom[372] = 8'h40;
    chr_rom[373] = 8'h40;
    chr_rom[374] = 8'h7C;
    chr_rom[375] = 8'h40;
    chr_rom[376] = 8'h40;
    chr_rom[377] = 8'h40;
    chr_rom[378] = 8'h40;
    chr_rom[379] = 8'h00;
    chr_rom[380] = 8'h00;
    chr_rom[381] = 8'h00;
    chr_rom[382] = 8'h00;
    chr_rom[383] = 8'h00;
    chr_rom[384] = 8'h00;  // 'A'
    chr_rom[385] = 8'h00;
    chr_rom[386] = 8'h00;
    chr_rom[387] = 8'h38;
    chr_rom[388] = 8'h44;
    chr_rom[389] = 8'h44;
    chr_rom[390] = 8'h44;
    chr_rom[391] = 8'h7C;
    chr_rom[392] = 8'h44;
    chr_rom[393] = 8'h44;
    chr_rom[394] = 8'h44;
    chr_rom[395] = 8'h00;
    chr_rom[396] = 8'h00;
    chr_rom[397] = 8'h00;
    chr_rom[398] = 8'h00;
    chr_rom[399] = 8'h00;
    chr_rom[400] = 8'h00;  // 'T' (V34: 用于 "ROTATE")
    chr_rom[401] = 8'h00;
    chr_rom[402] = 8'h00;
    chr_rom[403] = 8'h7C;
    chr_rom[404] = 8'h10;
    chr_rom[405] = 8'h10;
    chr_rom[406] = 8'h10;
    chr_rom[407] = 8'h10;
    chr_rom[408] = 8'h10;
    chr_rom[409] = 8'h10;
    chr_rom[410] = 8'h10;
    chr_rom[411] = 8'h00;
    chr_rom[412] = 8'h00;
    chr_rom[413] = 8'h00;
    chr_rom[414] = 8'h00;
    chr_rom[415] = 8'h00;
end

//--------------------------------------------------------------------------
// 三行版式 (8x16 等宽字符)
//   行1: x 24..88  (8 字符 "640x480 " / "1280x960")  y 24..40
//   行2: x 24..88  (8 字符 "BRI nnn%" / "CON nnn%")   y 42..58
//   行3: x 24..88  (8 字符 "SLIDE   " / "FADE    ")   y 60..76  (V32)
//--------------------------------------------------------------------------
wire in_row1 = osd_en && (px >= 10'd24) && (px < 10'd88) && (py >= 10'd24) && (py < 10'd40);
wire in_row2 = osd_en && (px >= 10'd24) && (px < 10'd88) && (py >= 10'd42) && (py < 10'd58);
wire in_row3 = osd_en && (px >= 10'd24) && (px < 10'd88) && (py >= 10'd60) && (py < 10'd76);
wire in_txt  = in_row1 | in_row2 | in_row3;

wire [6:0]  pxo  = px - 10'd24;                 // 0..63
wire [2:0]  cpos = pxo[5:3];                    // 0..7 字符位
wire [2:0]  cbit = 3'd7 - pxo[2:0];             // 位内偏移(高位在左)
wire [3:0]  crow = in_row3 ? (py - 10'd60) :
                   in_row2 ? (py - 10'd42) : (py - 10'd24);

// 百位: 0 -> 不显示(空格), 否则显示数字
wire [3:0] ci_h = (h == 2'd0) ? 4'd15 : {2'b0, h};

reg [4:0] cidx;                                // 5bit: 字库 25 字符
always @(*) begin
    if (in_row1) begin
        if (is_1280) begin
            case (cpos)                            // "1280x960"
                3'd0: cidx = 4'd1;                 // '1'
                3'd1: cidx = 4'd2;                 // '2'
                3'd2: cidx = 4'd8;                 // '8'
                3'd3: cidx = 4'd0;                 // '0'
                3'd4: cidx = 4'd10;                // 'x'
                3'd5: cidx = 4'd9;                 // '9'
                3'd6: cidx = 4'd6;                 // '6'
                3'd7: cidx = 4'd0;                 // '0'
                default: cidx = 4'd15;             // SP
            endcase
        end else begin
            case (cpos)                            // "640x480 "
                3'd0: cidx = 4'd6;                 // '6'
                3'd1: cidx = 4'd4;                 // '4'
                3'd2: cidx = 4'd0;                 // '0'
                3'd3: cidx = 4'd10;                // 'x'
                3'd4: cidx = 4'd4;                 // '4'
                3'd5: cidx = 4'd8;                 // '8'
                3'd6: cidx = 4'd0;                 // '0'
                default: cidx = 4'd15;             // SP
            endcase
        end
    end else if (in_row3) begin
        // 第三行: 当前转场方式 —— 0 -> "SLIDE   "  1 -> "FADE    "  2 -> "ROTATE  "
        // 按 KEY7 切换后这一行立刻变, 演示时不用切图也知道当前是哪种转场
        case (cpos)
            3'd0: cidx = (trans_mode == 2'd0) ? 5'd19 : ((trans_mode == 2'd1) ? 5'd23 : 5'd12); // S/F/R
            3'd1: cidx = (trans_mode == 2'd0) ? 5'd20 : ((trans_mode == 2'd1) ? 5'd24 : 5'd17); // L/A/O
            3'd2: cidx = (trans_mode == 2'd0) ? 5'd13 : ((trans_mode == 2'd1) ? 5'd21 : 5'd25); // I/D/T
            3'd3: cidx = (trans_mode == 2'd0) ? 5'd21 : ((trans_mode == 2'd1) ? 5'd22 : 5'd24); // D/E/A
            3'd4: cidx = (trans_mode == 2'd0) ? 5'd22 : ((trans_mode == 2'd1) ? 5'd15 : 5'd25); // E/SP/T
            3'd5: cidx = (trans_mode == 2'd2) ? 5'd22 : 5'd15;                                 // -/-/E
            default: cidx = 5'd15;                     // SP
        endcase
    end else begin
        // 第二行随模式切换:  0 -> "BRI nnn%"   1 -> "CON nnn%"
        // 用户长按 KEY6 切模式后, 这一行的前缀立刻变, 一眼看出在调哪个参数
        case (cpos)
            3'd0: cidx = con_mode ? 5'd16 : 5'd11;   // 'C' / 'B'
            3'd1: cidx = con_mode ? 5'd17 : 5'd12;   // 'O' / 'R'
            3'd2: cidx = con_mode ? 5'd18 : 5'd13;   // 'N' / 'I'
            3'd3: cidx = 5'd15;                      // SP
            3'd4: cidx = ci_h;
            3'd5: cidx = t;
            3'd6: cidx = u;
            default: cidx = 5'd14;                   // '%'
        endcase
    end
end

wire [7:0] cline = chr_rom[{cidx, crow}];
wire osd_on = in_txt && cline[cbit];

//--------------------------------------------------------------------------
// 暗底(原画面减半) + 白字
//   V32: 文字亮度也跟着淡变一起降, 否则淡到全黑那两帧会出现"纯黑底 + 白字"
//        的孤立刻字, 很扎眼。纯移位实现, 不引入乘法器。
//--------------------------------------------------------------------------
wire in_bg = osd_en && (px >= 10'd20) && (px < 10'd92) && (py >= 10'd20) && (py < 10'd78);
wire [23:0] dark = { {1'b0, adj[23:17]}, {1'b0, adj[15:9]}, {1'b0, adj[7:1]} };

wire [8:0]  osd_lvl9 = {fade, 4'b0};                  // fade*16: 16->256, 0->0
wire [7:0]  osd_lvl  = osd_lvl9[8] ? 8'hFF : osd_lvl9[7:0];

assign rgb_out = osd_on ? {osd_lvl, osd_lvl, osd_lvl} :
                 in_bg  ? dark :
                          adj;

endmodule
