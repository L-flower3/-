`timescale 1ns / 1ps
//============================================================================
// 模块名称 : wav_audio_out
// 功能描述 : 音频 FIFO 读侧 + 精确 48kHz 采样率生成 + 16bit->24bit 扩展
//            - 520/521 循环分数分频: video_clk=25MHz 下每 6 帧 = 5*521+1*520
//              = 3125 周期, 平均 25000000/3125*6 = 48000.0 Hz (精确)
//            - 每个 fs_tick 读 1 个 32bit 立体声帧 (FIFO 空则补零静音,
//              但 valid 节奏不断, 保证 ACR/时钟再生稳定)
//            - 16bit 样本左移 8 位扩展为 24bit 送入 HDMI 核
//            - display_valid 同步门控: 首图提交前不消耗 FIFO (出声即从头)
// 时钟域 : video_clk = 25MHz
//============================================================================
module wav_audio_out (
    input            video_clk,
    input            rst,             // 高有效异步复位
    input            display_valid,   // 音画同步门控

    input  [31:0]    fifo_dout,       // FIFO 读数据 (SHOW-AHEAD: 队头)
    input            fifo_empty,
    input  [9:0]     fifo_rdusedw,    // (调试, 未用)

    output reg       wav_fifo_re,     // FIFO 读使能 (每帧 1 拍)
    output reg       audio_valid,     // 音频帧有效 (每帧 1 拍)
    output reg [23:0] audio_left_data,  // 24bit 左声道
    output reg [23:0] audio_right_data  // 24bit 右声道
);

//--------------------------------------------------------------------------
// 48kHz 分数分频: super_cnt 0..5, fs_limit = (super_cnt==5)? 520 : 521
//   每 6 帧总周期 = 5*521 + 1*520 = 3125 -> 25MHz/3125*6 = 48000Hz
//--------------------------------------------------------------------------
reg [2:0] super_cnt;   // 0..5
reg [9:0] fs_cnt;      // 帧内周期计数
wire [9:0] fs_limit = (super_cnt == 3'd5) ? 10'd520 : 10'd521;
wire fs_tick = (fs_cnt >= (fs_limit - 10'd1));

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        super_cnt <= 3'd0;
        fs_cnt    <= 10'd0;
    end else if (fs_tick) begin
        fs_cnt    <= 10'd0;
        super_cnt <= (super_cnt == 3'd5) ? 3'd0 : super_cnt + 3'd1;
    end else begin
        fs_cnt <= fs_cnt + 10'd1;
    end
end

//--------------------------------------------------------------------------
// display_valid 两级同步 (准静态信号)
//--------------------------------------------------------------------------
reg [1:0] dv_sync;
always @(posedge video_clk or posedge rst) begin
    if (rst)
        dv_sync <= 2'b00;
    else
        dv_sync <= {dv_sync[0], display_valid};
end
wire audio_en = dv_sync[1];

//--------------------------------------------------------------------------
// 音频输出: 每个 fs_tick 产生 1 拍 valid; 有数据则弹出并输出, 无则补零
//--------------------------------------------------------------------------
always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        wav_fifo_re     <= 1'b0;
        audio_valid     <= 1'b0;
        audio_left_data <= 24'd0;
        audio_right_data <= 24'd0;
    end else if (fs_tick) begin
        audio_valid <= 1'b1;
        if (audio_en && !fifo_empty) begin
            wav_fifo_re     <= 1'b1;
            audio_left_data <= {fifo_dout[15:0], 8'b0};   // 16bit 左移 8 扩 24bit
            audio_right_data <= {fifo_dout[31:16], 8'b0};
        end else begin
            wav_fifo_re     <= 1'b0;
            audio_left_data <= 24'd0;
            audio_right_data <= 24'd0;
        end
    end else begin
        audio_valid     <= 1'b0;
        wav_fifo_re     <= 1'b0;
        audio_left_data <= audio_left_data;    // 帧间保持, 核在 valid 拍采样
        audio_right_data <= audio_right_data;
    end
end

endmodule
