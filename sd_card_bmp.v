
module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd4
)(
    input                       clk,
    input                       rst,
    input                       key_prev,   // KEY0(E10xE11): 上一张
    input                       key_next,   // KEY1(E10xD11): 下一张
    input                       key_auto,   // KEY2(E10xC11): 自动轮播 开/关（瞬时按键）
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg                  display_valid,
    output      [3:0]           state_code,
    output reg                  img_is_1280,      // 当前显示图片分辨率: 1=1280x960, 0=640x480

    input                       write_finish_toggle,
    output reg [1:0]            write_buf_idx,
    output reg [1:0]            disp_buf_idx,

    output                      write_req,
    input                       write_req_ack,
    output                      write_en,
    output [31:0]               write_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO,

    // ---- v7 WAV 音频 (FIFO 读侧跨到 video_clk 域) ----
    input                       fifo_rclk,        // video_clk 25MHz, 音频 FIFO 读时钟
    input                       wav_fifo_re,
    output [31:0]               wav_fifo_dout,
    output                      wav_fifo_empty,
    output [9:0]                wav_fifo_rdusedw,
    output                      wav_found,        // 已定位 WAV
    output                      wav_playing,      // 正在流式播放
    output                      sd_init_status    // SD 卡初始化完成 (诊断 led6)
);

wire key_prev_press;
wire key_next_press;
wire key_auto_press;

wire             bmp_sec_req;          // bmp_read 读请求 (仲裁器输入)
wire [31:0]      bmp_sec_addr;         // bmp_read 读地址
wire [7:0]       sd_sec_read_data;     // sd_card_top 原始输出
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire [3:0]       state_code_i;
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
wire             bmp_is_1280;      // bmp_read 输出: 当前加载图分辨率
wire             sd_init_done;
wire             bmp_ready;
wire             scan_done;
wire             scan_found_valid;
wire [31:0]      scan_found_sector;
wire [2:0]       scan_found_total;
wire             sd_rst;             // sd_card_top 复位 (含 2s 初始化重试看门狗)
// 仲裁器相关 (须在 bmp_read/sd_card_top 实例之前声明)
wire        sd_sec_read_arb;
wire [31:0] sd_sec_read_addr_arb;
wire        bmp_sec_dv;
wire        bmp_sec_end;

reg              scan_start_pulse;
reg              load_start_pulse;
reg [31:0]       load_sector;
reg              scan_kicked;
reg              first_image_committed;
reg              auto_play_en;
reg [31:0]       auto_cnt;
reg [2:0]        img_found_count;
reg [1:0]        img_idx;              // 当前真正显示中的图片编号
reg [1:0]        load_idx;             // 当前正在写入的图片编号
reg [1:0]        pending_buf_idx;      // 当前正在写入的目标缓冲区
reg [31:0]       img_sector0;
reg [31:0]       img_sector1;
reg [31:0]       img_sector2;
reg [31:0]       img_sector3;
reg              next_req_pending;
reg              prev_req_pending;
reg              load_busy;
reg [31:0]       load_timeout_cnt;

reg              load_abort;

// bmp_ready 先表示“源文件读取/送 FIFO 完成”；真正切显示要等 write_finish_toggle 同步后
reg              source_done_seen;
reg              write_done_seen;

// 同步 mem_clk 域的 write_finish_toggle
reg [2:0]        wrfin_tgl_sync;
wire             write_finish_pulse;

wire auto_tick;
wire [1:0] next_from_current;
wire [1:0] prev_from_current;

assign write_en   = bmp_data_wr_en;
assign write_data = {bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], 8'b0};
assign auto_tick  = (auto_cnt == (CLK_FREQ_HZ - 1));
assign next_from_current = next_index_limited(img_idx, img_found_count);
assign prev_from_current = prev_index_limited(img_idx, img_found_count);
assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
assign state_code = state_code_i;

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (50)
) u_key_prev (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_prev),
    .press_pulse(key_prev_press)
);

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (50)
) u_key_next (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_next),
    .press_pulse(key_next_press)
);

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (50)
) u_key_auto (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_auto),
    .press_pulse(key_auto_press)
);

function [1:0] next_index_limited;
    input [1:0] cur;
    input [2:0] count;
    begin
        case (count)
            3'd0: next_index_limited = 2'd0;
            3'd1: next_index_limited = 2'd0;
            3'd2: next_index_limited = (cur == 2'd1) ? 2'd0 : (cur + 2'd1);
            3'd3: next_index_limited = (cur == 2'd2) ? 2'd0 : (cur + 2'd1);
            default: next_index_limited = (cur == 2'd3) ? 2'd0 : (cur + 2'd1);
        endcase
    end
endfunction

function [1:0] prev_index_limited;
    input [1:0] cur;
    input [2:0] count;
    begin
        case (count)
            3'd0: prev_index_limited = 2'd0;
            3'd1: prev_index_limited = 2'd0;
            3'd2: prev_index_limited = (cur == 2'd0) ? 2'd1 : (cur - 2'd1);
            3'd3: prev_index_limited = (cur == 2'd0) ? 2'd2 : (cur - 2'd1);
            default: prev_index_limited = (cur == 2'd0) ? 2'd3 : (cur - 2'd1);
        endcase
    end
endfunction

function [31:0] sector_lut;
    input [1:0] idx;
    begin
        case (idx)
            2'd0: sector_lut = img_sector0;
            2'd1: sector_lut = img_sector1;
            2'd2: sector_lut = img_sector2;
            2'd3: sector_lut = img_sector3;
            default: sector_lut = img_sector0;
        endcase
    end
endfunction

function [1:0] next_buf_lut;
    input [1:0] cur_disp_buf;
    input       valid_now;
    begin
        if (!valid_now)
            next_buf_lut = 2'd0;                 // 首图固定写 buffer0
        else if (cur_disp_buf == 2'd0)
            next_buf_lut = 2'd1;
        else
            next_buf_lut = 2'd0;
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync        <= 3'b000;
        scan_start_pulse      <= 1'b0;
        load_start_pulse      <= 1'b0;
        load_sector           <= 32'd0;
        scan_kicked           <= 1'b0;
        first_image_committed <= 1'b0;
        auto_play_en          <= 1'b0;
        auto_cnt              <= 32'd0;
        img_found_count       <= 3'd0;
        img_idx               <= 2'd0;
        load_idx              <= 2'd0;
        pending_buf_idx       <= 2'd0;
        write_buf_idx         <= 2'd0;
        disp_buf_idx          <= 2'd0;
        img_sector0           <= 32'd0;
        img_sector1           <= 32'd0;
        img_sector2           <= 32'd0;
        img_sector3           <= 32'd0;
        next_req_pending      <= 1'b0;
        prev_req_pending      <= 1'b0;
        load_busy             <= 1'b0;
        load_timeout_cnt      <= 32'd0;
        load_abort            <= 1'b0;
        source_done_seen      <= 1'b0;
        write_done_seen       <= 1'b0;
        display_valid         <= 1'b0;
        img_is_1280           <= 1'b0;
    end else begin
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;
        load_abort       <= 1'b0;

        if (!sd_init_done) begin
            scan_kicked           <= 1'b0;
            first_image_committed <= 1'b0;
            auto_play_en          <= 1'b0;
            auto_cnt              <= 32'd0;
            img_found_count       <= 3'd0;
            img_idx               <= 2'd0;
            load_idx              <= 2'd0;
            pending_buf_idx       <= 2'd0;
            write_buf_idx         <= 2'd0;
            disp_buf_idx          <= 2'd0;
            img_sector0           <= 32'd0;
            img_sector1           <= 32'd0;
            img_sector2           <= 32'd0;
            img_sector3           <= 32'd0;
            next_req_pending      <= 1'b0;
            prev_req_pending      <= 1'b0;
            load_busy             <= 1'b0;
            load_timeout_cnt      <= 32'd0;
            load_abort            <= 1'b0;
            source_done_seen      <= 1'b0;
            write_done_seen       <= 1'b0;
            display_valid         <= 1'b0;
            img_is_1280           <= 1'b0;
        end else begin
            // 扫描阶段缓存前 4 张图的起始 sector
            if (scan_found_valid) begin
                case (img_found_count)
                    3'd0: img_sector0 <= scan_found_sector;
                    3'd1: img_sector1 <= scan_found_sector;
                    3'd2: img_sector2 <= scan_found_sector;
                    3'd3: img_sector3 <= scan_found_sector;
                    default: ;
                endcase

                if (img_found_count < 3'd4)
                    img_found_count <= img_found_count + 3'd1;
            end

            // 记住 bmp_read 已经把源图送完 FIFO，但还不能切显示，得等整帧写完
            if (load_busy && bmp_ready)
                source_done_seen <= 1'b1;

            // 记住写帧完成脉冲，避免“先写完后源结束”导致脉冲丢失而卡死
            if (load_busy && write_finish_pulse)
                write_done_seen <= 1'b1;

            // 只有“源图送完 + 整帧写完”都满足，才提交新图并切换显示缓冲区
            if (load_busy && source_done_seen && write_done_seen) begin
                load_busy             <= 1'b0;
                load_timeout_cnt      <= 32'd0;
                source_done_seen      <= 1'b0;
                write_done_seen       <= 1'b0;
                disp_buf_idx          <= pending_buf_idx;
                img_idx               <= load_idx;
                display_valid         <= 1'b1;
                first_image_committed <= 1'b1;
                img_is_1280           <= bmp_is_1280;
            end else if (load_busy) begin
                if (load_timeout_cnt > 32'd1_000_000_000) begin  // 10s @100MHz: 1280x960 降采样写入较慢, 需足够超时
                    // 超时（例如读到坏图或截断的文件导致死锁），强制释放 busy 以恢复按键响应
                    load_busy             <= 1'b0;
                    load_timeout_cnt      <= 32'd0;
                    source_done_seen      <= 1'b0;
                    write_done_seen       <= 1'b0;
                    load_abort            <= 1'b1;
                end else begin
                    load_timeout_cnt <= load_timeout_cnt + 32'd1;
                end
            end else begin
                load_timeout_cnt <= 32'd0;
            end

            // 上电后自动发起一次“扫描前 4 张 BMP”
            if (!scan_kicked && bmp_ready) begin
                scan_start_pulse      <= 1'b1;
                scan_kicked           <= 1'b1;
                first_image_committed <= 1'b0;
                auto_play_en          <= 1'b0;
                auto_cnt              <= 32'd0;
                img_found_count       <= 3'd0;
                img_idx               <= 2'd0;
                load_idx              <= 2'd0;
                pending_buf_idx       <= 2'd0;
                write_buf_idx         <= 2'd0;
                disp_buf_idx          <= 2'd0;
                next_req_pending      <= 1'b0;
                display_valid         <= 1'b0;
                load_busy             <= 1'b0;
                source_done_seen      <= 1'b0;
                write_done_seen       <= 1'b0;
            end else begin
                // 忙的时候也只记 1 次"下/上一张"请求，不会累积成连跳两张
                if (key_next_press && scan_done && (img_found_count > 3'd0))
                    next_req_pending <= 1'b1;
                if (key_prev_press && scan_done && (img_found_count > 3'd0))
                    prev_req_pending <= 1'b1;

                // 自动轮播：KEY2 按下沿 toggle 开/关（瞬时按键）
                //   手动切图(KEY1下一张/KEY0上一张)即退出轮播（双保险）；不足 2 张强制关闭
                if (scan_done) begin
                    if (key_auto_press && (img_found_count > 3'd1))
                        auto_play_en <= ~auto_play_en;
                    if (key_next_press || key_prev_press)
                        auto_play_en <= 1'b0;
                    if (img_found_count <= 3'd1)
                        auto_play_en <= 1'b0;
                end

                // 自动播放 1s 计数：只有当前没有写图任务时才计时
                if (scan_done && auto_play_en && display_valid && !load_busy && first_image_committed && (img_found_count > 3'd1)) begin
                    if (auto_tick)
                        auto_cnt <= 32'd0;
                    else
                        auto_cnt <= auto_cnt + 32'd1;
                end else begin
                    auto_cnt <= 32'd0;
                end

                // 首图自动加载到 buffer0
                if (scan_done && !first_image_committed && bmp_ready && !load_busy && (img_found_count != 3'd0)) begin
                    load_idx         <= 2'd0;
                    load_sector      <= img_sector0;
                    pending_buf_idx  <= 2'd0;
                    write_buf_idx    <= 2'd0;
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    next_req_pending <= 1'b0;
                    prev_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 手动下一张优先：写到“非当前显示”的另一块 buffer
                else if (scan_done && bmp_ready && display_valid && !load_busy && next_req_pending && (img_found_count != 3'd0)) begin
                    load_idx         <= next_from_current;
                    load_sector      <= sector_lut(next_from_current);
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    next_req_pending <= 1'b0;
                    prev_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 手动上一张：同样写到“非当前显示”的另一块 buffer
                else if (scan_done && bmp_ready && display_valid && !load_busy && prev_req_pending && (img_found_count != 3'd0)) begin
                    load_idx         <= prev_from_current;
                    load_sector      <= sector_lut(prev_from_current);
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    next_req_pending <= 1'b0;
                    prev_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 自动播放下一张：同样写到“非当前显示”的另一块 buffer
                else if (scan_done && bmp_ready && display_valid && !load_busy && auto_play_en && auto_tick && (img_found_count > 3'd1)) begin
                    load_idx         <= next_from_current;
                    load_sector      <= sector_lut(next_from_current);
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
            end
        end
    end
end

bmp_read bmp_read_m0(
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (bmp_ready),

    .scan_start             (scan_start_pulse),
    .scan_start_sector      (SCAN_START_SECTOR),
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_done              (scan_done),
    .scan_found_valid       (scan_found_valid),
    .scan_found_sector      (scan_found_sector),
    .scan_found_total       (scan_found_total),

    .load_start             (load_start_pulse),
    .load_abort             (load_abort),
    .load_sector            (load_sector),

    .sd_init_done           (sd_init_done),
    .state_code             (state_code_i),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack),
    .sd_sec_read            (bmp_sec_req),
    .sd_sec_read_addr       (bmp_sec_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (bmp_sec_dv),
    .sd_sec_read_end        (bmp_sec_end),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data),
    .bmp_is_1280            (bmp_is_1280)
);

sd_card_top sd_card_top_m0(
    .clk                    (clk),
    .rst                    (sd_rst),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (sd_sec_read_arb),
    .sd_sec_read_addr       (sd_sec_read_addr_arb),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

//============================================================================
// v7: WAV 音频 (TF 卡流式读取)
//   bmp_read 与 wav_player 经仲裁器复用 sd_card_top 单扇区读接口;
//   wav 数据 4 字节组帧写入异步 FIFO (32bit x 1024, clkw=100M/clkr=video_clk)
//============================================================================

// ---- SD 初始化失败自动重试看门狗 ----
//   官方初始化 FSM 在 CMD0 无响应时无限重发(无超时退出), SD 卡上电闩锁/
//   SPI 无响应时 sd_init_done 永不拉高。此处每 2s 自动脉冲复位 sd_card_top,
//   重新走一遍完整初始化(带空闲期+CMD0 复位), 给卡恢复机会。
assign sd_init_status = sd_init_done;

reg [31:0] sd_rst_cnt;
reg [1:0]  sd_rst_pulse;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        sd_rst_cnt   <= 32'd0;
        sd_rst_pulse <= 2'd0;
    end else begin
        sd_rst_pulse <= (sd_rst_pulse != 2'd0) ? (sd_rst_pulse - 2'd1) : 2'd0;
        if (sd_init_done) begin
            sd_rst_cnt <= 32'd0;
        end else if (sd_rst_cnt >= 32'd200_000_000) begin  // 2s @100MHz
            sd_rst_cnt   <= 32'd0;
            sd_rst_pulse <= 2'b11;                          // 2 拍复位脉冲
        end else begin
            sd_rst_cnt <= sd_rst_cnt + 32'd1;
        end
    end
end
assign sd_rst = rst | (sd_rst_pulse != 2'd0);

// ---- 仲裁器信号 ----
localparam GRANT_NONE = 2'd0;
localparam GRANT_BMP  = 2'd1;
localparam GRANT_WAV  = 2'd2;

reg [1:0] grant;
reg       end_seen;

wire        wav_sec_req;
wire [31:0] wav_sec_addr;
wire        wav_sec_dv;
wire        wav_sec_end;

wire owner_req   = (grant == GRANT_WAV) ? wav_sec_req : bmp_sec_req;
wire [31:0] owner_addr = (grant == GRANT_WAV) ? wav_sec_addr : bmp_sec_addr;

assign sd_sec_read_arb      = (grant != GRANT_NONE) ? owner_req : 1'b0;
assign sd_sec_read_addr_arb = owner_addr;

// data/end 按 owner 门控后分别回送, 防止误吞对方扇区数据
assign bmp_sec_dv = sd_sec_read_data_valid && (grant == GRANT_BMP);
assign bmp_sec_end = sd_sec_read_end && (grant == GRANT_BMP);
assign wav_sec_dv = sd_sec_read_data_valid && (grant == GRANT_WAV);
assign wav_sec_end = sd_sec_read_end && (grant == GRANT_WAV);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        grant    <= GRANT_NONE;
        end_seen <= 1'b0;
    end else if (end_seen) begin
        // 事务结束后的重评估拍: 按扇区原子切换, wav 优先
        end_seen <= 1'b0;
        case (grant)
            GRANT_WAV: begin
                if (wav_sec_req)      grant <= GRANT_WAV;   // 音频连续流
                else if (bmp_sec_req) grant <= GRANT_BMP;
                else                  grant <= GRANT_NONE;
            end
            GRANT_BMP: begin
                if (wav_sec_req)      grant <= GRANT_WAV;   // 音频抢占
                else if (bmp_sec_req) grant <= GRANT_BMP;
                else                  grant <= GRANT_NONE;
            end
            default: grant <= GRANT_NONE;
        endcase
    end else if (sd_sec_read_end) begin
        end_seen <= 1'b1;           // 事务结束拍, owner 不变
    end else if (grant == GRANT_NONE) begin
        if (wav_sec_req)      grant <= GRANT_WAV;
        else if (bmp_sec_req) grant <= GRANT_BMP;
    end
end

// ---- WAV 扫描触发: SD 初始化后立即与 BMP 扫描并行启动 ----
//   FIFO 在首图显示前预填满, display_valid 拉高瞬间音频即从文件头出声(音画同步)
wire wav_scan_start;
reg  wav_scan_started;
assign wav_scan_start = sd_init_done && !wav_scan_started && !wav_found;
always @(posedge clk or posedge rst) begin
    if (rst)
        wav_scan_started <= 1'b0;
    else if (!sd_init_done)
        wav_scan_started <= 1'b0;
    else if (wav_scan_start)
        wav_scan_started <= 1'b1;
end

// ---- WAV 流式读取器 ----
wire        wav_fifo_we;
wire [31:0] wav_fifo_di;
wire [9:0]  wav_fifo_wrusedw;
wire [9:0]  wav_fifo_rdusedw;
wire [31:0] wav_fifo_dout;
wire        wav_fifo_empty;

wav_player #(
    .WAV_SCAN_START (32'd15424),
    .WAV_SCAN_MAX   (32'd131071),
    .FIFO_WR_THRESH (10'd880)
) u_wav_player (
    .clk            (clk),
    .rst            (rst),
    .sd_init_done   (sd_init_done),
    .scan_start     (wav_scan_start),
    .wav_req        (wav_sec_req),
    .wav_addr       (wav_sec_addr),
    .sec_data       (sd_sec_read_data),
    .sec_data_valid (wav_sec_dv),
    .sec_end        (wav_sec_end),
    .fifo_wrusedw   (wav_fifo_wrusedw),
    .wav_fifo_we    (wav_fifo_we),
    .wav_fifo_di    (wav_fifo_di),
    .wav_found      (wav_found),
    .wav_playing    (wav_playing),
    .wav_state_code ()
);

// ---- 音频异步 FIFO: 32bit x 1024, 100MHz 写 / video_clk 读 ----
//   深度 1024 ≈ 21ms 缓冲(足够覆盖仲裁抢占往返), 减小音画同步滞后
wfifo_32_32_512 #(
    .DATA_WIDTH_W (32),
    .DATA_WIDTH_R (32),
    .ADDR_WIDTH_W (10),
    .ADDR_WIDTH_R (10),
    .AL_FULL_NUM  (1000),
    .AL_EMPTY_NUM (2),
    .SHOW_AHEAD_EN (1'b1),
    .OUTREG_EN    ("NOREG")
) u_audio_fifo (
    .rst         (rst),
    .clkw        (clk),
    .clkr        (fifo_rclk),
    .we          (wav_fifo_we),
    .di          (wav_fifo_di),
    .re          (wav_fifo_re),
    .dout        (wav_fifo_dout),
    .valid       (),
    .full_flag   (),
    .empty_flag  (wav_fifo_empty),
    .afull       (),
    .aempty      (),
    .wrusedw     (wav_fifo_wrusedw),
    .rdusedw     (wav_fifo_rdusedw)
);

endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse,  // 按下沿脉冲
    output reg  button_out    // 消抖后稳定电平
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
reg [31:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
        button_out    <= 1'b1;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;
        button_out   <= button_stable;

        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule
