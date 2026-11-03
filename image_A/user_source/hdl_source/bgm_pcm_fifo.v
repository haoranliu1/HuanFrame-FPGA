// 1024 signed mono samples, two inferred 9K RAMs. Both domains acknowledge
// a flush before writes resume; no unsynchronised pointer reset on track change.
module bgm_pcm_fifo(
    input write_clk, input read_clk, input rst,
    input flush_toggle, output flush_busy,
    input write_en, input [15:0] write_data,
    output reg [10:0] write_level, output write_full,
    input sample_tick, input play, input [6:0] volume,
    output reg audio_valid, output reg [23:0] audio_sample,
    output reg [31:0] underruns
);
reg [15:0] memory[0:1023];
reg [10:0] wbin,wgray,rbin,rgray;
(* async_reg="true" *) reg [10:0] rgray_w0,rgray_w1,wgray_r0,wgray_r1;
(* async_reg="true" *) reg [2:0] flush_read_sync,ack_write_sync;
reg ack_read, flush_write_seen;
reg [2:0] settle;
reg [15:0] ram_q;
reg primed;
reg [2:0] play_sync;
reg [6:0] volume_m0,volume_m1;
reg signed [23:0] product;
reg signed [30:0] gain;
reg product_valid,gain_valid;
wire [10:0] rbin_sync,wbin_sync;
genvar bit_idx;
generate for(bit_idx=0;bit_idx<11;bit_idx=bit_idx+1) begin: gray_decode
    assign rbin_sync[bit_idx]=^(rgray_w1 >> bit_idx);
    assign wbin_sync[bit_idx]=^(wgray_r1 >> bit_idx);
end endgenerate
wire [10:0] current_write_level=wbin-rbin_sync;
// External scheduling sees a registered estimate. Keep the actual full guard
// combinational so delayed telemetry can never cause an out-of-bounds write.
// Standard depth-1024 asynchronous FIFO full comparison: one complete binary
// pointer lap toggles the two highest Gray bits. Avoid decode/subtract here.
assign write_full=(wgray == {~rgray_w1[10:9],rgray_w1[8:0]});
assign flush_busy=(flush_write_seen!=flush_toggle) ||
                  (ack_write_sync[2]!=flush_toggle) || (settle!=0);
wire empty=(rgray==wgray_r1);
wire [10:0] read_level=wbin_sync-rbin;
wire read_flushing=(flush_read_sync[2]!=ack_read);
wire signed [7:0] volume_signed={1'b0,volume_m1};
wire signed [30:0] product_ext={{7{product[23]}},product};
always @(posedge write_clk or posedge rst) begin
    if(rst) begin
        wbin<=0;wgray<=0;rgray_w0<=0;rgray_w1<=0;
        ack_write_sync<=0;flush_write_seen<=0;settle<=0;write_level<=0;
    end else begin
        rgray_w0<=rgray;rgray_w1<=rgray_w0;
        ack_write_sync<={ack_write_sync[1:0],ack_read};
        write_level<=current_write_level;
        if(flush_write_seen!=flush_toggle) begin
            flush_write_seen<=flush_toggle;
            wbin<=0;wgray<=0;settle<=7;
        end else if(ack_write_sync[2]==flush_toggle && settle!=0)
            settle<=settle-1'b1;
        if(write_en && !write_full && !flush_busy) begin
            memory[wbin[9:0]]<=write_data;
            wbin<=wbin+1'b1;
            wgray<=((wbin+1'b1)>>1)^(wbin+1'b1);
        end
    end
end
always @(posedge read_clk) ram_q<=memory[rbin[9:0]];
always @(posedge read_clk or posedge rst) begin
    if(rst) begin
        rbin<=0;rgray<=0;wgray_r0<=0;wgray_r1<=0;
        flush_read_sync<=0;ack_read<=0;primed<=0;play_sync<=0;
        volume_m0<=20;volume_m1<=20;product<=0;gain<=0;
        product_valid<=0;gain_valid<=0;audio_valid<=0;
        audio_sample<=0;underruns<=0;
    end else begin
        wgray_r0<=wgray;wgray_r1<=wgray_r0;
        flush_read_sync<={flush_read_sync[1:0],flush_toggle};
        play_sync<={play_sync[1:0],play};
        volume_m0<=volume;volume_m1<=volume_m0;
        audio_valid<=gain_valid;
        product_valid<=0;gain_valid<=product_valid;
        if(product_valid) gain<=product_ext+(product_ext<<<3)+(product_ext<<<5);
        if(gain_valid) begin
            if(gain>31'sd134213632) audio_sample<=24'h7fff00;
            else if(gain< -31'sd134217728) audio_sample<=24'h800000;
            else audio_sample<=(gain>>>12)<<<8;
        end
        if(read_flushing) begin
            rbin<=0;rgray<=0;ack_read<=flush_read_sync[2];primed<=0;
            product<=0;gain<=0;product_valid<=0;gain_valid<=0;
            audio_valid<=0;audio_sample<=0;
        end else if(sample_tick) begin
            product_valid<=1;
            if(play_sync[2] && !empty) begin
                // Start only with at least 512 samples; resume keeps the queue.
                if(primed || read_level>=11'd512) begin
                    primed<=1;
                    product<=$signed(ram_q)*volume_signed;
                    rbin<=rbin+1'b1;
                    rgray<=((rbin+1'b1)>>1)^(rbin+1'b1);
                end else product<=0;
            end else begin
                product<=0;
                if(play_sync[2] && primed && empty) begin
                    underruns<=underruns+1'b1;
                    primed<=0;
                end
            end
        end
    end
end
endmodule
