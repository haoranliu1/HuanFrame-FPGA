// Read-only BGM library, independent of BMP lifetime and slideshow state.
// The PC installer verifies the complete FAT chain and readback before emitting
// paired start sector, size and catalog ID to the screen. No FAT logic in FPGA.
// A short sector refill may preempt image reads ONLY at transaction boundaries.
module bgm_library_player #(
    parameter integer TIMEOUT_CYCLES=100_000_000
)(
    input clk,input rst,input init_done,input quiesce,
    input [1:0] mode,input [3:0] track,input play,input restart_toggle,
    input [31:0] configured_sector,configured_bytes,configured_id,input config_valid,
    output request,output [31:0] address,input ack,
    input [7:0] data,input valid,input sector_end,
    output urgent,output fifo_play,
    output reg flush_toggle,input flush_busy,
    input [10:0] fifo_level,input fifo_full,
    output reg sample_write,output reg [15:0] sample_data,
    output reg [4:0] track_count,output reg [3:0] fault,
    output ready
);
localparam LOCATE=0,HEADER_REQ=1,HEADER_READ=2,HEADER_CHECK=3,
           VALIDATE=4,ACTIVE=5,AUDIO_REQ=6,AUDIO_READ=7,FLUSH=8,ERROR=9,
           VALIDATE_END=10,SET_TRACK=11;
reg [3:0] state;
// UART configuration is frozen until reset; the valid bit crosses three stages.
wire [31:0] library_sector=configured_sector,library_bytes=configured_bytes;
reg [2:0] config_sync;
// Read only the selected descriptor. Re-read the 512-byte header on track
// changes instead of retaining 1024 bits of registers plus 16-way muxes.
reg [20:0] descriptor_offset;
reg [27:0] descriptor_samples;
reg [3:0] header_track,loaded_track;
reg descriptor_reserved;
reg [20:0] track_sectors;
reg header_bad;
reg header_compare_valid;
reg [7:0] header_actual_byte,header_expected_byte;
reg [15:0] header_sum,stored_sum;
reg [9:0] byte_count;
reg [27:0] cursor,selected_samples;
reg [31:0] selected_sector,audio_sector;
reg [8:0] transfer_samples;
reg [7:0] low_byte;
localparam TIMER_BITS=$clog2(TIMEOUT_CYCLES+1);
reg [TIMER_BITS-1:0] timer;
reg pending_reset;
reg [1:0] mode_m0,mode_m1,mode_seen;
reg [3:0] track_m0,track_m1,track_seen;
reg [2:0] play_sync,restart_sync;
reg restart_seen;
wire controls_changed=(mode_m1!=mode_seen)||(track_m1!=track_seen)||
                      (restart_sync[2]!=restart_seen);
wire [27:0] remaining=selected_samples-cursor;
wire [32:0] library_end={1'b0,configured_sector}+{12'd0,configured_bytes[31:9]};
wire header_request=(state==HEADER_REQ);
wire audio_request=(state==AUDIO_REQ) && !pending_reset && !controls_changed;
assign request=!quiesce && (header_request||audio_request);
assign address=header_request?library_sector:audio_sector;
assign urgent=(state==AUDIO_REQ) && fifo_level<512;
assign ready=(state==ACTIVE || state==AUDIO_REQ || state==AUDIO_READ || state==FLUSH);
assign fifo_play=ready && state!=FLUSH && mode_m1==2 && play_sync[2] &&
                 !quiesce && !pending_reset && !controls_changed && !flush_busy;
// Keep the timeout's enable independent of descriptor/address validation.
// It measures only idle clocks inside an already accepted sector transaction.
always @(posedge clk or posedge rst) begin
    if(rst) timer<=0;
    else if((state!=HEADER_READ && state!=AUDIO_READ) || valid) timer<=0;
    // Starts at zero and saturates exactly at the limit: equality is enough
    // and shares the terminal decode used by the state machine.
    else if(timer!=TIMEOUT_CYCLES) timer<=timer+1'b1;
end
always @(posedge clk or posedge rst) begin
    if(rst) begin
        mode_m0<=1;mode_m1<=1;mode_seen<=1;
        track_m0<=0;track_m1<=0;track_seen<=0;
        play_sync<=0;restart_sync<=0;restart_seen<=0;
        state<=LOCATE;track_count<=0;fault<=0;flush_toggle<=0;
        config_sync<=0;
        sample_write<=0;sample_data<=0;byte_count<=0;
        header_bad<=0;header_sum<=0;stored_sum<=0;
        header_compare_valid<=0;header_actual_byte<=0;header_expected_byte<=0;
        descriptor_offset<=0;descriptor_samples<=0;header_track<=0;loaded_track<=0;
        descriptor_reserved<=0;track_sectors<=0;
        cursor<=0;selected_samples<=0;selected_sector<=0;
        audio_sector<=0;transfer_samples<=0;low_byte<=0;pending_reset<=1;
    end else begin
        mode_m0<=mode;mode_m1<=mode_m0;
        track_m0<=track;track_m1<=track_m0;
        play_sync<={play_sync[1:0],play};
        restart_sync<={restart_sync[1:0],restart_toggle};
        config_sync<={config_sync[1:0],config_valid};
        sample_write<=0;
        // Compare after capturing both bytes. This removes the shared SD
        // data bus from the wide address-decoded header error path and also
        // accepts back-to-back valid bytes. All checked bytes precede 24;
        // their comparison drains long before the 512-byte header ends.
        header_compare_valid<=0;
        if(header_compare_valid && header_actual_byte!=header_expected_byte)
            header_bad<=1;
        if(controls_changed) begin
            mode_seen<=mode_m1;track_seen<=track_m1;restart_seen<=restart_sync[2];
            pending_reset<=1;
        end
        case(state)
        LOCATE:begin
            if(init_done && config_sync[2] && !quiesce) begin
                if(configured_sector==0 || configured_bytes<2048 || configured_bytes>32'h20000000 ||
                   configured_bytes[8:0]!=0 ||
                   library_end[32]) begin fault<=4;state<=ERROR;end
                else begin
                    state<=HEADER_REQ;
                end
            end
        end
        HEADER_REQ:if(ack) begin
            state<=HEADER_READ;byte_count<=0;header_sum<=0;
            header_bad<=0;
            header_track<=track_m1;descriptor_offset<=0;descriptor_samples<=0;
            descriptor_reserved<=0;
        end
        HEADER_READ:begin
            if(valid) begin
                byte_count<=byte_count+1'b1;
                if(byte_count!=28 && byte_count!=29) header_sum<=header_sum+data;
                header_actual_byte<=data;
                header_compare_valid<=(byte_count<24 && byte_count!=5);
                case(byte_count)
                    0:header_expected_byte<="B";
                    1:header_expected_byte<="G";
                    2:header_expected_byte<="M";
                    3:header_expected_byte<="1";
                    4,6:header_expected_byte<=1;
                    5:begin track_count<=data[4:0];if(data==0||data>16)header_bad<=1;end
                    7:header_expected_byte<=16;
                    8:header_expected_byte<=8'h80;
                    9:header_expected_byte<=8'hbb;
                    10,11,12,14,15:header_expected_byte<=0;
                    13:header_expected_byte<=2;
                    16:header_expected_byte<=library_bytes[7:0];
                    17:header_expected_byte<=library_bytes[15:8];
                    18:header_expected_byte<=library_bytes[23:16];
                    19:header_expected_byte<=library_bytes[31:24];
                    20:header_expected_byte<=configured_id[7:0];
                    21:header_expected_byte<=configured_id[15:8];
                    22:header_expected_byte<=configured_id[23:16];
                    23:header_expected_byte<=configured_id[31:24];
                    28:stored_sum[7:0]<=data;
                    29:stored_sum[15:8]<=data;
                    default:;
                endcase
                if(byte_count>=32 && byte_count<288 && byte_count[8:4]==({1'b0,header_track}+5'd2)) begin
                    case(byte_count[3:0])
                        0:descriptor_offset[7:0]<=data;
                        1:descriptor_offset[15:8]<=data;
                        2:begin descriptor_offset[20:16]<=data[4:0];if(data[7:5]!=0)descriptor_reserved<=1;end
                        3:if(data!=0)descriptor_reserved<=1;
                        4:descriptor_samples[7:0]<=data;
                        5:descriptor_samples[15:8]<=data;
                        6:descriptor_samples[23:16]<=data;
                        7:begin descriptor_samples[27:24]<=data[3:0];if(data[7:4]!=0)descriptor_reserved<=1;end
                        12,13,14,15:if(data!=0)descriptor_reserved<=1;
                    endcase
                end
            end
            if(sector_end) begin
                if(byte_count!=512) begin fault<=6;state<=ERROR;end
                else state<=HEADER_CHECK;
            end else if(timer==TIMEOUT_CYCLES) begin fault<=1;state<=ERROR;end
        end
        HEADER_CHECK:begin
            if(header_bad || header_sum!=stored_sum) begin fault<=6;state<=ERROR;end
            else state<=VALIDATE;
        end
        VALIDATE:begin
            if(header_track>=track_count) begin
                selected_samples<=0;loaded_track<=header_track;fault<=7;state<=ACTIVE;
            end else if(descriptor_offset==0 || descriptor_samples<1024 || descriptor_reserved)
                begin fault<=6;state<=ERROR;end
            else begin track_sectors<=({1'b0,descriptor_samples}+29'd255)>>8;state<=VALIDATE_END;end
        end
        VALIDATE_END:begin
            if(track_sectors>(library_bytes>>9) ||
               descriptor_offset>((library_bytes>>9)-track_sectors)) begin fault<=6;state<=ERROR;end
            else state<=SET_TRACK;
        end
        SET_TRACK:begin
            loaded_track<=header_track;selected_samples<=descriptor_samples;
            selected_sector<=library_sector+descriptor_offset;fault<=0;state<=ACTIVE;
        end
        ACTIVE:begin
            if((pending_reset || controls_changed) && !flush_busy) begin
                if(track_m1!=loaded_track) state<=HEADER_REQ;
                else begin
                    flush_toggle<=~flush_toggle;state<=FLUSH;
                    pending_reset<=0;cursor<=0;
                end
            end else if(!quiesce && mode_m1==2 && play_sync[2] &&
                        // Level is registered: reserve one extra sample for
                        // a write since the estimate, plus a full 256-sample sector.
                        !flush_busy && fifo_level<=11'd767 && selected_samples!=0) begin
                audio_sector<=selected_sector+(cursor>>8);
                transfer_samples<=(remaining>=256)?9'd256:remaining[8:0];
                state<=AUDIO_REQ;
            end
        end
        FLUSH:if(!flush_busy && !controls_changed) state<=ACTIVE;
        AUDIO_REQ:begin
            // Once accepted, always drain the transaction even if stop/seek
            // arrives on the same edge. pending_reset suppresses its PCM.
            if(ack) begin state<=AUDIO_READ;byte_count<=0;end
            else if(pending_reset || controls_changed || quiesce) state<=ACTIVE;
        end
        AUDIO_READ:begin
            if(valid) begin
                byte_count<=byte_count+1'b1;
                if(!byte_count[0]) low_byte<=data;
                else if((byte_count>>1)<transfer_samples && !pending_reset && !controls_changed) begin
                    if(fifo_full || flush_busy) begin fault<=8;pending_reset<=1;end
                    else begin sample_write<=1;sample_data<={data,low_byte};end
                end
            end
            if(sector_end) begin
                if(byte_count!=512) begin fault<=6;state<=ERROR;end
                else begin
                    if(remaining<=256) cursor<=0;
                    else cursor<=cursor+256;
                    state<=ACTIVE;
                end
            end else if(timer==TIMEOUT_CYCLES) begin fault<=1;state<=ERROR;end
        end
        ERROR:;
        default:state<=ERROR;
        endcase
    end
end
endmodule
