`timescale 1ns / 1ps
//============================================================================
// 模块名称 : seg4_scan
// 功能描述 : 4位共阴数码管动态扫描（M0底板）
//            位选低有效：seg_sel[0]=C9最右 ... seg_sel[3]=A3最左
//            段选高有效：seg_led[0]=a ... [6]=g, [7]=dp
//            扫描频率：每位2.5kHz，刷新1kHz
//============================================================================
module seg4_scan (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] disp3,     // 最左位段码
    input  wire [7:0] disp2,
    input  wire [7:0] disp1,
    input  wire [7:0] disp0,     // 最右位段码
    output reg  [3:0] seg_sel,
    output reg  [7:0] seg_led
);

reg [13:0] scan_cnt;
always @(posedge clk or negedge rst_n)
    if (!rst_n)        scan_cnt <= 14'd0;
    else if (scan_cnt >= 14'd12499) scan_cnt <= 14'd0;
    else               scan_cnt <= scan_cnt + 14'd1;

reg [1:0] phase;
always @(posedge clk or negedge rst_n)
    if (!rst_n) phase <= 2'd0;
    else begin
        case (scan_cnt)
            14'd3124:  phase <= 2'd1;
            14'd6249:  phase <= 2'd2;
            14'd9374:  phase <= 2'd3;
            14'd12499: phase <= 2'd0;
            default:   phase <= phase;
        endcase
    end

always @(*) begin
    case (phase)
        2'd0: begin seg_sel = 4'b1110; seg_led = disp0; end  // 最右
        2'd1: begin seg_sel = 4'b1101; seg_led = disp1; end
        2'd2: begin seg_sel = 4'b1011; seg_led = disp2; end
        2'd3: begin seg_sel = 4'b0111; seg_led = disp3; end  // 最左
        default: begin seg_sel = 4'b1111; seg_led = 8'h00; end
    endcase
end

endmodule
