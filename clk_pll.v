/************************************************************\
 **     Copyright (c) 2012-2024 Anlogic Inc.
 **  All Right Reserved.\
\************************************************************/
/************************************************************\
 ** 基于官方 sys_pll（spi_FLASH_SDRAM_pic / lab_ex4_tf）改写
 ** 模块名/端口与 M0 例程 clk_pll 保持一致，顶层无需改动
\************************************************************/

///////////////////////////////////////////////////////////////////////////////
//	Input frequency:               50.000000MHz
//	Clock multiplication factor: 2
//	Clock division factor:       1
//	Clock information:
//		Clock name	| Frequency 	| Phase shift
//		C0        	| 100.000000MHZ	| 0.0000  DEG    (sd_card_clk / write_clk)
//		C1        	| 100.000000MHZ	| 0.0000  DEG    (SDRAM 用户时钟)
//		C2        	| 100.000000MHZ	| 180.0000 DEG   (SDRAM 移相时钟)
//  说明：SDRAM 选 100MHz 而非 125/150MHz，为帧FIFO读侧控制逻辑
//       留出充足建立时间裕量；带宽 100M x 32bit 远超显示需求。
///////////////////////////////////////////////////////////////////////////////
`timescale 1 ns / 100 fs

module clk_pll (
  refclk,
  reset,
  extlock,
  clk0_out,
  clk1_out,
  clk2_out 
);

  input refclk;
  input reset;
  output extlock;
  output clk0_out;
  output clk1_out;
  output clk2_out;

  wire clk0_buf;

  EG_LOGIC_BUFG bufg_feedback (
    .i(clk0_buf),
    .o(clk0_out) 
  );

  EG_PHY_PLL #(
    .DPHASE_SOURCE("DISABLE"),
    .DYNCFG("DISABLE"),
    .FIN("50.000000"),
    .FEEDBK_MODE("NORMAL"),
    .FEEDBK_PATH("CLKC0_EXT"),
    .STDBY_ENABLE("DISABLE"),
    .PLLRST_ENA("ENABLE"),
    .SYNC_ENABLE("DISABLE"),
    .GMC_GAIN(4),
    .ICP_CURRENT(29),
    .KVCO(4),
    .LPF_CAPACITOR(1),
    .LPF_RESISTOR(2),
    .REFCLK_DIV(1),
    .FBCLK_DIV(2),
    .CLKC0_ENABLE("ENABLE"),
    .CLKC0_DIV(10),
    .CLKC0_CPHASE(9),
    .CLKC0_FPHASE(0),
    .CLKC1_ENABLE("ENABLE"),
    .CLKC1_DIV(10),
    .CLKC1_CPHASE(9),
    .CLKC1_FPHASE(0),
    .CLKC2_ENABLE("ENABLE"),
    .CLKC2_DIV(10),
    .CLKC2_CPHASE(4),
    .CLKC2_FPHASE(0) 
  ) pll_inst (
    .refclk(refclk),
    .reset(reset),
    .stdby(1'b0),
    .extlock(extlock),
    .load_reg(1'b0),
    .psclk(1'b0),
    .psdown(1'b0),
    .psstep(1'b0),
    .psclksel(3'b000),
    .psdone(open),
    .dclk(1'b0),
    .dcs(1'b0),
    .dwe(1'b0),
    .di(8'b00000000),
    .daddr(6'b000000),
    .do({open, open, open, open, open, open, open, open}),
    .fbclk(clk0_out),
    .clkc({open, open, clk2_out, clk1_out, clk0_buf}) 
  );

endmodule