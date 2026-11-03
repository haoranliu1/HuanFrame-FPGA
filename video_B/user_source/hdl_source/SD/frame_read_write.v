`timescale 1ns/1ps
module frame_read_write
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter READ_DATA_BITS         = 32,
	parameter WRITE_DATA_BITS        = 32,
	parameter ADDR_BITS              = 21,
	parameter BURST_BITS             = 9,//
	parameter BURST_SIZE             = 256,
	parameter WRITE_V_FLIP           = 1,      // 1: vertical flip when writing TF/BMP frame into SDRAM
	parameter FRAME_WIDTH            = 640,
	parameter FRAME_HEIGHT           = 480
) 
(
	input                            rst,                  
	input                            mem_clk,                    // external memory controller user interface clock
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
    input							 Sdr_busy,
	input                            display_active,
	
    /*
    output                           rd_burst_req,               // to external memory controller,send out a burst read request
	output[BURST_BITS - 1:0]         rd_burst_len,               // to external memory controller,data length of the burst read request, not bytes
	output[ADDR_BITS - 1:0]          rd_burst_addr,              // to external memory controller,base address of the burst read request 
	input                            rd_burst_data_valid,        // from external memory controller,read data valid 
	input[MEM_DATA_BITS - 1:0]       rd_burst_data,              // from external memory controller,read request data
	input                            rd_burst_finish,            // from external memory controller,burst read finish
	*/
	output							 App_rd_en,
	output[ADDR_BITS - 1:0]			 App_rd_addr,
	input							 Sdr_rd_en,					 //read_data_valid
	input[MEM_DATA_BITS - 1:0]		 Sdr_rd_dout,
	
	input                            read_clk,                   // data read module clock
	input                            read_req,                   // data read module read request,keep '1' until read_req_ack = '1'
	output                           read_req_ack,               // data read module read request response
	output                           read_finish,                // data read module read request finish
	input[ADDR_BITS - 1:0]           read_addr_0,                // data read module read request base address 0, used when read_addr_index = 0
	input[ADDR_BITS - 1:0]           read_addr_1,                // data read module read request base address 1, used when read_addr_index = 1
	input[ADDR_BITS - 1:0]           read_addr_2,                // data read module read request base address 1, used when read_addr_index = 2
	input[ADDR_BITS - 1:0]           read_addr_3,                // data read module read request base address 1, used when read_addr_index = 3
	input[1:0]                       read_addr_index,            // select valid base address from read_addr_0 read_addr_1 read_addr_2 read_addr_3
	input[ADDR_BITS - 1:0]           read_len,                   // data read module read request data length
	input                            read_en,                    // data read module read request for one data, read_data valid next clock
	output[READ_DATA_BITS  - 1:0]    read_data,                  // read data
	output                           read_fifo_empty,            // read-clock-domain FIFO empty status
	output                           read_stream_ready,          // FIFO has been primed for HDMI consumption
	/*
	output                           wr_burst_req,               // to external memory controller,send out a burst write request
	output[BURST_BITS - 1:0]         wr_burst_len,               // to external memory controller,data length of the burst write request, not bytes
	output[ADDR_BITS - 1:0]          wr_burst_addr,              // to external memory controller,base address of the burst write request 
	input                            wr_burst_data_req,          // from external memory controller,write data request ,before data 1 clock
	output[MEM_DATA_BITS - 1:0]      wr_burst_data,              // to external memory controller,write data
	input                            wr_burst_finish,            // from external memory controller,burst write finish
	*/
	output							 App_wr_en,
	output[ADDR_BITS - 1:0]			 App_wr_addr,
	output[MEM_DATA_BITS - 1:0]	 App_wr_din,
	output[3:0]						 App_wr_dm,
	
	//
	input                            write_clk,                  // data write module clock
	input                            write_req,                  // data write module write request,keep '1' until read_req_ack = '1'
	output                           write_req_ack,              // data write module write request response
	output                           write_finish,               // data write module write request finish
	output                           write_fifo_full,            // write-clock-domain FIFO backpressure
	input[ADDR_BITS - 1:0]           write_addr_0,               // data write module write request base address 0, used when write_addr_index = 0
	input[ADDR_BITS - 1:0]           write_addr_1,               // data write module write request base address 1, used when write_addr_index = 1
	input[ADDR_BITS - 1:0]           write_addr_2,               // data write module write request base address 1, used when write_addr_index = 2
	input[ADDR_BITS - 1:0]           write_addr_3,               // data write module write request base address 1, used when write_addr_index = 3
	input[1:0]                       write_addr_index,           // select valid base address from write_addr_0 write_addr_1 write_addr_2 write_addr_3
	input[ADDR_BITS - 1:0]           write_len,                  // data write module write request data length
	input                            write_en,                   // data write module write request for one data
	input[WRITE_DATA_BITS - 1:0]     write_data                 // write data

);
wire[BURST_BITS - 1:0]                           wrusedw;                    // write used words
wire[BURST_BITS - 1:0]                           rdusedw;                    // read used words

wire 								 App_rd_busy;
wire								 App_wr_busy;

wire                                 read_fifo_aclr;             // fifo Asynchronous clear
wire                                 write_fifo_aclr;            // fifo Asynchronous clear
wire                                 read_fifo_empty_i;
wire [BURST_BITS - 1:0]              read_fifo_usedw;
reg                                  read_stream_ready_r;
reg [7:0]                            read_prefill_cnt;
reg                                  display_active_mem0;
reg                                  display_active_mem1;

// Require a real read-domain FIFO watermark after each reset. A timer based
// only on !empty can release HDMI after one word and still expose stale data
// when the next SDRAM burst is delayed.
localparam [BURST_BITS - 1:0] READ_PREFILL_WORDS = BURST_SIZE;
localparam [7:0]              READ_PREFILL_STABLE_CYCLES = 8'd3;

wire O_wr_busy;
wire O_rd_busy;

assign App_wr_busy = O_wr_busy;//下个时钟写指令拉高
assign App_rd_busy = O_rd_busy;//读指令还没有过去十个时钟;因为写指令优先，不需要在意下个时钟是否是读指令
assign App_wr_dm = 4'b0000;

// display_active is produced by the TF control clock domain. Synchronize it
// before using it to enable the read-FIFO low-water protection in mem_clk.
always @(posedge mem_clk or posedge rst) begin
	if (rst) begin
		display_active_mem0 <= 1'b0;
		display_active_mem1 <= 1'b0;
	end else begin
		display_active_mem0 <= display_active;
		display_active_mem1 <= display_active_mem0;
	end
end

//instantiate an asynchronous FIFO 
wfifo_32_32_512 write_buf
	(
	.clkr                      	(mem_clk                  ),          // Read side clock
	.clkw                      	(write_clk                ),          // Write side clock
	.rst                       	(write_fifo_aclr          ),          // Asynchronous clear
	.we                      	(write_en                 ),          // Write Request
	.re                      	(App_wr_en        		  ),          // Read Request
	.di                       	(write_data               ),          // Input Data
	.empty_flag                 (                         ),          // Read side Empty flag
	.full_flag                  (write_fifo_full          ),          // Write side Full flag
	.wrusedw                	(              	  		  ),          // Read Used Words
	.rdusedw                	(rdusedw                  ),          // Write Used Words
	.dout                       (App_wr_din		          )
);

frame_fifo_write
#
(
	.MEM_DATA_BITS              (MEM_DATA_BITS            ),
	.ADDR_BITS                  (ADDR_BITS                ),
	.BURST_BITS                 (BURST_BITS               ),
	.BURST_SIZE                 (BURST_SIZE               ),
	.WRITE_V_FLIP               (WRITE_V_FLIP             ),
	.FRAME_WIDTH                (FRAME_WIDTH              ),
	.FRAME_HEIGHT               (FRAME_HEIGHT             )
) 
frame_fifo_write_m0              
(  
	.rst                        (rst                      ),
	.mem_clk                    (mem_clk                  ),
    .Sdr_init_done				(Sdr_init_done),
	.Sdr_init_ref_vld			(Sdr_init_ref_vld),
    .Sdr_busy					(Sdr_busy),
	.App_rd_busy				(App_rd_busy),
    .O_wr_busy					(O_wr_busy),
	
	.App_wr_en					(App_wr_en),
    .App_wr_addr				(App_wr_addr),
	.write_req                  (write_req                ),
	.write_req_ack              (write_req_ack            ),
	.write_finish               (write_finish             ),
	.write_addr_0               (write_addr_0             ),
	.write_addr_1               (write_addr_1             ),
	.write_addr_2               (write_addr_2             ),
	.write_addr_3               (write_addr_3             ),
	.write_addr_index           (write_addr_index         ),    
	.write_len                  (write_len                ),
	.fifo_aclr                  (write_fifo_aclr          ),
	.rdusedw                 	(rdusedw                  ),
	.read_fifo_usedw           (wrusedw                  ),
	.display_active            (display_active_mem1       )
);

//instantiate an asynchronous FIFO 
rfifo_32_32_512 read_buf
	(
	.clkr                     	(read_clk                   ),          // Read side clock
	.clkw                     	(mem_clk                    ),          // Write side clock
	.rst                      	(read_fifo_aclr             ),          // Asynchronous clear
	.we                     	(Sdr_rd_en       			),          // Write Request
	.re                     	(read_en                    ),          // Read Request
	.di                      	(Sdr_rd_dout                ),          // Input Data
	.empty_flag					(read_fifo_empty_i       ),          // Read side Empty flag
	.full_flag					(                           ),          // Write side Full flag
	.wrusedw                	(wrusedw         	  	  		 ),          // Read Used Words
	.rdusedw                	(read_fifo_usedw          ),          // Write Used Words
	.dout						(read_data                  )
);

assign read_fifo_empty = read_fifo_empty_i;
assign read_stream_ready = read_stream_ready_r;

// Keep the ready flag asserted during normal streaming. It is cleared by the
// per-frame asynchronous FIFO reset or a real underflow; a low watermark alone
// must not periodically blank the picture.
always @(posedge read_clk or posedge rst or posedge read_fifo_aclr) begin
	if (rst || read_fifo_aclr) begin
		read_stream_ready_r <= 1'b0;
		read_prefill_cnt     <= 8'd0;
	end else if (!read_stream_ready_r) begin
		if (read_fifo_usedw < READ_PREFILL_WORDS) begin
			read_prefill_cnt <= 8'd0;
		end else if (read_prefill_cnt >= READ_PREFILL_STABLE_CYCLES) begin
			read_stream_ready_r <= 1'b1;
		end else begin
			read_prefill_cnt <= read_prefill_cnt + 8'd1;
		end
	end else if (read_fifo_empty_i) begin
		read_stream_ready_r <= 1'b0;
		read_prefill_cnt     <= 8'd0;
	end
end

frame_fifo_read
#
(
	.MEM_DATA_BITS              (MEM_DATA_BITS            ),
	.ADDR_BITS                  (ADDR_BITS                ),
	.BURST_BITS                 (BURST_BITS               ),
	.BURST_SIZE                 (BURST_SIZE               )
)
frame_fifo_read_m0
(
	.rst                        (rst                      ),
	.mem_clk                    (mem_clk                  ),
    .Sdr_init_done				(Sdr_init_done),
	.Sdr_init_ref_vld			(Sdr_init_ref_vld),
    .Sdr_busy					(Sdr_busy),
    .Sdr_rd_en					(Sdr_rd_en),
	.App_wr_busy				(App_wr_busy),
    .O_rd_busy					(O_rd_busy),
	
    .App_rd_en					(App_rd_en),
    .App_rd_addr				(App_rd_addr),
	.read_req                   (read_req                 ),
	.read_req_ack               (read_req_ack             ),
	.read_finish                (read_finish              ),
	.read_addr_0                (read_addr_0              ),
	.read_addr_1                (read_addr_1              ),
	.read_addr_2                (read_addr_2              ),
	.read_addr_3                (read_addr_3              ),
	.read_addr_index            (read_addr_index          ),    
	.read_len                   (read_len                 ),
	.fifo_aclr                  (read_fifo_aclr           ),
	.wrusedw                	(wrusedw                  )
);

endmodule
