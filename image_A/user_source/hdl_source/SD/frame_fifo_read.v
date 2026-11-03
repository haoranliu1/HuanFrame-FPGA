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
	input[9:0]                      wrusedw                     // from fifo write used words

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

reg [BURST_BITS:0] rd_return_cnt;
wire sdram_accept_window;

assign App_rd_addr = {App_rd_addr_r[ADDR_BITS - 1:0]};

assign sdram_accept_window = ~Sdr_busy && ~Sdr_init_ref_vld;
assign O_rd_busy = (state == S_READ_BURST || state == S_READ_BURST_END);//读指令期间
// Complete a burst only after all accepted commands have produced real data.
// A fixed latency is unsafe when refresh or write arbitration delays returns.
assign rd_burst_finish = (burst_cnt >= BURST_SIZE && rd_return_cnt >= BURST_SIZE);
assign read_finish = (state == S_END) ? 1'b1 : 1'b0;             //read finish at state 'S_END'
// Hold the burst request and counters during SDRAM refresh/busy cycles.
assign App_rd_en = App_rd_en_d0 && sdram_accept_window;
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
	if(rst)
		rd_return_cnt <= {(BURST_BITS + 1){1'b0}};
	else if(state == S_CHECK_FIFO)
		rd_return_cnt <= {(BURST_BITS + 1){1'b0}};
	else if(state == S_READ_BURST && Sdr_rd_en && rd_return_cnt < BURST_SIZE)
		rd_return_cnt <= rd_return_cnt + 1'b1;
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
				if(read_addr_index_d1 == 2'd0)
					App_rd_addr_r <= read_addr_0;
				else if(read_addr_index_d1 == 2'd1)
					App_rd_addr_r <= read_addr_1;
				else if(read_addr_index_d1 == 2'd2)
					App_rd_addr_r <= read_addr_2;
				else if(read_addr_index_d1 == 2'd3)
					App_rd_addr_r <= read_addr_3;
			end
		else if(App_rd_en)
			App_rd_addr_r <= App_rd_addr_r + 1'b1;
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
				else if(wrusedw < (FIFO_DEPTH - BURST_SIZE) && ~App_wr_busy && sdram_accept_window)
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
`timescale 1ns/1ps
// Separate video/read-clock and SDRAM-clock line cache. Requests are bundled
// data handshakes: descriptors stay stable until the matching toggle is ACKed.
// Two complete 640-pixel lines permit scale changes without reloading the TF.
module image_zoom_reader #(
    parameter ADDR_BITS=21
)(
    input rst, input mem_clk, input video_clk,
    input init_done, input mem_busy, input refresh_busy, input writer_busy,
    input display_active,
    output mem_read_en, output [ADDR_BITS-1:0] mem_read_addr,
    input mem_data_valid, input [31:0] mem_data,
    output reader_busy, output [8:0] buffered_words,
    input frame_req, output frame_ack,
    input [ADDR_BITS-1:0] frame_base,
    input [7:0] zoom_setting, input [7:0] pan_x, input [7:0] pan_y,
    input pixel_read, output [31:0] pixel_data,
    output stream_ready, output cache_empty,
    output reg [15:0] missed_pixels
);
    // Index bit 10 is the bank. Padding each row to1024 avoids divider logic.
    (* ram_style="bram" *) reg [23:0] lines [0:2047];
    reg [23:0] line_pixel;
    reg sample_valid;
    assign pixel_data={sample_valid ? line_pixel : 24'd0,8'd0};
    // Never gate pixel position advancement on cache readiness. A missed
    // line is explicitly black, so later lines can recover without shifting.
    assign stream_ready=!rst;
    assign frame_ack=frame_req;

    reg [1:0] request_toggle, request_valid;
    reg [8:0] request_row0,request_row1;
    reg [ADDR_BITS-1:0] request_base0,request_base1;
    reg [1:0] ack_toggle, ack_v0,ack_v1;
    reg [1:0] req_m0,req_m1,req_m2;
    reg [8:0] row0_m0,row1_m0,row0_m1,row1_m1;
    reg [ADDR_BITS-1:0] base0_m0,base1_m0,base0_m1,base1_m1;
    reg active_m0,active_m1,active_v0,active_v1;
    reg mem_state, fill_bank;
    reg [9:0] issued,returned;
    reg [ADDR_BITS-1:0] address;
    wire [1:0] pending=req_m2 ^ ack_toggle;
    assign buffered_words=(pending!=0 || mem_state) ? 9'd0 : 9'd511;
    assign reader_busy=mem_state;
    assign mem_read_en=mem_state && issued<10'd640 && !mem_busy && !refresh_busy;
    assign mem_read_addr=address;

    // Related PLL clocks have a substantial insertion-skew difference.
    // Sample the stable bundled request on the opposite memory edge, then
    // register it on rising edges. Every crossing stays statically timed.
    // Data gets two samples and the request gets three before use.
    always @(negedge mem_clk or posedge rst) begin
        if(rst) begin
            req_m0<=0;row0_m0<=0;row1_m0<=0;base0_m0<=0;base1_m0<=0;
        end else begin
            req_m0<=request_toggle;
            row0_m0<=request_row0;row1_m0<=request_row1;
            base0_m0<=request_base0;base1_m0<=request_base1;
        end
    end
    always @(posedge mem_clk or posedge rst) begin
        if(rst) begin
            req_m1<=0;req_m2<=0;active_m0<=0;active_m1<=0;
            row0_m1<=0;row1_m1<=0;base0_m1<=0;base1_m1<=0;
            ack_toggle<=0;mem_state<=0;fill_bank<=0;
            issued<=0;returned<=0;address<=0;
        end else begin
            req_m1<=req_m0;req_m2<=req_m1;
            row0_m1<=row0_m0;row1_m1<=row1_m0;
            base0_m1<=base0_m0;base1_m1<=base1_m0;
            active_m0<=display_active;active_m1<=active_m0;
            if(!mem_state) begin
                if(init_done && active_m1 && !writer_busy && !mem_busy && !refresh_busy && pending!=0) begin
                    fill_bank<=!pending[0];
                    address<=pending[0] ? base0_m1 + row0_m1*21'd640
                                             : base1_m1 + row1_m1*21'd640;
                    issued<=0;returned<=0;mem_state<=1;
                end
            end else begin
                if(mem_read_en) begin
                    issued<=issued+1'b1;
                    address<=address+1'b1;
                end
                if(mem_data_valid && returned<10'd640)
                    returned<=returned+1'b1;
                // Release the bus only after every actual return; never
                // infer data completion from accepted-command timing.
                if(issued==10'd640 && returned==10'd640) begin
                    ack_toggle[fill_bank]<=req_m2[fill_bank];
                    mem_state<=0;
                end
            end
        end
    end
    always @(posedge mem_clk) begin
        if(mem_state && mem_data_valid && returned<10'd640)
            lines[{fill_bank,returned}]<=mem_data[31:8];
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
    reg [9:0] step_q8;
    reg [9:0] viewport_w,viewport_h,dest_w,dest_h,left_pad,top_pad;
    reg [9:0] origin_x,origin_y;
    reg [ADDR_BITS-1:0] base_frame;
    reg configured,current_bank;
    reg [9:0] out_x,out_y;
    reg [18:0] source_x_q8,source_y_q8;
    wire [19:0] next_source_y={1'b0,source_y_q8}+step_q8;
    wire [10:0] next_unique=(step_q8>=256) ? next_source_y[18:8]
                                                          : {1'b0,source_y_q8[17:8]}+11'd1;
    wire [8:0] current_row=source_y_q8[18:8]>479 ? 9'd479 : source_y_q8[16:8];
    wire [8:0] prefetch_row=next_unique>479 ? 9'd479 : next_unique[8:0];
    wire [8:0] wanted0=current_bank ? prefetch_row : current_row;
    wire [8:0] wanted1=current_bank ? current_row : prefetch_row;
    wire valid0=request_valid[0] && ack_v1[0]==request_toggle[0]
                && request_row0==current_row && request_base0==base_frame;
    wire valid1=request_valid[1] && ack_v1[1]==request_toggle[1]
                && request_row1==current_row && request_base1==base_frame;
    wire current_ready=current_bank ? valid1 : valid0;
    wire inside_image=out_x>=left_pad && out_x<left_pad+dest_w
                     && out_y>=top_pad && out_y<top_pad+dest_h;
    wire [9:0] column=source_x_q8[18:8]>639 ? 10'd639 : source_x_q8[17:8];
    assign cache_empty=!current_ready;

    // A dedicated synchronous RAM read, followed by a valid mask, keeps
    // inference on true dual-clock BRAM rather than distributed LUT memory.
    always @(posedge video_clk)
        line_pixel<=lines[{current_bank,column}];

    always @(posedge video_clk or posedge rst) begin
        if(rst) begin
            request_toggle<=0;request_valid<=0;request_row0<=0;request_row1<=0;
            request_base0<=0;request_base1<=0;ack_v0<=0;ack_v1<=0;
            active_v0<=0;active_v1<=0;req_d<=0;
            setting_v0<=25;setting_v1<=25;px_v0<=128;px_v1<=128;py_v0<=128;py_v1<=128;
            pan_x_frame<=128;pan_y_frame<=128;
            setup_state<=0;divide_count<=0;percentage<=100;divisor<=100;
            quotient<=0;remainder<=0;step_q8<=256;
            viewport_w<=640;viewport_h<=480;dest_w<=640;dest_h<=480;
            left_pad<=0;top_pad<=0;origin_x<=0;origin_y<=0;base_frame<=0;
            configured<=0;current_bank<=0;out_x<=0;out_y<=0;
            source_x_q8<=0;source_y_q8<=0;sample_valid<=0;missed_pixels<=0;
        end else begin
            ack_v0<=ack_toggle;ack_v1<=ack_v0;
            active_v0<=display_active;active_v1<=active_v0;
            setting_v0<=zoom_setting;setting_v1<=setting_v0;
            px_v0<=pan_x;px_v1<=px_v0;py_v0<=pan_y;py_v1<=py_v0;
            req_d<=frame_req;
            sample_valid<=pixel_read && configured && active_v1 && inside_image && current_ready;
            if(frame_req && !req_d) begin
                // Delay one clock before latching base: top switches its
                // guarded front-buffer register on this same frame edge.
                setup_state<=1;configured<=0;out_x<=0;out_y<=0;missed_pixels<=0;
            end else begin
                case(setup_state)
                    1: begin
                        percentage<=9'd50+{setting_v1,1'b0};
                        divisor<=9'd50+{setting_v1,1'b0};
                        pan_x_frame<=px_v1;pan_y_frame<=py_v1;
                        base_frame<=frame_base;quotient<=16'd25600;
                        remainder<=0;divide_count<=0;setup_state<=2;
                    end
                    2: begin
                        quotient<=quotient_next;
                        remainder<=take ? trial-divisor : trial;
                        if(divide_count==15) begin step_q8<=quotient_next[9:0];setup_state<=3;end
                        else divide_count<=divide_count+1'b1;
                    end
                    3: begin
                        viewport_w<=(step_q8*20'd640)>>8;
                        viewport_h<=(step_q8*20'd480)>>8;
                        // Reuse the restoring divider for the destination
                        // dimensions. A multiply followed by constant division
                        // in one cycle exceeded the video-clock timing budget.
                        quotient<=percentage>=100 ? 16'd64000 : percentage*16'd640;
                        divisor<=100;remainder<=0;divide_count<=0;
                        setup_state<=4;
                    end
                    4: begin
                        quotient<=quotient_next;
                        remainder<=take ? trial-divisor : trial;
                        if(divide_count==15) setup_state<=5;
                        else divide_count<=divide_count+1'b1;
                    end
                    5: begin
                        dest_w<=quotient[9:0];
                        quotient<=percentage>=100 ? 16'd48000 : percentage*16'd480;
                        remainder<=0;divide_count<=0;setup_state<=6;
                    end
                    6: begin
                        quotient<=quotient_next;
                        remainder<=take ? trial-divisor : trial;
                        if(divide_count==15) setup_state<=7;
                        else divide_count<=divide_count+1'b1;
                    end
                    7: begin
                        dest_h<=quotient[9:0];setup_state<=8;
                    end
                    8: begin
                        origin_x<=percentage<=100 ? 10'd0 : (pan_x_frame==255 ? 640-viewport_w :
                                                                      ((640-viewport_w)*pan_x_frame)>>8);
                        origin_y<=percentage<=100 ? 10'd0 : (pan_y_frame==255 ? 480-viewport_h :
                                                                      ((480-viewport_h)*pan_y_frame)>>8);
                        left_pad<=(640-dest_w)>>1;top_pad<=(480-dest_h)>>1;
                        setup_state<=9;
                    end
                    9: begin
                        source_x_q8<={origin_x,8'd0};source_y_q8<={origin_y,8'd0};
                        current_bank<=0;configured<=1;setup_state<=0;
                    end
                    default: begin end
                endcase
                if(configured && active_v1) begin
                    if(ack_v1[0]==request_toggle[0] && (!request_valid[0] || request_row0!=wanted0 || request_base0!=base_frame)) begin
                        request_row0<=wanted0;request_base0<=base_frame;
                        request_toggle[0]<=~request_toggle[0];request_valid[0]<=1;
                    end
                    if(ack_v1[1]==request_toggle[1] && (!request_valid[1] || request_row1!=wanted1 || request_base1!=base_frame)) begin
                        request_row1<=wanted1;request_base1<=base_frame;
                        request_toggle[1]<=~request_toggle[1];request_valid[1]<=1;
                    end
                end
                if(pixel_read && configured) begin
                    if(inside_image && active_v1 && !current_ready && missed_pixels!=16'hffff)
                        missed_pixels<=missed_pixels+1'b1;
                    if(out_x==639) begin
                        out_x<=0;out_y<=out_y+1'b1;source_x_q8<={origin_x,8'd0};
                        if(out_y>=top_pad && out_y+1<top_pad+dest_h) begin
                            source_y_q8<=next_source_y[18:0];
                            if(next_source_y[18:8]!=source_y_q8[18:8]) current_bank<=~current_bank;
                        end
                    end else begin
                        out_x<=out_x+1'b1;
                        if(inside_image) source_x_q8<=source_x_q8+step_q8;
                    end
                end
            end
        end
    end
endmodule
