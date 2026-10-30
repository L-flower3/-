`timescale 1ns/1ps
module frame_fifo_read
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter ADDR_BITS              = 21,
	parameter BURST_BITS             = 9,
	parameter FIFO_DEPTH             = 512,
	parameter BURST_SIZE             = 128
)               
(
	input                            rst,                  
	input                            mem_clk,                    // external memory controller user interface clock
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
    input							 Sdr_busy,
    input							 Sdr_rd_en,
	input							 App_wr_busy,
    output							 O_rd_busy,
	/*
    output reg                       rd_burst_req,               // to external memory controller,send out a burst read request  
	output reg[BURST_BITS - 1:0]     rd_burst_len,               // to external memory controller,data length of the burst read request, not bytes 
	output reg[ADDR_BITS - 1:0]      rd_burst_addr,              // to external memory controller,base address of the burst read request
	input                            rd_burst_data_valid,        // from external memory controller,read request data valid    
	input                            rd_burst_finish,            // from external memory controller,burst read finish
	*/
	output 							 App_rd_en,
	output  [ADDR_BITS - 1:0]		 App_rd_addr,
	
	input                            read_req,                   // data read module read request,keep '1' until read_req_ack = '1'
	output reg                       read_req_ack,               // data read module read request response
	output                           read_finish,                // data read module read request finish
	input[ADDR_BITS - 1:0]           read_addr_0,                // data read module read request base address 0, used when read_addr_index = 0
	input[ADDR_BITS - 1:0]           read_addr_1,                // data read module read request base address 1, used when read_addr_index = 1
	input[ADDR_BITS - 1:0]           read_addr_2,                // data read module read request base address 1, used when read_addr_index = 2
	input[ADDR_BITS - 1:0]           read_addr_3,                // data read module read request base address 1, used when read_addr_index = 3
	input[1:0]                       read_addr_index,            // select valid base address from read_addr_0 read_addr_1 read_addr_2 read_addr_3
	input[ADDR_BITS - 1:0]           read_len,                   // data read module read request data length
	output reg                       fifo_aclr,                  // to fifo asynchronous clear
	input[9:0]                      wrusedw,                    // from fifo write used words
	//--------- 帧内行跳转 (滑动转场) ---------
	// 读到 seg_cnt 个字后, 把读地址直接置为 seg_addr, 之后继续线性递增。
	// 用于"跨两个相邻帧缓存"拼出一帧画面, 不占用额外带宽、不打断 FIFO。
	input                            seg_en,                     // 1: 启用跳转 (0 时行为与原始版本完全一致)
	input[18:0]                      seg_cnt,                    // 跳转点(已读字数, 恒>0)
	input[20:0]                      seg_addr,                   // 跳转目标地址
	//--------- 旋转擦除 (V34) ---------
	// 逐块(16 字 = 16 像素)选择本块读 BUF0 还是 BUF1, 不做帧内跳转。
	// 边界是"绕屏幕中心旋转的一条半径", 每一行的边界 x 随行号线性变化,
	// 所以只需要一个起点 wipe_x0 和一个每行增量 wipe_dx, 帧内累加即可。
	input                            wipe_en,                    // 1: 旋转擦除模式 (块粒度选帧)
	input[1:0]                       wipe_q,                     // 象限 0..3 (扫过 0/90/180/270 度)
	input signed [19:0]              wipe_x0,                    // 第 0 行的边界 x (Q12.4)
	input signed [11:0]              wipe_dx,                    // 每行边界增量 (Q.4)
	input                            wipe_dir,                   // 1=顺时针 0=逆时针(左右镜像)
	input                            wipe_new_idx,               // 新图帧索引 0/1
	input                            wipe_full                    // 1: 整屏已全部换成新图

);
localparam ONE                       = 256'd1;                   //256 bit '1'   you can use ONE[n-1:0] for n bit '1'
localparam ZERO                      = 256'd0;                   //256 bit '0'
//read state machine code
localparam S_IDLE                    = 0;                        //idle state,waiting for frame read
localparam S_ACK                     = 1;                        //read request response
localparam S_CHECK_FIFO              = 2;                        //check the FIFO status, ensure that there is enough space to burst read
localparam S_READ_BURST              = 3;                        //begin a burst read
localparam S_READ_BURST_END          = 4;                        //a burst read complete
localparam S_END                     = 5;                        //a frame of data is read to complete

reg                                  read_req_d0;                //asynchronous read request, synchronize to 'mem_clk' clock domain,first beat
reg                                  read_req_d1;                //second
reg                                  read_req_d2;                //third,Why do you need 3 ? Here's the design habit
reg[ADDR_BITS - 1:0]                 read_len_d0;                //asynchronous read_len(read data length), synchronize to 'mem_clk' clock domain first
reg[ADDR_BITS - 1:0]                 read_len_d1;                //second
reg[ADDR_BITS - 1:0]                 read_len_latch;             //lock read data length
reg[ADDR_BITS - 1:0]                 read_cnt;                   //read data counter
reg[3:0]                             state;                      //state machine
reg[1:0]                             read_addr_index_d0;         //synchronize to 'mem_clk' clock domain first
reg[1:0]                             read_addr_index_d1;         //synchronize to 'mem_clk' clock domain second
reg [ADDR_BITS - 1:0]	 App_rd_addr_r;

reg [BURST_BITS - 1:0]				burst_cnt;
wire								rd_burst_finish;
reg App_rd_en_r;
reg App_rd_en_d0;

//--------------------------------------------------------------------------
// wrusedw 打一拍 (V33)
//
//   加频谱之后布局变紧, 原来"够用"的这条路径变成了全片最差:
//     write_buf 里的跨时钟域同步 + 格雷码转二进制(5 级异或/加法)
//       -> wrusedw < FIFO_DEPTH-BURST_SIZE 比较
//       -> state / App_rd_en_r
//   实测 9.79ns / 10ns, slack -0.074ns, 2 个端点违例。
//
//   在这里打一拍, 路径被切成"纯布线"和"比较+状态"两段。
//   安全性: wrusedw 是异步 FIFO 的写侧水位, 本身就已经滞后若干拍,
//   再延后一拍对"FIFO 快满了就暂停取数"这个判断毫无影响
//   (深度 512, 阈值留了 BURST_SIZE 的余量, 一拍只差几个字)。
//--------------------------------------------------------------------------
reg [9:0] wrusedw_r;
always@(posedge mem_clk or posedge rst)
begin
	if(rst) wrusedw_r <= 10'd0;
	else    wrusedw_r <= wrusedw;
end

// 比较结果也寄存 (第二刀): 把 "10bit 比较 + 状态机分支" 再拆成两段。
// 状态机只看到一个 1bit 的 fifo_room, 次态路径只剩两三个 LUT。
// 累计延迟 2 拍 = 2 个字, 相对 256 字的阈值余量可以忽略。
reg fifo_room;
always@(posedge mem_clk or posedge rst)
begin
	if(rst) fifo_room <= 1'b0;
	else    fifo_room <= (wrusedw_r < (FIFO_DEPTH - BURST_SIZE));
end

//--------- 帧内行跳转 (滑动转场) ---------
reg[18:0]                            rd_word_cnt;   // 本帧已发出的读请求字数
reg                                  seg_en_l;      // S_ACK 时锁存, 帧内保持不变
reg[18:0]                            seg_cnt_l;
reg[20:0]                            seg_addr_l;
reg                                  seg_hit;       // 预判下一拍跳转 (把比较器移出地址路径)

always@(posedge mem_clk or posedge rst)
begin
	if(rst)
	begin
		rd_word_cnt <= 19'd0;
		seg_hit     <= 1'b0;
	end
	else if(state == S_ACK)
	begin
		rd_word_cnt <= 19'd0;
		seg_hit     <= 1'b0;
	end
	else if(App_rd_en)
	begin
		rd_word_cnt <= rd_word_cnt + 1'b1;
		// 下一拍字数 = rd_word_cnt+1, 提前一拍算好, 地址选择直接用寄存器结果
		seg_hit     <= seg_en_l && ((rd_word_cnt + 1'b1) == seg_cnt_l);
	end
end


//==========================================================================
// 旋转擦除 (V34)
//
//  为什么按"块"选帧, 而不是按像素:
//    本模块的地址序列必须与 FPS 的消费顺序(光栅顺序)逐字对齐, 所以只能
//    在"突发"边界上换源帧。把读突发从 128 字降到 16 字(即 16 像素)后,
//    旋转边界的横向量化误差只有 16px(2.5% 屏宽), 观感与连续边线一致,
//    而突发开销(BURST_SIZE + 10 个等待拍)仍远小于带宽需求:
//        16 字 / 约 28 拍  ->  约 55M 字/秒  >>  需要的 18.4M 字/秒
//
//  边界几何 (屏幕中心 320,240, 角度自 12 点方向顺时针量):
//    扇形区域 { 0 <= 角度 < S } 在任意一行上都是一段连续区间, 端点 x 随
//    行号线性变化, 因此只需 (起点, 每行增量), 不需要除法/LUT/查找表。
//      q0 (S<90)  : 上半屏 [320, xb), 下半屏空
//      q1/q2      : 上半屏 [320,639], 下半屏 [xb,639)
//      q3 (S<360) : 下半屏全满, 上半屏 [0,xb) U [320,639]
//    逆时针扫就是把 x 左右镜像, 所以只需对块坐标做一次 639-x 变换。
//==========================================================================
reg                                          wipe_l;        // 帧内锁存
reg [1:0]                                    wipe_q_l;
reg signed [19:0]                            wipe_x0_l;
reg signed [11:0]                            wipe_dx_l;
reg                                          wipe_dir_l;
reg                                          wipe_full_l;
reg [20:0]                                   base_new_l;
reg [20:0]                                   base_old_l;

// 块坐标(行 0..479, 列 0..39)
reg [8:0]                                    wb_row;
reg [5:0]                                    wb_col;
reg [20:0]                                   wb_off;        // row*640 + col*16, 每块 +16
reg signed [19:0]                            wb_acc;        // 边界累加 (Q.4)

wire [20:0] wipe_base_new = base_new_l;   // 新图帧缓存基址
wire [20:0] wipe_base_old = base_old_l;   // 旧图帧缓存基址

//---- 下一块的坐标 ----
//   wb_off 每块固定 +16: 行末 wb_off = row*640+624, +16 正好是下一行行首, 无需换行判断
wire [5:0]  wb_ncol  = (wb_col == 6'd39) ? 6'd0 : (wb_col + 6'd1);
wire [8:0]  wb_nrow  = (wb_col == 6'd39) ? (wb_row + 9'd1) : wb_row;
wire [20:0] wb_noff  = wb_off + 21'd16;
wire signed [19:0] wb_nacc = (wb_col == 6'd39) ? (wb_acc + wipe_dx_l) : wb_acc;
wire [9:0]  wb_npx   = {4'd0, wb_ncol, 4'd0};                  // 列块 * 16
wire [9:0]  wb_nctr  = wipe_dir_l ? (wb_npx + 10'd8) : (10'd631 - wb_npx);

//---- 边界值: 累加器取整并饱和到 [0,1023] (饱和后比较结果与原值等价) ----
//   ★ 逆时针扫只镜像"块坐标", 不镜像边界值本身:
//       R'(x) = R(639-x), 边界 xb 仍是屏幕坐标, 所以判据里用未镜像的 xb。
//     等价性: q3 顺时针的判据是 (x<xb)||(x>=320), 代入 x=639-xe 即得
//     (xe>639-xb)||(xe<=319) —— 正是顺时针区域的左右镜像。
wire [10:0] n_fx = (wb_nacc < 0) ? 11'd0 :
                   ((wb_nacc >>> 4) > 11'd1023 ? 11'd1023 : wb_nacc[14:4]);
wire [10:0] f_fx = (wipe_x0 < 0) ? 11'd0 :
                   ((wipe_x0 >>> 4) > 11'd1023 ? 11'd1023 : wipe_x0[14:4]);

reg n_use;
always @(*) begin
	if (wipe_full_l) n_use = 1'b1;
	else case (wipe_q_l)
		2'd0:    n_use = (wb_nrow < 9'd240) && (wb_nctr >= 10'd320) && ({1'b0,wb_nctr} < n_fx);
		2'd1:    n_use = (wb_nrow < 9'd240) ? (wb_nctr >= 10'd320) : ({1'b0,wb_nctr} >= n_fx);
		2'd2:    n_use = (wb_nrow < 9'd240) ? (wb_nctr >= 10'd320) : ({1'b0,wb_nctr} >= n_fx);
		2'd3:    n_use = (wb_nrow < 9'd240) ? ((wb_nctr >= 10'd320) || ({1'b0,wb_nctr} < n_fx)) : 1'b1;
		default: n_use = 1'b0;
	endcase
end

//--------------------------------------------------------------------------
// 地址两级流水 (V34 时序修正)
//   直接 "比较 -> 选帧 -> 21bit 加法 -> App_rd_addr_r" 在 100MHz 下达不到
//   (实测 -2.94ns)。这里把最后一段拆出来:
//     第一级: n_use / wb_noff 打一拍 (块内稳定, 提前一拍寄存无副作用)
//     第二级: 只剩 "选帧 mux + 21bit 加法"
//   突发长度 16 字(约 28 拍), 提前一拍寄存完全来得及。
//--------------------------------------------------------------------------
reg        nr_sel;
reg [20:0] nr_off;

always @(posedge mem_clk or posedge rst)
begin
	if(rst)
	begin
		nr_sel <= 1'b0;
		nr_off <= 21'd0;
	end
	else
	begin
		nr_sel <= n_use;
		nr_off <= wb_noff;
	end
end

//---- 帧首块 (行0 列0), 直接用量未锁存的输入, 因为 S_ACK 当拍才锁存 ----
wire [9:0]  f_ctr = wipe_dir ? 10'd8 : 10'd631;
reg f_use;
always @(*) begin
	if (wipe_full) f_use = 1'b1;
	else case (wipe_q)
		2'd0:    f_use = (f_ctr >= 10'd320) && ({1'b0,f_ctr} < f_fx);
		2'd1:    f_use = (f_ctr >= 10'd320);
		2'd2:    f_use = (f_ctr >= 10'd320);
		2'd3:    f_use = (f_ctr >= 10'd320) || ({1'b0,f_ctr} < f_fx);
		default: f_use = 1'b0;
	endcase
end
wire [20:0] wb_faddr = f_sel_r ? (wipe_new_idx ? read_addr_1 : read_addr_0)
                               : (wipe_new_idx ? read_addr_0 : read_addr_1);

// 帧首块的选择位也打一拍: 该位只在转场参数变化时变, S_ACK 之前早已稳定
reg f_sel_r;
always @(posedge mem_clk or posedge rst)
begin
	if(rst) f_sel_r <= 1'b0;
	else    f_sel_r <= f_use;
end

//---- 块计数器: 每次突发结束推进一块 ----
always@(posedge mem_clk or posedge rst)
begin
	if(rst)
	begin
		wb_row      <= 9'd0;
		wb_col      <= 6'd0;
		wb_off      <= 21'd0;
		wb_acc      <= 20'd0;
	end
	else if(state == S_ACK)
	begin
		wb_row      <= 9'd0;
		wb_col      <= 6'd0;
		wb_off      <= 21'd0;
		wb_acc      <= wipe_x0;
	end
	else if(state == S_READ_BURST_END && wipe_l)
	begin
		wb_row      <= wb_nrow;
		wb_col      <= wb_ncol;
		wb_off      <= wb_noff;
		wb_acc      <= wb_nacc;
	end
end

wire rd_vld;
reg [3:0] rd_delay;

assign App_rd_addr = {App_rd_addr_r[ADDR_BITS - 1:0]};
assign rd_vld = (state == S_READ_BURST && burst_cnt >= BURST_SIZE);

assign O_rd_busy = (state == S_READ_BURST);//读指令期间
//burst_cnt代表发送的读指令
//但rd_burst_finish需要在发送完十个时钟后拉高，此时数据全部读出
assign rd_burst_finish = (rd_vld && rd_delay == 4'd10);
assign read_finish = (state == S_END) ? 1'b1 : 1'b0;             //read finish at state 'S_END'
assign App_rd_en = App_rd_en_d0;
always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		read_req_d0    <=  1'b0;
		read_req_d1    <=  1'b0;
		read_req_d2    <=  1'b0;
		read_len_d0    <=  ZERO[ADDR_BITS - 1:0];               //equivalent to read_len_d0 <= 0;
		read_len_d1    <=  ZERO[ADDR_BITS - 1:0];               //equivalent to read_len_d1 <= 0;
		read_addr_index_d0 <= 2'b00;
		read_addr_index_d1 <= 2'b00;
	end
	else
	begin
		read_req_d0    <=  read_req;
		read_req_d1    <=  read_req_d0;
		read_req_d2    <=  read_req_d1;     
		read_len_d0    <=  read_len;
		read_len_d1    <=  read_len_d0; 
		read_addr_index_d0 <= read_addr_index;
		read_addr_index_d1 <= read_addr_index_d0;
		
	end 
end

always @(posedge mem_clk or posedge rst)
begin
	if(rst || App_rd_en)begin
        rd_delay <= 4'd0;
    end
    else if(rd_delay < 4'd10)begin
    	rd_delay <= rd_delay + 1'b1;
    end
end
always @(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		burst_cnt <= ZERO[BURST_BITS - 1:0];
		App_rd_addr_r <= ZERO[ADDR_BITS - 1:0];
		App_rd_en_d0 <= 1'b0;
	end
	else begin
	
		if(state == S_CHECK_FIFO)
			burst_cnt <= ZERO[BURST_BITS - 1:0];
		else if(App_rd_en)
			burst_cnt <= burst_cnt + 1'b1;
		else
			burst_cnt <= burst_cnt;
		//
		if(state == S_ACK)
			begin
				if(wipe_en)
					// 旋转擦除: 起始地址由"帧首块"选源帧决定
					App_rd_addr_r <= wb_faddr;
				else if(read_addr_index_d1 == 2'd0)
					App_rd_addr_r <= read_addr_0;
				else if(read_addr_index_d1 == 2'd1)
					App_rd_addr_r <= read_addr_1;
				else if(read_addr_index_d1 == 2'd2)
					App_rd_addr_r <= read_addr_2;
				else if(read_addr_index_d1 == 2'd3)
					App_rd_addr_r <= read_addr_3;
			end
		else if(App_rd_en)
			// 到达跳转点则直接接上另一帧的地址, 否则正常递增 (seg_hit=0 时与原始逻辑等价)
			App_rd_addr_r <= seg_hit ? seg_addr_l : (App_rd_addr_r + 1'b1);
		else if(state == S_READ_BURST_END && wipe_l)
			// 旋转擦除: 每个突发边界换成本块的起始地址 (突发内仍然 +1)
			App_rd_addr_r <= (nr_sel ? wipe_base_new : wipe_base_old) + nr_off;
		else
			App_rd_addr_r <= App_rd_addr_r;
		//
		if(App_rd_en_r && burst_cnt + App_rd_en < BURST_SIZE)
			App_rd_en_d0 <= 1'b1;
		else
			App_rd_en_d0 <= 1'b0;
	
	end		
end
always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		state <= S_IDLE;
		read_len_latch <= ZERO[ADDR_BITS - 1:0];
		
		//rd_burst_addr <= ZERO[ADDR_BITS - 1:0];
		//rd_burst_req <= 1'b0;
		App_rd_en_r <= 1'b0;
		
		read_cnt <= ZERO[ADDR_BITS - 1:0];
		fifo_aclr <= 1'b0;
		//rd_burst_len <= ZERO[BURST_BITS - 1:0];
		read_req_ack <= 1'b0;
	end
	else
		case(state)
			//idle state,waiting for read, read_req_d2 == '1' goto the 'S_ACK'
			S_IDLE:
			begin
				if(read_req_d2 == 1'b1 && Sdr_init_done)
				begin
					state <= S_ACK;
				end
				read_req_ack <= 1'b0;
			end
			//'S_ACK' state completes the read request response, the FIFO reset, the address latch, and the data length latch
			S_ACK:
			begin
				if(read_req_d2 == 1'b0)
				begin
					state <= S_CHECK_FIFO;
					fifo_aclr <= 1'b0;
					read_req_ack <= 1'b0;
				end
				else
				begin
					//read request response
					read_req_ack <= 1'b1;
					//FIFO reset
					fifo_aclr <= 1'b1;
					//select valid base address from read_addr_0 read_addr_1 read_addr_2 read_addr_3
					/*
					if(read_addr_index_d1 == 2'd0)
						App_rd_addr <= read_addr_0;
					else if(read_addr_index_d1 == 2'd1)
						App_rd_addr <= read_addr_1;
					else if(read_addr_index_d1 == 2'd2)
						App_rd_addr <= read_addr_2;
					else if(read_addr_index_d1 == 2'd3)
						App_rd_addr <= read_addr_3;
					*/
					//latch data length
					read_len_latch <= read_len_d1;
					// 滑动转场参数随帧起始一次性锁存, 保证整帧读取过程中不变
					seg_en_l       <= seg_en;
					seg_cnt_l      <= seg_cnt;
					seg_addr_l     <= seg_addr;
					// 旋转擦除参数同样在帧起始锁存
					wipe_l         <= wipe_en;
					wipe_q_l       <= wipe_q;
					wipe_x0_l      <= wipe_x0;
					wipe_dx_l      <= wipe_dx;
					wipe_dir_l     <= wipe_dir;
					wipe_full_l    <= wipe_full;
					base_new_l     <= wipe_new_idx ? read_addr_1 : read_addr_0;
					base_old_l     <= wipe_new_idx ? read_addr_0 : read_addr_1;
				end
				//read data counter reset, read_cnt <= 0;
				read_cnt <= ZERO[ADDR_BITS - 1:0];
			end
			S_CHECK_FIFO:
			begin
				//if there is a read request at this time, enter the 'S_ACK' state
				if(read_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				//if the FIFO space is a burst read request, goto burst read state
				else if(fifo_room && ~App_wr_busy)
				begin
					state <= S_READ_BURST;
					//rd_burst_len <= BURST_SIZE[BURST_BITS - 1:0];
					//rd_burst_req <= 1'b1;
					App_rd_en_r <= 1'b1;
				end
			end
			
			S_READ_BURST:
			begin
				//burst finish  
				if(rd_burst_finish == 1'b1)
				begin
					App_rd_en_r <= 1'b0;
					state <= S_READ_BURST_END;
					//read counter + burst length
					read_cnt <= read_cnt + BURST_SIZE[ADDR_BITS - 1:0];
					//the next burst read address is generated
					//rd_burst_addr <= rd_burst_addr + BURST_SIZE[ADDR_BITS - 1:0];
				end     
			end
			S_READ_BURST_END:
			begin
				//if there is a read request at this time, enter the 'S_ACK' state
				if(read_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				//if the read counter value is less than the frame length, continue read,
				//otherwise the read is complete
				else if(read_cnt < read_len_latch)
				begin
					state <= S_CHECK_FIFO;
				end
				else
				begin
					state <= S_END;
				end
			end
			S_END:
			begin
				state <= S_IDLE;
			end
			default:
				state <= S_IDLE;
		endcase
end
endmodule
