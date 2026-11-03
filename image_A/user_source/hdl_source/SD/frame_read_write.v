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
	input [7:0]                      zoom_setting,
	input [7:0]                      zoom_pan_x,
	input [7:0]                      zoom_pan_y,
	
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
	output [127:0]                   diagnostic_data,
	input [23:0]                     monitor_rgb,
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

// Sticky nonzero detector at the actual accepted write interface, after WFIFO.
reg [15:0] diagnostic_write_or;
always @(posedge mem_clk or posedge rst) begin
    if(rst) diagnostic_write_or<=0;
    else if(App_wr_en) diagnostic_write_or<={15'd0,diagnostic_write_or[0] | (|App_wr_din)};
end

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
wire [ADDR_BITS-1:0] zoom_base = read_addr_index==0 ? read_addr_0 :
                                    read_addr_index==1 ? read_addr_1 :
                                    read_addr_index==2 ? read_addr_2 : read_addr_3;
image_hires_zoom_reader #(.ADDR_BITS(ADDR_BITS)) zoom_read(
    .rst(rst),.mem_clk(mem_clk),.video_clk(read_clk),
    .init_done(Sdr_init_done),.mem_busy(Sdr_busy),.refresh_busy(Sdr_init_ref_vld),
    .writer_busy(App_wr_busy),.display_active(display_active),
    .mem_read_en(App_rd_en),.mem_read_addr(App_rd_addr),
    .mem_data_valid(Sdr_rd_en),.mem_data(Sdr_rd_dout),
    .reader_busy(O_rd_busy),.buffered_words(wrusedw),
    .frame_req(read_req),.frame_ack(read_req_ack),.frame_base(zoom_base),
    .zoom_setting(zoom_setting),.pan_x(zoom_pan_x),.pan_y(zoom_pan_y),
    .pixel_read(read_en),.pixel_data(read_data),
    .diagnostic_write_or(diagnostic_write_or),.monitor_rgb(monitor_rgb),
    .stream_ready(read_stream_ready),.cache_empty(read_fifo_empty),
    .missed_pixels(),.diagnostic_data(diagnostic_data)
);
assign read_fifo_usedw=wrusedw;
assign read_finish=1'b0;
endmodule

// Four rows of eight large hexadecimal digits. Diagnostic candidate only.
module hires_diagnostic_overlay(
 input clk,input rst,input vs,input de,input [127:0] data,
 input [23:0] source_rgb,output reg [23:0] rgb
);
 reg [9:0] x,y;
 reg de_d;
 reg vs_d;
 reg [127:0] frame_data;
 always @(posedge clk or posedge rst) begin
   if(rst) begin x<=0;y<=0;de_d<=0;vs_d<=1;frame_data<=0;end
   else begin
     de_d<=de;
     vs_d<=vs;
     if(vs_d && !vs) frame_data<=data;
     if(!vs) begin x<=0;y<=0;end
     else begin
       if(de) x<=x+1'b1;else x<=0;
       if(de_d && !de) y<=y+1'b1;
     end
   end
 end
 function [6:0] segments(input [3:0] n);
   begin
     case(n)
       0:segments=7'b1111110;1:segments=7'b0110000;
       2:segments=7'b1101101;3:segments=7'b1111001;
       4:segments=7'b0110011;5:segments=7'b1011011;
       6:segments=7'b1011111;7:segments=7'b1110000;
       8:segments=7'b1111111;9:segments=7'b1111011;
       10:segments=7'b1110111;11:segments=7'b0011111;
       12:segments=7'b1001110;13:segments=7'b0111101;
       14:segments=7'b1001111;15:segments=7'b1000111;
     endcase
   end
 endfunction
 wire region=de && x>=8 && x<264 && y>=32 && y<224;
 wire [8:0] dx=x-10'd8;
 wire [7:0] dy=y-10'd32;
 wire [1:0] row=dy>=144 ? 2'd3 : dy>=96 ? 2'd2 : dy>=48 ? 2'd1 : 2'd0;
 wire [7:0] local_y=dy-row*8'd48;
 wire [4:0] ly=local_y[5:1];
 wire [3:0] lx=dx[4:1];
 wire [4:0] shift={dx[7:5],2'b00};
 wire [31:0] row_data=row==0 ? frame_data[127:96] : row==1 ? frame_data[95:64] :
                        row==2 ? frame_data[63:32] : frame_data[31:0];
 wire [3:0] digit=(row_data>>(5'd28-shift));
 wire [6:0] seg=segments(digit);
 wire horizontal=lx>=3 && lx<11;
 wire upper=ly>=3 && ly<10;
 wire lower=ly>=12 && ly<19;
 wire ink=(seg[6] && horizontal && ly>=1 && ly<3) ||
          (seg[5] && lx>=11 && lx<13 && upper) ||
          (seg[4] && lx>=11 && lx<13 && lower) ||
          (seg[3] && horizontal && ly>=19 && ly<21) ||
          (seg[2] && lx>=1 && lx<3 && lower) ||
          (seg[1] && lx>=1 && lx<3 && upper) ||
          (seg[0] && horizontal && ly>=10 && ly<12);
 always @* begin
   rgb=source_rgb;
   if(region) rgb=ink ? 24'hff60c0 : 24'h081020;
 end
endmodule

//960x720 packed RGB888 backing store,640x480 viewport. The two line caches
//hold DISPLAY pixels, not source rows, so BRAM use stays at2048x24 bits.
module image_hires_zoom_reader #(parameter ADDR_BITS=21)(
    input rst,input mem_clk,input video_clk,
    input init_done,input mem_busy,input refresh_busy,input writer_busy,
    input display_active,output mem_read_en,output [ADDR_BITS-1:0] mem_read_addr,
    input mem_data_valid,input [31:0] mem_data,
    output reader_busy,output [8:0] buffered_words,
    input frame_req,output frame_ack,input [ADDR_BITS-1:0] frame_base,
    input [7:0] zoom_setting,input [7:0] pan_x,input [7:0] pan_y,
    input pixel_read,output [31:0] pixel_data,
    input [15:0] diagnostic_write_or,input [23:0] monitor_rgb,
    output stream_ready,output cache_empty,output reg [15:0] missed_pixels,
    output [127:0] diagnostic_data
);
    (* ram_style="bram" *) reg [23:0] lines[0:2047];
    reg [23:0] line_pixel;
    reg sample_valid;
    assign pixel_data={sample_valid ? line_pixel : 24'd0,8'd0};
    assign stream_ready=!rst;
    assign frame_ack=frame_req;

    reg [1:0] request_toggle,request_valid;
    reg [9:0] request_row0,request_row1;
    reg [10:0] request_origin0,request_origin1,request_step0,request_step1;
    reg [9:0] request_width0,request_width1;
    reg [ADDR_BITS-1:0] request_base0,request_base1;
    reg [1:0] ack_toggle,ack_v0,ack_v1,req_m0,req_m1,req_m2;
    reg [9:0] row0_m0,row1_m0,row0_m1,row1_m1;
    reg [10:0] origin0_m0,origin1_m0,origin0_m1,origin1_m1;
    reg [10:0] step0_m0,step1_m0,step0_m1,step1_m1;
    reg [9:0] width0_m0,width1_m0,width0_m1,width1_m1;
    reg [ADDR_BITS-1:0] base0_m0,base1_m0,base0_m1,base1_m1;
    reg active_m0,active_m1,active_v0,active_v1;
    wire [1:0] pending=req_m2 ^ ack_toggle;
    reg mem_state,fill_bank;
    reg [ADDR_BITS-1:0] address;
    reg [10:0] issued,returned;
    reg [10:0] fill_step;
    reg [9:0] fill_width,fill_last,fill_output;
    reg [19:0] fill_target,fill_next_target;
    reg [10:0] source_column;
    reg [31:0] raw_fifo[0:15];
    reg [15:0] last_return;
    reg [3:0] raw_wr,raw_rd;
    reg [4:0] raw_count;
    reg [1:0] assemble_phase,group_index;
    reg [95:0] group_data;
    reg group_valid;
    // Assemble the following four pixels while the current group is sampled.
    // Keep this staging register independent of group_data: magnification may
    // consume one source pixel more than once, including the group's last one.
    reg [95:0] assembled_data;
    reg assembled_valid;
    // A credit remains reserved from command acceptance until raw FIFO pop.
    // This is exactly raw_count + issued - returned, without routing two
    // wide arithmetic chains and a comparator into the SDRAM command pins.
    reg [4:0] reserved_words;
    wire raw_push=mem_state && mem_data_valid;
    wire raw_pop=mem_state && !assembled_valid && raw_count!=0;
    wire [19:0] following_target=fill_next_target;
    wire selected_pixel=group_valid && fill_output<fill_width &&
                        source_column==fill_target[19:8];
    wire consume_pixel=group_valid && (!selected_pixel ||
                       fill_output>=fill_last || following_target[19:8]!=source_column);
    // Hand over on the cycle after the previous group drains. This breaks
    // the source-column comparator -> high-fanout assembled_valid path.
    // The assembly stage remains overlapped with sampling; no pixel is lost.
    wire take_assembled=assembled_valid && !group_valid;
    assign mem_read_en=mem_state && issued<720 && reserved_words<12 &&
                       !mem_busy && !refresh_busy;
    assign mem_read_addr=address;
    assign reader_busy=mem_state;
    assign buffered_words=(pending!=0 || mem_state) ? 9'd0 : 9'd511;

    // Bundled descriptors remain unchanged from request until acknowledgement.
    // Keep the same opposite-edge sampling convention as the accepted baseline.
    always @(negedge mem_clk or posedge rst) begin
        if(rst) begin
            req_m0<=0;row0_m0<=0;row1_m0<=0;base0_m0<=0;base1_m0<=0;
            origin0_m0<=0;origin1_m0<=0;step0_m0<=0;step1_m0<=0;
            width0_m0<=0;width1_m0<=0;
        end else begin
            req_m0<=request_toggle;row0_m0<=request_row0;row1_m0<=request_row1;
            base0_m0<=request_base0;base1_m0<=request_base1;
            origin0_m0<=request_origin0;origin1_m0<=request_origin1;
            step0_m0<=request_step0;step1_m0<=request_step1;
            width0_m0<=request_width0;width1_m0<=request_width1;
        end
    end
    always @(posedge mem_clk or posedge rst) begin
        if(rst) begin
            req_m1<=0;req_m2<=0;row0_m1<=0;row1_m1<=0;base0_m1<=0;base1_m1<=0;
            origin0_m1<=0;origin1_m1<=0;step0_m1<=0;step1_m1<=0;
            width0_m1<=0;width1_m1<=0;active_m0<=0;active_m1<=0;
            ack_toggle<=0;mem_state<=0;fill_bank<=0;address<=0;issued<=0;returned<=0;
            fill_step<=0;fill_width<=0;fill_last<=0;fill_output<=0;
            fill_target<=0;fill_next_target<=0;source_column<=0;reserved_words<=0;
            raw_wr<=0;raw_rd<=0;raw_count<=0;assemble_phase<=0;group_index<=0;
            group_data<=0;group_valid<=0;assembled_data<=0;assembled_valid<=0;
            last_return<=0;
        end else begin
            req_m1<=req_m0;req_m2<=req_m1;row0_m1<=row0_m0;row1_m1<=row1_m0;
            base0_m1<=base0_m0;base1_m1<=base1_m0;
            origin0_m1<=origin0_m0;origin1_m1<=origin1_m0;
            step0_m1<=step0_m0;step1_m1<=step1_m0;
            width0_m1<=width0_m0;width1_m1<=width1_m0;
            active_m0<=display_active;active_m1<=active_m0;
            if(!mem_state) begin
                if(init_done && active_m1 && !writer_busy && !mem_busy && !refresh_busy && pending!=0) begin
                    fill_bank<=!pending[0];
                    address<=pending[0] ? base0_m1+row0_m1*21'd720 : base1_m1+row1_m1*21'd720;
                    fill_target<=pending[0] ? {origin0_m1,8'd0} : {origin1_m1,8'd0};
                    fill_next_target<=pending[0] ?
                        ({origin0_m1,8'd0}+step0_m1) : ({origin1_m1,8'd0}+step1_m1);
                    fill_step<=pending[0] ? step0_m1 : step1_m1;
                    fill_width<=pending[0] ? width0_m1 : width1_m1;
                    fill_last<=(pending[0] ? width0_m1 : width1_m1)-10'd1;
                    fill_output<=0;source_column<=0;issued<=0;returned<=0;
                    raw_wr<=0;raw_rd<=0;raw_count<=0;reserved_words<=0;assemble_phase<=0;group_index<=0;
                    group_valid<=0;assembled_valid<=0;mem_state<=1;
                end
            end else begin
                if(mem_read_en) begin issued<=issued+1'b1;address<=address+1'b1;end
                if(raw_push) begin
                    returned<=returned+1'b1;raw_wr<=raw_wr+1'b1;
                    last_return<=mem_data[31:16]^mem_data[15:0];
                end
                if(raw_pop) begin
                    raw_rd<=raw_rd+1'b1;
                    case(assemble_phase)
                        0: begin assembled_data[95:64]<=raw_fifo[raw_rd];assemble_phase<=1;end
                        1: begin assembled_data[63:32]<=raw_fifo[raw_rd];assemble_phase<=2;end
                        2: begin assembled_data[31:0]<=raw_fifo[raw_rd];assemble_phase<=0;assembled_valid<=1;end
                    endcase
                end
                case({raw_push,raw_pop})
                    2'b10: raw_count<=raw_count+1'b1;
                    2'b01: raw_count<=raw_count-1'b1;
                    default: begin end
                endcase
                case({mem_read_en,raw_pop})
                    2'b10: reserved_words<=reserved_words+1'b1;
                    2'b01: reserved_words<=reserved_words-1'b1;
                    default: begin end
                endcase
                if(selected_pixel) begin
                    fill_output<=fill_output+1'b1;fill_target<=following_target;
                    fill_next_target<=fill_next_target+fill_step;
                end
                if(consume_pixel) begin
                    source_column<=source_column+1'b1;
                    group_data<={group_data[71:0],24'd0};
                    group_index<=group_index+1'b1;
                    if(group_index==3) group_valid<=0;
                end
                // Replacement takes priority over shifting the old final
                // pixel. The line RAM still captures the old group this edge.
                if(take_assembled) begin
                    group_data<=assembled_data;group_index<=0;group_valid<=1;
                    assembled_valid<=0;
                end
                // All accepted commands and all returns must drain, even when
                //the visible crop ends before the right edge of the source row.
                if(issued==720 && returned==720 && raw_count==0 && !group_valid &&
                   !assembled_valid && assemble_phase==0 &&
                   source_column==960 && fill_output==fill_width) begin
                    ack_toggle[fill_bank]<=req_m2[fill_bank];mem_state<=0;
                end
            end
        end
    end
    always @(posedge mem_clk) begin
        if(raw_push) raw_fifo[raw_wr]<=mem_data;
        if(mem_state && selected_pixel) lines[{fill_bank,fill_output}]<=group_data[95:72];
    end

    reg req_d;
    reg [7:0] setting_v0,setting_v1,px_v0,px_v1,py_v0,py_v1;
    reg [7:0] pan_x_frame,pan_y_frame;
    reg [3:0] setup_state;
    reg [4:0] divide_count;
    reg [8:0] percentage,divisor;
    reg [15:0] quotient;
    reg [9:0] remainder;
    wire [10:0] trial={remainder,quotient[15]};
    wire take=trial>={2'b0,divisor};
    wire [15:0] quotient_next={quotient[14:0],take};
    reg [10:0] step_q8;
    reg [11:0] viewport_w,viewport_h;
    reg [9:0] dest_w,dest_h,left_pad,top_pad;
    // Used only when percentage>100: the legal viewport fits 960x720.
    // Explicit widths avoid a 32-bit subtract/multiply for pan.
    wire [9:0] pan_span_x=10'd960-viewport_w[9:0];
    wire [9:0] pan_span_y=10'd720-viewport_h[9:0];
    wire [17:0] pan_product_x=pan_span_x*pan_x_frame;
    wire [17:0] pan_product_y=pan_span_y*pan_y_frame;
    reg [10:0] origin_x,origin_y;
    reg [ADDR_BITS-1:0] base_frame;
    reg configured,current_bank;
    reg [9:0] out_x,out_y;
    reg [19:0] source_y_q8;
    wire [20:0] next_source_y={1'b0,source_y_q8}+step_q8;
    wire [12:0] next_unique=step_q8>=256 ? next_source_y[20:8] : {1'b0,source_y_q8[19:8]}+13'd1;
    wire [9:0] current_row=source_y_q8[19:8]>719 ? 10'd719 : source_y_q8[17:8];
    wire [9:0] prefetch_row=next_unique>719 ? 10'd719 : next_unique[9:0];
    wire [9:0] wanted0=current_bank ? prefetch_row : current_row;
    wire [9:0] wanted1=current_bank ? current_row : prefetch_row;
    wire valid0=request_valid[0] && ack_v1[0]==request_toggle[0] && request_row0==current_row &&
                request_base0==base_frame && request_origin0==origin_x &&
                request_step0==step_q8 && request_width0==dest_w;
    wire valid1=request_valid[1] && ack_v1[1]==request_toggle[1] && request_row1==current_row &&
                request_base1==base_frame && request_origin1==origin_x &&
                request_step1==step_q8 && request_width1==dest_w;
    wire current_ready=current_bank ? valid1 : valid0;
    wire inside_image=out_x>=left_pad && out_x<left_pad+dest_w && out_y>=top_pad && out_y<top_pad+dest_h;
    // Each sticky bit is zero exactly when every observed data bit was zero. Keep
    // observations across blank source rows; the supplied BMPs have black
    // letterboxes, so the final returned word alone cannot diagnose data.
    reg [15:0] diagnostic_read_or,diagnostic_unpack_or;
    // Observe complete row service time; do not gate any datapath with it.
    // At 125 MHz, one tick is 8 ns. Sticky maximum saturates at 65535.
    reg [15:0] diagnostic_row_ticks,diagnostic_row_max;
    reg diagnostic_row_busy_d;
    always @(posedge mem_clk or posedge rst) begin
      if(rst) begin
        diagnostic_row_ticks<=0;diagnostic_row_max<=0;diagnostic_row_busy_d<=0;
      end else begin
        diagnostic_row_busy_d<=mem_state;
        if(mem_state) begin
          if(diagnostic_row_ticks!=16'hffff) diagnostic_row_ticks<=diagnostic_row_ticks+1'b1;
        end else begin
          diagnostic_row_ticks<=0;
          if(diagnostic_row_busy_d && diagnostic_row_ticks>diagnostic_row_max)
            diagnostic_row_max<=diagnostic_row_ticks;
        end
      end
    end
    always @(posedge mem_clk or posedge rst) begin
      if(rst) begin diagnostic_read_or<=0;diagnostic_unpack_or<=0;end
      else begin
        if(raw_push) diagnostic_read_or<={15'd0,diagnostic_read_or[0] | (|mem_data)};
        if(mem_state && selected_pixel)
          diagnostic_unpack_or<={15'd0,diagnostic_unpack_or[0] | (|group_data[95:72])};
      end
    end
    reg [47:0] debug_v0,debug_v1;
    reg [15:0] diagnostic_cache_or,diagnostic_monitor_or,diagnostic_valid_count;
    reg [15:0] previous_missed,previous_flags;
    always @(posedge video_clk or posedge rst) begin
        if(rst) begin
          debug_v0<=0;debug_v1<=0;diagnostic_cache_or<=0;
          diagnostic_monitor_or<=0;diagnostic_valid_count<=0;
          previous_missed<=0;previous_flags<=0;
        end
        else begin
            debug_v0<={diagnostic_row_max,diagnostic_read_or,diagnostic_unpack_or};
            debug_v1<=debug_v0;
            if(pixel_read && configured && active_v1 && inside_image && current_ready)
              diagnostic_cache_or<={15'd0,diagnostic_cache_or[0] | (|line_pixel)};
            if(pixel_read) diagnostic_monitor_or<={15'd0,diagnostic_monitor_or[0] | (|monitor_rgb)};
            if(sample_valid && diagnostic_valid_count!=16'hffff)
              diagnostic_valid_count<=diagnostic_valid_count+1'b1;
            // Capture BEFORE the request resets configured and missed_pixels.
            // The overlay's delayed VS occurs during setup and hid this data.
            if(frame_req && !req_d) begin
              previous_missed<=missed_pixels;
              previous_flags<={4'd0,configured,active_v1,current_bank,current_ready,
                               request_valid,request_toggle,ack_v1,2'd0};
            end
        end
    end
    assign diagnostic_data={debug_v1,diagnostic_cache_or,diagnostic_monitor_or,
                            diagnostic_valid_count,previous_missed,previous_flags};
    wire [9:0] display_column=out_x-left_pad;
    assign cache_empty=!current_ready;
    always @(posedge video_clk) line_pixel<=lines[{current_bank,display_column}];
    always @(posedge video_clk or posedge rst) begin
        if(rst) begin
            request_toggle<=0;request_valid<=0;request_row0<=0;request_row1<=0;
            request_base0<=0;request_base1<=0;request_origin0<=0;request_origin1<=0;
            request_step0<=0;request_step1<=0;request_width0<=0;request_width1<=0;
            ack_v0<=0;ack_v1<=0;active_v0<=0;active_v1<=0;req_d<=0;
            setting_v0<=25;setting_v1<=25;px_v0<=128;px_v1<=128;py_v0<=128;py_v1<=128;
            pan_x_frame<=128;pan_y_frame<=128;setup_state<=0;divide_count<=0;
            percentage<=100;divisor<=100;quotient<=0;remainder<=0;step_q8<=384;
            viewport_w<=960;viewport_h<=720;dest_w<=640;dest_h<=480;
            left_pad<=0;top_pad<=0;origin_x<=0;origin_y<=0;base_frame<=0;
            configured<=0;current_bank<=0;out_x<=0;out_y<=0;source_y_q8<=0;sample_valid<=0;missed_pixels<=0;
        end else begin
            ack_v0<=ack_toggle;ack_v1<=ack_v0;active_v0<=display_active;active_v1<=active_v0;
            setting_v0<=zoom_setting;setting_v1<=setting_v0;px_v0<=pan_x;px_v1<=px_v0;py_v0<=pan_y;py_v1<=py_v0;
            req_d<=frame_req;
            sample_valid<=pixel_read && configured && active_v1 && inside_image && current_ready;
            if(frame_req && !req_d) begin
                setup_state<=1;configured<=0;out_x<=0;out_y<=0;missed_pixels<=0;
            end else begin
                case(setup_state)
                    1: begin
                        percentage<=9'd50+{setting_v1,1'b0};divisor<=9'd50+{setting_v1,1'b0};
                        pan_x_frame<=px_v1;pan_y_frame<=py_v1;base_frame<=frame_base;
                        quotient<=16'd38400;remainder<=0;divide_count<=0;setup_state<=2;
                    end
                    2: begin
                        quotient<=quotient_next;remainder<=take ? trial-divisor : trial;
                        if(divide_count==15) begin step_q8<=quotient_next[10:0];setup_state<=3;end
                        else divide_count<=divide_count+1'b1;
                    end
                    3: begin
                        viewport_w<=(step_q8*21'd640)>>8;viewport_h<=(step_q8*21'd480)>>8;
                        quotient<=percentage>=100 ? 16'd64000 : percentage*16'd640;
                        divisor<=100;remainder<=0;divide_count<=0;setup_state<=4;
                    end
                    4: begin
                        quotient<=quotient_next;remainder<=take ? trial-divisor : trial;
                        if(divide_count==15) setup_state<=5;else divide_count<=divide_count+1'b1;
                    end
                    5: begin
                        dest_w<=quotient[9:0];quotient<=percentage>=100 ? 16'd48000 : percentage*16'd480;
                        remainder<=0;divide_count<=0;setup_state<=6;
                    end
                    6: begin
                        quotient<=quotient_next;remainder<=take ? trial-divisor : trial;
                        if(divide_count==15) setup_state<=7;else divide_count<=divide_count+1'b1;
                    end
                    7: begin dest_h<=quotient[9:0];setup_state<=8;end
                    8: begin
                        origin_x<=percentage<=100 ? 11'd0 : (pan_x_frame==255 ? {1'b0,pan_span_x} : {1'b0,pan_product_x[17:8]});
                        origin_y<=percentage<=100 ? 11'd0 : (pan_y_frame==255 ? {1'b0,pan_span_y} : {1'b0,pan_product_y[17:8]});
                        left_pad<=(640-dest_w)>>1;top_pad<=(480-dest_h)>>1;setup_state<=9;
                    end
                    9: begin source_y_q8<={origin_y,8'd0};current_bank<=0;configured<=1;setup_state<=0;end
                    default: begin end
                endcase
                if(configured && active_v1) begin
                    if(ack_v1[0]==request_toggle[0] && (!request_valid[0] || request_row0!=wanted0 ||
                       request_base0!=base_frame || request_origin0!=origin_x || request_step0!=step_q8 || request_width0!=dest_w)) begin
                        request_row0<=wanted0;request_base0<=base_frame;request_origin0<=origin_x;
                        request_step0<=step_q8;request_width0<=dest_w;
                        request_toggle[0]<=~request_toggle[0];request_valid[0]<=1;
                    end
                    if(ack_v1[1]==request_toggle[1] && (!request_valid[1] || request_row1!=wanted1 ||
                       request_base1!=base_frame || request_origin1!=origin_x || request_step1!=step_q8 || request_width1!=dest_w)) begin
                        request_row1<=wanted1;request_base1<=base_frame;request_origin1<=origin_x;
                        request_step1<=step_q8;request_width1<=dest_w;
                        request_toggle[1]<=~request_toggle[1];request_valid[1]<=1;
                    end
                end
                if(pixel_read && configured) begin
                    if(inside_image && active_v1 && !current_ready && missed_pixels!=16'hffff) missed_pixels<=missed_pixels+1'b1;
                    if(out_x==639) begin
                        out_x<=0;out_y<=out_y+1'b1;
                        if(out_y>=top_pad && out_y+1<top_pad+dest_h) begin
                            source_y_q8<=next_source_y[19:0];
                            if(next_source_y[19:8]!=source_y_q8[19:8]) current_bank<=~current_bank;
                        end
                    end else out_x<=out_x+1'b1;
                end
            end
        end
    end
endmodule
