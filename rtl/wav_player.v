`timescale 1ns / 1ps
//============================================================================
// 模块名称 : wav_player
// 功能描述 : TF 卡 WAV (RIFF/WAVE, PCM 48000Hz/16bit/双声道) 定位 + 流式读取
//             扫描: 从 WAV_SCAN_START 起逐扇区找 "RIFF"+"WAVE", 校验 fmt/data chunk
//             流式: 按 data 偏移顺序读扇区, 4 字节组装 1 个 32bit 立体声帧写 FIFO
//             播完自动无缝循环 (FIFO 85ms 缓冲兜底)
//  与 bmp_read 共用 sd_card_top 单扇区读接口 (本模块为 sd_card_bmp 内仲裁器的
//  wav 侧 master; sec_data_valid/sec_end 由仲裁器按 grant 门控后送入本模块)
// 时钟域 : sd_card_clk = 100MHz
//============================================================================
module wav_player #(
    parameter [31:0] WAV_SCAN_START = 32'd15424,   // BMP 4 张之后固定放 WAV 的起始扇区
    parameter [31:0] WAV_SCAN_MAX   = 32'd131071,  // 扫描上限 (前 64MB)
    parameter [9:0]  FIFO_WR_THRESH = 10'd880      // FIFO 写侧高水位 (1024 深, 留余量防溢出)
)(
    input               clk,              // sd_card_clk 100MHz
    input               rst,              // 高有效异步复位
    input               sd_init_done,
    input               scan_start,       // 扫描启动电平 (SD 初始化后由 sd_card_bmp 并行触发)

    output reg          wav_req,          // 电平读请求 (仲裁器 wav 侧)
    output reg [31:0]   wav_addr,         // 读扇区地址 (请求期间保持稳定)

    input  [7:0]        sec_data,         // 仲裁器门控后的数据字节
    input               sec_data_valid,   // 门控后数据有效 (每字节一拍)
    input               sec_end,          // 门控后扇区结束脉冲

    input  [9:0]        fifo_wrusedw,     // 音频 FIFO 写侧水位
    output reg          wav_fifo_we,      // FIFO 写使能 (每 4 字节一拍)
    output reg [31:0]   wav_fifo_di,      // FIFO 写数据 {R_hi,R_lo,L_hi,L_lo}

    output reg          wav_found,        // 已定位 WAV
    output reg          wav_playing,      // 正在流式播放
    output reg [3:0]    wav_state_code    // 调试: 0=IDLE 1=SCAN 2=PLAY 3=PAUSE
);

localparam W_IDLE = 4'd0;
localparam W_SCAN = 4'd1;
localparam W_PLAY = 4'd2;
localparam W_PAUSE= 4'd3;

reg [3:0]  state;

reg [31:0] scan_sector;      // 扫描当前扇区
reg [9:0]  sec_byte_cnt;     // 当前扇区字节计数 0..513 (CRC 字节 ≥512)

// ---- 扫描解析寄存器 ----
reg        scan_active;      // 本扇区已确认 "R" 开头, 正在解析
reg        riff_ok;          // 0..3 == "RIFF"
reg        wave_ok;          // 8..11 == "WAVE"
reg        fmt_ok;           // fmt: PCM/2ch/48000/16bit
reg        data_ok;          // 已定位 data chunk
reg [31:0] riff_size;        // RIFF 文件长度字段
reg [31:0] ch_id;            // 当前 chunk id (MSB 先收, 可直接 == "fmt " / "data")
reg [31:0] ch_sz;            // 当前 chunk size (LSB 先收, 小端数值)
reg [1:0]  ch_cnt;           // 当前 id/size 第几个字节 0..3
reg        ch_sz_phase;      // 0=收 id, 1=收 size
reg        in_pay;           // 正在跳过 chunk payload
reg [31:0] pay_left;         // payload 剩余跳过字节 (已含奇数对齐)
reg [15:0] fmt_tag;          // format tag
reg [15:0] fmt_ch;           // channels
reg [31:0] fmt_rate;         // sample rate
reg [15:0] fmt_bits;         // bits per sample
reg [31:0] data_ofs;         // data payload 起始文件偏移
reg [31:0] data_len;         // data 长度
// data_len 兜底 (组合): size 为 0/0xFFFFFFFF 时用 riff_size 推算
wire [31:0] data_len_eff = ((data_len == 32'd0) || (data_len == 32'hFFFFFFFF)) ?
                           ((riff_size >= (data_ofs - 32'd8)) ?
                            (riff_size - (data_ofs - 32'd8)) : 32'd0) : data_len;
// 打一拍寄存: 规避 sec_end 判定时刻的过长组合链 (data_len/使能路径时序收敛)
reg [31:0] data_len_eff_q;
reg        wav_found_pre;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        data_len_eff_q <= 32'd0;
        wav_found_pre  <= 1'b0;
    end else begin
        data_len_eff_q <= data_len_eff;
        wav_found_pre  <= riff_ok && wave_ok && fmt_ok && data_ok;
    end
end

// ---- 流式读取寄存器 ----
reg [31:0] wav_base_sector;  // WAV 文件起始扇区 (RIFF 头所在 LBA)
reg [31:0] play_sector;      // 当前读扇区 (绝对 LBA)
reg        first_sector;     // 处于 data 首扇区 (需跳过头字节)
reg [9:0]  skip_off;         // data 偏移在首扇区内的字节位置
reg [31:0] remain_cnt;       // 剩余待读 payload 字节数
reg [31:0] word_buf;         // 立体声帧组装缓冲
reg [1:0]  wb;               // 帧内字节计数 0..3

//============================================================================
// 字节计数: 扫描/播放期间对门控后数据逐字节计数, 扇区结束清零
//============================================================================
always @(posedge clk or posedge rst) begin
    if (rst)
        sec_byte_cnt <= 10'd0;
    else if (sec_end)
        sec_byte_cnt <= 10'd0;
    else if (sec_data_valid && (state == W_SCAN || state == W_PLAY))
        sec_byte_cnt <= sec_byte_cnt + 10'd1;
end

//============================================================================
// 主状态机
//============================================================================
always @(posedge clk or posedge rst) begin
    if (rst) begin
        state          <= W_IDLE;
        wav_req        <= 1'b0;
        wav_addr       <= 32'd0;
        wav_fifo_we    <= 1'b0;
        wav_fifo_di    <= 32'd0;
        wav_found      <= 1'b0;
        wav_playing    <= 1'b0;
        wav_state_code <= W_IDLE;

        scan_sector    <= WAV_SCAN_START;
        scan_active    <= 1'b0;
        riff_ok        <= 1'b0;
        wave_ok        <= 1'b0;
        fmt_ok         <= 1'b0;
        data_ok        <= 1'b0;
        riff_size      <= 32'd0;
        ch_id          <= 32'd0;
        ch_sz          <= 32'd0;
        ch_cnt         <= 2'd0;
        ch_sz_phase    <= 1'b0;
        in_pay         <= 1'b0;
        pay_left       <= 32'd0;
        fmt_tag        <= 16'd0;
        fmt_ch         <= 16'd0;
        fmt_rate       <= 32'd0;
        fmt_bits       <= 16'd0;
        data_ofs       <= 32'd0;
        data_len       <= 32'd0;

        play_sector    <= 32'd0;
        wav_base_sector <= 32'd0;
        first_sector   <= 1'b0;
        skip_off       <= 10'd0;
        remain_cnt     <= 32'd0;
        word_buf       <= 32'd0;
        wb             <= 2'd0;
    end else begin
        // 默认清脉冲类输出
        wav_fifo_we <= 1'b0;

        case (state)
            //---------------------------------------------------------- IDLE
            W_IDLE: begin
                wav_state_code <= W_IDLE;
                wav_playing    <= 1'b0;
                wav_req        <= 1'b0;
                if (sd_init_done && scan_start && !wav_found) begin
                    scan_sector <= WAV_SCAN_START;
                    wav_addr    <= WAV_SCAN_START;
                    wav_req     <= 1'b1;
                    state       <= W_SCAN;
                end
            end

            //---------------------------------------------------------- SCAN
            W_SCAN: begin
                wav_state_code <= W_SCAN;
                wav_playing    <= 1'b0;
                wav_req        <= 1'b1;          // 扫描连续请求

                // ---- 逐字节解析 (仅数据区字节 0..511) ----
                if (sec_data_valid && (sec_byte_cnt < 10'd512)) begin
                    if (sec_byte_cnt == 10'd0) begin
                        // 扇区第 0 字节必须为 'R'(0x52) 才进入 RIFF 解析
                        if (sec_data == 8'h52) begin
                            scan_active <= 1'b1;
                            riff_ok     <= 1'b0;
                            wave_ok     <= 1'b0;
                            fmt_ok      <= 1'b0;
                            data_ok     <= 1'b0;
                            ch_id       <= 32'd0;
                            ch_sz       <= 32'd0;
                            ch_cnt      <= 2'd0;
                            ch_sz_phase <= 1'b0;
                            in_pay      <= 1'b0;
                            pay_left    <= 32'd0;
                            fmt_tag     <= 16'd0;
                            fmt_ch      <= 16'd0;
                            fmt_rate    <= 32'd0;
                            fmt_bits    <= 16'd0;
                            data_ofs    <= 32'd0;
                            data_len    <= 32'd0;
                        end else begin
                            scan_active <= 1'b0;
                        end
                    end else if (scan_active) begin
                        case (sec_byte_cnt)
                            // RIFF 标识 (0..3)
                            10'd1: if (sec_data != 8'h49) scan_active <= 1'b0;   // 'I'
                            10'd2: if (sec_data != 8'h46) scan_active <= 1'b0;   // 'F'
                            10'd3: begin
                                       if (sec_data != 8'h46) scan_active <= 1'b0; // 'F'
                                       else riff_ok <= 1'b1;
                                   end
                            // RIFF 文件长度 (4..7, 小端)
                            10'd4: riff_size[7:0]   <= sec_data;
                            10'd5: riff_size[15:8]  <= sec_data;
                            10'd6: riff_size[23:16] <= sec_data;
                            10'd7: riff_size[31:24] <= sec_data;
                            // WAVE 标识 (8..11)
                            10'd8: if (sec_data != 8'h57) scan_active <= 1'b0;   // 'W'
                            10'd9: if (sec_data != 8'h41) scan_active <= 1'b0;   // 'A'
                            10'd10: if (sec_data != 8'h56) scan_active <= 1'b0;  // 'V'
                            10'd11: begin
                                        if (sec_data != 8'h45) scan_active <= 1'b0; // 'E'
                                        else wave_ok <= 1'b1;
                                    end
                            // chunk 游走 (≥12)
                            default: begin
                                if (!in_pay) begin
                                    if (!ch_sz_phase) begin
                                        // 收集 chunk id (MSB 先收)
                                        case (ch_cnt)
                                            2'd0: ch_id[31:24] <= sec_data;
                                            2'd1: ch_id[23:16] <= sec_data;
                                            2'd2: ch_id[15:8]  <= sec_data;
                                            default: begin
                                                ch_id[7:0] <= sec_data;
                                                ch_sz     <= 32'd0;
                                                ch_cnt    <= 2'd0;
                                                ch_sz_phase <= 1'b1;
                                            end
                                        endcase
                                        if (ch_cnt < 2'd3)
                                            ch_cnt <= ch_cnt + 2'd1;
                                    end else begin
                                        // 收集 chunk size (小端)
                                        case (ch_cnt)
                                            2'd0: ch_sz[7:0]   <= sec_data;
                                            2'd1: ch_sz[15:8]  <= sec_data;
                                            2'd2: ch_sz[23:16] <= sec_data;
                                            default: begin
                                                ch_sz[31:24] <= sec_data;
                                                if (ch_id == "fmt ") begin
                                                    fmt_ok <= 1'b0;
                                                    fmt_tag <= 16'd0;
                                                    fmt_ch  <= 16'd0;
                                                    fmt_rate <= 32'd0;
                                                    fmt_bits <= 16'd0;
                                                end else if (ch_id == "data") begin
                                                    // 该 chunk 头起始 = 当前位置-7, payload 起始 = +8
                                                    data_ofs <= sec_byte_cnt + 10'd1;
                                                    data_len <= {sec_data, ch_sz[23:0]}; // 小端完整 size
                                                    data_ok  <= 1'b1;
                                                end
                                                ch_cnt      <= 2'd0;
                                                ch_sz_phase <= 1'b0;
                                                in_pay      <= 1'b1;
                                                pay_left    <= {sec_data, ch_sz[23:0]} + ({sec_data, ch_sz[23:0]} & 32'h1); // 完整 size + 奇数对齐
                                            end
                                        endcase
                                        if (ch_cnt < 2'd3)
                                            ch_cnt <= ch_cnt + 2'd1;
                                    end
                                end else begin
                                    // 跳过 payload, 同时采集 fmt 字段
                                    if (ch_id == "fmt ") begin
                                        case (16'd16 - pay_left[4:0])
                                            5'd0: fmt_tag[7:0]   <= sec_data;
                                            5'd1: fmt_tag[15:8]  <= sec_data;
                                            5'd2: fmt_ch[7:0]    <= sec_data;
                                            5'd3: fmt_ch[15:8]   <= sec_data;
                                            5'd4: fmt_rate[7:0]  <= sec_data;
                                            5'd5: fmt_rate[15:8] <= sec_data;
                                            5'd6: fmt_rate[23:16] <= sec_data;
                                            5'd7: fmt_rate[31:24] <= sec_data;
                                            5'd14: fmt_bits[7:0] <= sec_data;
                                            5'd15: begin
                                                fmt_bits[15:8] <= sec_data;
                                                fmt_ok <= 1'b1;
                                            end
                                            default: ;
                                        endcase
                                    end
                                    if (pay_left <= 32'd1)
                                        in_pay <= 1'b0;            // 下一字节为下一 chunk 头
                                    pay_left <= pay_left - 32'd1;
                                end
                            end
                        endcase
                    end
                end

                // ---- 扇区结束: 评估结果 ----
                if (sec_end) begin
                    wav_req <= 1'b0;            // 让出 1 拍 (公平性)
                    if (wav_found_pre) begin
                        wav_found    <= 1'b1;
                        wav_base_sector <= scan_sector;
                        play_sector  <= scan_sector + data_ofs[31:9];
                        skip_off     <= data_ofs[9:0];
                        first_sector <= 1'b1;
                        data_len     <= data_len_eff_q;                   // 打一拍后的有效长度
                        remain_cnt   <= data_len_eff_q & 32'hFFFFFFFC;    // 4 字节对齐
                        wb           <= 2'd0;
                        word_buf     <= 32'd0;
                        wav_addr     <= scan_sector + data_ofs[31:9];
                        state        <= W_PLAY;
                    end else if (scan_sector >= WAV_SCAN_MAX) begin
                        state <= W_IDLE;        // 未找到, 回 IDLE 允许重扫
                    end else begin
                        scan_sector <= scan_sector + 32'd1;
                        wav_addr    <= scan_sector + 32'd1;
                    end
                end

                if (!sd_init_done)
                    state <= W_IDLE;
            end

            //---------------------------------------------------------- PLAY
            W_PLAY: begin
                wav_state_code <= W_PLAY;
                wav_playing    <= 1'b1;

                // 水位门控: 需要数据且 FIFO 未满才请求
                if (!wav_req && (remain_cnt != 32'd0) &&
                    (fifo_wrusedw < FIFO_WR_THRESH) && !sec_end)
                    wav_req <= 1'b1;

                // ---- 数据组装 ----
                if (sec_data_valid && (sec_byte_cnt < 10'd512) && (remain_cnt != 32'd0)) begin
                    if (first_sector && (sec_byte_cnt < skip_off)) begin
                        // 首扇区跳过 data 偏移之前的头字节
                    end else begin
                        case (wb)
                            2'd0: begin
                                word_buf[7:0] <= sec_data;
                                wb <= 2'd1;
                            end
                            2'd1: begin
                                word_buf[15:8] <= sec_data;
                                wb <= 2'd2;
                            end
                            2'd2: begin
                                word_buf[23:16] <= sec_data;
                                wb <= 2'd3;
                            end
                            default: begin
                                word_buf[31:24] <= sec_data;
                                wav_fifo_di <= {sec_data, word_buf[23:0]};
                                wav_fifo_we <= 1'b1;      // 第 4 字节完成一帧
                                wb <= 2'd0;
                            end
                        endcase
                        remain_cnt <= remain_cnt - 32'd1;
                    end
                end

                // ---- 扇区结束: 推进 / 循环 / 暂停 ----
                if (sec_end) begin
                    wav_fifo_we <= 1'b0;
                    wb          <= 2'd0;
                    wav_req     <= 1'b0;
                    if (remain_cnt != 32'd0) begin
                        play_sector  <= play_sector + 32'd1;
                        first_sector <= 1'b0;
                        wav_addr     <= play_sector + 32'd1;
                    end else begin
                        play_sector  <= wav_base_sector + data_ofs[31:9];   // 无缝循环
                        first_sector <= 1'b1;
                        remain_cnt   <= data_len & 32'hFFFFFFFC;
                        wav_addr     <= wav_base_sector + data_ofs[31:9];
                    end
                    if (fifo_wrusedw >= FIFO_WR_THRESH)
                        state <= W_PAUSE;                 // FIFO 满, 等水位下降
                end

                if (!sd_init_done)
                    state <= W_IDLE;
            end

            //--------------------------------------------------------- PAUSE
            W_PAUSE: begin
                wav_state_code <= W_PAUSE;
                wav_playing    <= 1'b1;
                wav_req        <= 1'b0;
                if (fifo_wrusedw < FIFO_WR_THRESH)
                    state <= W_PLAY;
                if (!sd_init_done)
                    state <= W_IDLE;
            end

            default: begin
                state          <= W_IDLE;
                wav_state_code <= W_IDLE;
                wav_req        <= 1'b0;
                wav_playing    <= 1'b0;
            end
        endcase
    end
end

endmodule
