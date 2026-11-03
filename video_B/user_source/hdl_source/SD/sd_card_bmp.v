module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [4:0]   SCAN_TARGET_COUNT = 5'd1,
    parameter integer SOURCE_WIDTH = 512,
    parameter integer SOURCE_HEIGHT = 384,
    parameter integer AUDIO_SAMPLES_PER_FRAME = 3000,
    parameter integer AUDIO_FIFO_MODE = 0
)(
    input                       clk,
    input                       rst,
    input                       quiesce,
    output                      quiesced,
    input                       audio_frame_done_toggle,
    input [2:0]                 audio_fifo_head_gray,
    input                       audio_fifo_write_ready,
    input                       audio_fifo_frame_ready,
    output                      audio_fifo_clear,
    output                      audio_fifo_commit,
    output                      audio_fifo_abort,
    output reg [2:0]            audio_display_sequence_gray,
    output reg                  audio_manual_seek_toggle,
    output                      audio_write_en,
    output [11:0]               audio_write_addr,
    output [15:0]               audio_write_data,
    input                       key_next,
    input                       key_auto,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg                  display_valid,
    output      [3:0]           state_code,
    output      [3:0]           image_index_dbg,
    output                      auto_play_dbg,

    input                       key_next_toggle,
    input                       key_prev_toggle,
    input                       key_auto_toggle,
    input                       touch_auto_start_toggle,
    input                       touch_auto_stop_toggle,
    input                       interval_toggle,
    input  [3:0]                interval_value,

    input                       write_finish_toggle,
    input  [1:0]                front_buf_idx,
    output reg [1:0]            write_buf_idx,
    output reg [1:0]            disp_buf_idx,
    output [3:0]                interval_seconds_dbg,
    output [1:0]                reservoir_level_gray_dbg,

    output                      write_req,
    input                       write_req_ack,
    input                       write_fifo_full,
    output                      write_en,
    output [31:0]               write_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO
);

localparam [31:0] SOURCE_TIMEOUT_CYCLES = 32'd200_000_000;
localparam [31:0] WRITE_TIMEOUT_CYCLES  = 32'd200_000_000;
// Preserve the verified four-sector bounded CMD18 reservoir path. Source
// geometry and PCM stride must agree with the matched RVA media profile.
localparam [31:0] FRAME_PERIOD_CYCLES   = CLK_FREQ_HZ / 8;
localparam [18:0] FRAME_PIXEL_COUNT     = 19'd307200;
localparam [2:0]  PREFILL_FRAMES        = 3'd3;
localparam [31:0] VIDEO_FRAME_SECTORS   = SOURCE_WIDTH * SOURCE_HEIGHT / 256 + 12;
localparam [31:0] DIAG_START_FRAME      = 32'd0;
localparam [31:0] DIAG_START_SECTOR_OFF = 32'd0;
localparam [16:0] RETRY_DELAY_CYCLES    = 17'd100000;

wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [15:0]      sd_sec_read_count;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire             sd_init_done;
wire [3:0]       reader_state_code;
wire             reader_ready;
wire             sd_bus_idle;
wire             sd_ncs_raw;
wire             scan_done;
wire             scan_found_valid;
wire [31:0]      scan_found_sector;
wire [4:0]       scan_found_total;
wire [31:0]      reader_frame_count;
wire [7:0]       reader_video_fps;
wire [31:0]      reader_video_data_sector;
wire [31:0]      reader_video_last_frame_sector;

wire             source_pixel_valid;
wire [23:0]      source_pixel;
wire [15:0]      source_pixel_x;
wire             source_row_end;
wire             image_meta_valid;
wire [15:0]      image_width;
wire [15:0]      image_height;
wire             scale_layout_ready;
wire             scale_input_ready;
wire             scale_start;
wire             scaler_write_en;
wire [31:0]      scaler_write_data;
wire             scaler_frame_done;
wire             scaler_write_stall;

reg              scan_start_pulse;
reg              load_start_pulse;
reg [31:0]       load_sector;
reg              scan_kicked;
reg              video_found;
reg [31:0]       video_frame_count;
reg [31:0]       video_data_sector;
reg [31:0]       video_last_frame_sector;
reg [7:0]        video_fps;

reg              first_frame_committed;
reg              auto_play_en;
reg [31:0]       frame_timer;
reg [31:0]       current_frame_idx;
reg [31:0]       current_frame_sector;
reg [31:0]       load_frame_idx;
reg [31:0]       load_frame_sector;
reg [31:0]       back_frame_idx;
reg [31:0]       back_frame_sector;
reg [1:0]        pending_buf_idx;
reg [1:0]        back_buf_idx;
reg              back_ready;
reg              request_valid;
reg [31:0]       request_frame_idx;
reg [31:0]       request_frame_sector;
reg              load_busy;
reg [31:0]       load_timeout_cnt;
reg              load_abort;
reg              source_done_seen;
reg              audio_done_seen;
wire             reader_audio_done;
reg [2:0]        audio_done_sync;
reg              audio_advance_pending;
reg [2:0]        audio_head_sync0;
reg [2:0]        audio_head_sync1;
reg [2:0]        audio_display_sequence;
wire [2:0]      audio_head_binary;
wire [2:0]      audio_video_debt;
reg [1:0]        quiesce_sync;
reg              write_done_seen;
reg [3:0]        supervisor_fault_code;

reg [2:0]        wrfin_tgl_sync;
reg [2:0]        key_next_tgl_sync;
reg [2:0]        key_prev_tgl_sync;
reg [2:0]        key_auto_tgl_sync;
reg [2:0]        touch_auto_start_tgl_sync;
reg [2:0]        touch_auto_stop_tgl_sync;
wire             write_finish_pulse;
wire             key_next_press;
wire             key_prev_press;
wire             key_auto_press;
wire             touch_auto_start_press;
wire             touch_auto_stop_press;

reg              write_stage0_valid;
reg [31:0]       write_stage0_data;
reg              write_stage1_valid;
reg [31:0]       write_stage1_data;
reg              write_stage_overflow;
wire             write_stage_pop;

reg [18:0]       scaler_pixel_count;
reg              scaler_pixel_count_good;

// Four complete 640x480 output frames form a small reservoir. One bank is
// displayed while up to three banks wait in FIFO order. This keeps the proven
// frame DMA unchanged and validates prefill/refill behaviour before adding a
// separate compact-source SDRAM client.
reg [2:0]        buffered_count;
reg [1:0]        ring_write_idx;
reg [1:0]        ring_read_idx;
reg [31:0]       next_load_frame_idx;
reg [31:0]       next_load_frame_sector;
reg [31:0]       slot_frame_idx [0:3];
reg [31:0]       slot_frame_sector [0:3];
reg              playback_started;
reg              manual_next_pending;
reg              recovery_hold;
reg [16:0]       retry_delay_cnt;
reg [1:0]        load_retry_count;

wire             load_complete_event;
wire             load_success_event;
wire             queue_pop_event;
wire [1:0]       empty_refill_idx;

assign write_stage_pop = write_stage0_valid && !write_fifo_full;
assign write_en         = write_stage_pop;
assign write_data       = write_stage0_data;
assign scaler_write_stall = write_stage0_valid;
assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
assign key_next_press = key_next_tgl_sync[2] ^ key_next_tgl_sync[1];
assign key_prev_press = key_prev_tgl_sync[2] ^ key_prev_tgl_sync[1];
assign key_auto_press = key_auto_tgl_sync[2] ^ key_auto_tgl_sync[1];
assign touch_auto_start_press = touch_auto_start_tgl_sync[2] ^
                                touch_auto_start_tgl_sync[1];
assign touch_auto_stop_press = touch_auto_stop_tgl_sync[2] ^
                               touch_auto_stop_tgl_sync[1];
assign image_index_dbg = current_frame_idx[3:0];
assign auto_play_dbg = auto_play_en;
assign interval_seconds_dbg = 4'd0;
// Export the 0..3 queue occupancy in Gray code so the video-clock OSD can
// synchronize it without displaying an invalid intermediate binary value.
assign reservoir_level_gray_dbg = {
    buffered_count[1], buffered_count[1] ^ buffered_count[0]
};
assign state_code = (supervisor_fault_code != 4'd0) ?
                    supervisor_fault_code : reader_state_code;
assign load_complete_event = load_busy &&
                             audio_done_seen &&
                             source_done_seen &&
                             (write_done_seen || write_finish_pulse);
assign load_success_event = load_complete_event &&
                            source_done_seen &&
                            scaler_pixel_count_good &&
                            !write_stage_overflow &&
                            (!AUDIO_FIFO_MODE || audio_fifo_frame_ready);
assign audio_head_binary = {audio_head_sync1[2],
                            audio_head_sync1[2] ^ audio_head_sync1[1],
                            audio_head_sync1[2] ^ audio_head_sync1[1] ^ audio_head_sync1[0]};
assign audio_video_debt = audio_head_binary - audio_display_sequence;
assign audio_fifo_clear = !sd_init_done || !video_found;
assign audio_fifo_commit = load_success_event;
assign audio_fifo_abort = load_abort || (load_complete_event && !load_success_event);
assign quiesced = quiesce_sync[1] && !load_busy && reader_ready &&
                   sd_bus_idle && !sd_sec_read && !write_req &&
                   !write_stage0_valid && !write_stage1_valid &&
                   !load_start_pulse && !scan_start_pulse;
// Only deselect after CMD18 data, CMD12/R1b and both write bridge entries
// have drained. Do not change CS between a multi-read and its stop command.
assign SD_nCS = quiesced ? 1'b1 : sd_ncs_raw;
assign queue_pop_event = !quiesce_sync[1] && playback_started && display_valid &&
                         (buffered_count != 3'd0) &&
                         ((manual_next_pending && (front_buf_idx == disp_buf_idx)) ||
                          (auto_play_en &&
                           (AUDIO_FIFO_MODE ?
                            ((audio_video_debt != 3'd0) && (audio_video_debt <= 3'd4)) :
                            (!recovery_hold && audio_advance_pending))));
// Audio is the automatic-play master. A slow video handoff must not hold a
// complete next PCM bank hostage. Video may catch up to the latest committed
// frame at vblank. The loader still protects BOTH the real front bank and
// requested display/audio bank, and consumes only fully committed queue slots.
// Manual stepping keeps its original display-ack ordering.

// If the queue reaches zero, the old ring pointer can eventually coincide
// with the frame still scanned by HDMI. Select another bank and realign both
// queue pointers so an empty reservoir always has a valid refill path.
assign empty_refill_idx =
    ((front_buf_idx + 2'd1) == disp_buf_idx) ?
    (front_buf_idx + 2'd2) : (front_buf_idx + 2'd1);

function [31:0] next_frame_index;
    input [31:0] current_index;
    input [31:0] frame_count;
    begin
        if (frame_count <= 32'd1)
            next_frame_index = 32'd0;
        else if ((current_index + 32'd1) >= frame_count)
            next_frame_index = 32'd0;
        else
            next_frame_index = current_index + 32'd1;
    end
endfunction

function [31:0] prev_frame_index;
    input [31:0] current_index;
    input [31:0] frame_count;
    begin
        if (frame_count <= 32'd1)
            prev_frame_index = 32'd0;
        else if (current_index == 32'd0)
            prev_frame_index = frame_count - 32'd1;
        else
            prev_frame_index = current_index - 32'd1;
    end
endfunction

function [31:0] next_frame_sector;
    input [31:0] current_index;
    input [31:0] current_sector;
    input [31:0] frame_count;
    begin
        if ((frame_count <= 32'd1) ||
            ((current_index + 32'd1) >= frame_count))
            next_frame_sector = video_data_sector;
        else
            next_frame_sector = current_sector + VIDEO_FRAME_SECTORS;
    end
endfunction

function [31:0] prev_frame_sector;
    input [31:0] current_index;
    input [31:0] current_sector;
    begin
        if (current_index == 32'd0)
            prev_frame_sector = video_last_frame_sector;
        else
            prev_frame_sector = current_sector - VIDEO_FRAME_SECTORS;
    end
endfunction

function [1:0] next_buffer;
    input [1:0] current_buffer;
    begin
        next_buffer = (current_buffer == 2'd0) ? 2'd1 : 2'd0;
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        write_stage0_valid  <= 1'b0;
        write_stage0_data   <= 32'd0;
        write_stage1_valid  <= 1'b0;
        write_stage1_data   <= 32'd0;
        write_stage_overflow <= 1'b0;
    end else if (!sd_init_done || load_abort || scale_start) begin
        write_stage0_valid  <= 1'b0;
        write_stage0_data   <= 32'd0;
        write_stage1_valid  <= 1'b0;
        write_stage1_data   <= 32'd0;
        write_stage_overflow <= 1'b0;
    end else begin
        case ({scaler_write_en, write_stage_pop})
            2'b00: ;
            2'b01: begin
                if (write_stage1_valid) begin
                    write_stage0_valid <= 1'b1;
                    write_stage0_data  <= write_stage1_data;
                    write_stage1_valid <= 1'b0;
                end else begin
                    write_stage0_valid <= 1'b0;
                end
            end
            2'b10: begin
                if (!write_stage0_valid) begin
                    write_stage0_valid <= 1'b1;
                    write_stage0_data  <= scaler_write_data;
                end else if (!write_stage1_valid) begin
                    write_stage1_valid <= 1'b1;
                    write_stage1_data  <= scaler_write_data;
                end else begin
                    write_stage_overflow <= 1'b1;
                end
            end
            2'b11: begin
                if (write_stage1_valid) begin
                    write_stage0_valid <= 1'b1;
                    write_stage0_data  <= write_stage1_data;
                    write_stage1_valid <= 1'b1;
                    write_stage1_data  <= scaler_write_data;
                end else begin
                    write_stage0_valid <= 1'b1;
                    write_stage0_data  <= scaler_write_data;
                end
            end
        endcase
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        scaler_pixel_count      <= 19'd0;
        scaler_pixel_count_good <= 1'b0;
    end else if (!sd_init_done || load_abort || scale_start) begin
        scaler_pixel_count      <= 19'd0;
        scaler_pixel_count_good <= 1'b0;
    end else begin
        if (load_busy && scaler_write_en)
            scaler_pixel_count <= scaler_pixel_count + 19'd1;
        if (load_busy && scaler_frame_done)
            scaler_pixel_count_good <=
                ((scaler_pixel_count + (scaler_write_en ? 19'd1 : 19'd0)) ==
                 FRAME_PIXEL_COUNT);
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync             <= 3'b000;
        key_next_tgl_sync          <= 3'b000;
        key_prev_tgl_sync          <= 3'b000;
        key_auto_tgl_sync          <= 3'b000;
        touch_auto_start_tgl_sync  <= 3'b000;
        touch_auto_stop_tgl_sync   <= 3'b000;
        scan_start_pulse           <= 1'b0;
        load_start_pulse           <= 1'b0;
        load_sector                <= 32'd0;
        scan_kicked                <= 1'b0;
        video_found                <= 1'b0;
        video_frame_count          <= 32'd0;
        video_data_sector          <= 32'd0;
        video_last_frame_sector     <= 32'd0;
        video_fps                  <= 8'd0;
        first_frame_committed      <= 1'b0;
        auto_play_en               <= 1'b0;
        frame_timer                <= 32'd0;
        current_frame_idx          <= 32'd0;
        current_frame_sector       <= 32'd0;
        load_frame_idx             <= 32'd0;
        load_frame_sector          <= 32'd0;
        back_frame_idx             <= 32'd0;
        back_frame_sector          <= 32'd0;
        pending_buf_idx            <= 2'd0;
        back_buf_idx               <= 2'd0;
        back_ready                 <= 1'b0;
        request_valid              <= 1'b0;
        request_frame_idx          <= 32'd0;
        request_frame_sector       <= 32'd0;
        load_busy                  <= 1'b0;
        load_timeout_cnt           <= 32'd0;
        load_abort                 <= 1'b0;
        source_done_seen           <= 1'b0;
        write_done_seen            <= 1'b0;
        supervisor_fault_code      <= 4'd0;
        display_valid              <= 1'b0;
        write_buf_idx              <= 2'd0;
        disp_buf_idx               <= 2'd0;
        buffered_count             <= 3'd0;
        ring_write_idx             <= 2'd0;
        ring_read_idx              <= 2'd0;
        next_load_frame_idx        <= 32'd0;
        next_load_frame_sector     <= 32'd0;
        slot_frame_idx[0]          <= 32'd0;
        slot_frame_idx[1]          <= 32'd0;
        slot_frame_idx[2]          <= 32'd0;
        slot_frame_idx[3]          <= 32'd0;
        slot_frame_sector[0]       <= 32'd0;
        slot_frame_sector[1]       <= 32'd0;
        slot_frame_sector[2]       <= 32'd0;
        slot_frame_sector[3]       <= 32'd0;
        playback_started           <= 1'b0;
        manual_next_pending        <= 1'b0;
        recovery_hold              <= 1'b0;
        retry_delay_cnt            <= 17'd0;
        load_retry_count           <= 2'd0;
        audio_done_seen            <= 1'b0;
        audio_done_sync            <= 3'd0;
        audio_advance_pending      <= 1'b0;
        audio_head_sync0           <= 3'd0;
        audio_head_sync1           <= 3'd0;
        audio_display_sequence     <= 3'd0;
        audio_display_sequence_gray <= 3'd0;
        audio_manual_seek_toggle   <= 1'b0;
        quiesce_sync               <= 2'd0;
    end else begin
        quiesce_sync <= {quiesce_sync[0], quiesce};
        audio_done_sync <= {audio_done_sync[1:0], audio_frame_done_toggle};
        audio_head_sync0 <= audio_fifo_head_gray;
        audio_head_sync1 <= audio_head_sync0;
        if (audio_done_sync[2] ^ audio_done_sync[1])
            audio_advance_pending <= 1'b1;
        if (queue_pop_event || !playback_started)
            audio_advance_pending <= 1'b0;
        if (load_start_pulse || load_abort || !sd_init_done)
            audio_done_seen <= 1'b0;
        else if (load_busy && reader_audio_done)
            audio_done_seen <= 1'b1;
        wrfin_tgl_sync <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        key_next_tgl_sync <= {key_next_tgl_sync[1:0], key_next_toggle};
        key_prev_tgl_sync <= {key_prev_tgl_sync[1:0], key_prev_toggle};
        key_auto_tgl_sync <= {key_auto_tgl_sync[1:0], key_auto_toggle};
        touch_auto_start_tgl_sync <= {touch_auto_start_tgl_sync[1:0],
                                      touch_auto_start_toggle};
        touch_auto_stop_tgl_sync <= {touch_auto_stop_tgl_sync[1:0],
                                     touch_auto_stop_toggle};
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;
        load_abort       <= 1'b0;

        if (!sd_init_done) begin
            scan_kicked           <= 1'b0;
            video_found           <= 1'b0;
            video_frame_count     <= 32'd0;
            video_data_sector     <= 32'd0;
            video_last_frame_sector <= 32'd0;
            video_fps             <= 8'd0;
            first_frame_committed <= 1'b0;
            auto_play_en          <= 1'b0;
            frame_timer           <= 32'd0;
            current_frame_idx     <= 32'd0;
            current_frame_sector  <= 32'd0;
            load_frame_idx        <= 32'd0;
            load_frame_sector     <= 32'd0;
            back_frame_idx        <= 32'd0;
            back_frame_sector     <= 32'd0;
            back_ready            <= 1'b0;
            request_valid         <= 1'b0;
            request_frame_idx     <= 32'd0;
            request_frame_sector  <= 32'd0;
            load_busy             <= 1'b0;
            load_timeout_cnt      <= 32'd0;
            source_done_seen      <= 1'b0;
            write_done_seen       <= 1'b0;
            supervisor_fault_code <= 4'd0;
            display_valid         <= 1'b0;
            write_buf_idx         <= 2'd0;
            disp_buf_idx          <= 2'd0;
            buffered_count        <= 3'd0;
            ring_write_idx        <= 2'd0;
            ring_read_idx         <= 2'd0;
            next_load_frame_idx   <= 32'd0;
            next_load_frame_sector <= 32'd0;
            playback_started      <= 1'b0;
            manual_next_pending   <= 1'b0;
            recovery_hold         <= 1'b0;
            retry_delay_cnt       <= 17'd0;
            load_retry_count      <= 2'd0;
            audio_display_sequence <= 3'd0;
            audio_display_sequence_gray <= 3'd0;
            audio_manual_seek_toggle <= 1'b0;
        end else begin
            if (retry_delay_cnt != 17'd0)
                retry_delay_cnt <= retry_delay_cnt - 17'd1;

            if (!quiesce_sync[1] && !scan_kicked && reader_ready) begin
                scan_start_pulse      <= 1'b1;
                scan_kicked           <= 1'b1;
                supervisor_fault_code <= 4'd0;
            end

            if (scan_found_valid) begin
                video_found       <= 1'b1;
                video_frame_count <= reader_frame_count;
                video_data_sector <= reader_video_data_sector;
                video_last_frame_sector <= reader_video_last_frame_sector;
                video_fps         <= reader_video_fps;
                if (reader_frame_count > DIAG_START_FRAME) begin
                    next_load_frame_idx <= DIAG_START_FRAME;
                    next_load_frame_sector <= reader_video_data_sector +
                                              DIAG_START_SECTOR_OFF;
                end else begin
                    next_load_frame_idx <= 32'd0;
                    next_load_frame_sector <= reader_video_data_sector;
                end
                load_retry_count <= 2'd0;
            end

            if (quiesce_sync[1]) begin
                auto_play_en <= 1'b0;
                manual_next_pending <= 1'b0;
            end else if (key_next_press) begin
                auto_play_en       <= 1'b0;
                manual_next_pending <= 1'b1;
                frame_timer        <= 32'd0;
            end else if (key_prev_press) begin
                // The reservoir is forward-only in this first validation
                // build. Treat previous as pause; no queued frame is lost.
                auto_play_en       <= 1'b0;
                manual_next_pending <= 1'b0;
                frame_timer        <= 32'd0;
            end else if (touch_auto_stop_press) begin
                auto_play_en        <= 1'b0;
                manual_next_pending <= 1'b0;
                frame_timer         <= 32'd0;
            end else if (touch_auto_start_press) begin
                auto_play_en        <= 1'b1;
                manual_next_pending <= 1'b0;
                frame_timer         <= 32'd0;
            end else if (key_auto_press) begin
                auto_play_en        <= ~auto_play_en;
                manual_next_pending <= 1'b0;
                frame_timer         <= 32'd0;
            end

            if (auto_play_en && display_valid) begin
                if (frame_timer < FRAME_PERIOD_CYCLES)
                    frame_timer <= frame_timer + 32'd1;
            end else if (!auto_play_en) begin
                frame_timer <= 32'd0;
            end

            if (load_busy && scaler_frame_done)
                source_done_seen <= 1'b1;
            if (load_busy && write_finish_pulse)
                write_done_seen <= 1'b1;

            if (load_complete_event) begin
                load_busy        <= 1'b0;
                load_timeout_cnt <= 32'd0;
                source_done_seen <= 1'b0;
                write_done_seen  <= 1'b0;

                if (!scaler_pixel_count_good) begin
                    supervisor_fault_code <= 4'd8;
                end else if (write_stage_overflow) begin
                    supervisor_fault_code <= 4'd9;
                end else if (AUDIO_FIFO_MODE && !audio_fifo_frame_ready) begin
                    supervisor_fault_code <= 4'd9;
                end else begin
                    slot_frame_idx[pending_buf_idx] <= load_frame_idx;
                    slot_frame_sector[pending_buf_idx] <= load_frame_sector;
                    ring_write_idx <= ring_write_idx + 2'd1;
                    next_load_frame_idx <=
                        next_frame_index(load_frame_idx, video_frame_count);
                    next_load_frame_sector <=
                        next_frame_sector(load_frame_idx, load_frame_sector,
                                          video_frame_count);
                    supervisor_fault_code <= 4'd0;
                    load_retry_count <= 2'd0;
                end
            end else if (load_busy) begin
                if (scaler_frame_done && !source_done_seen) begin
                    load_timeout_cnt <= 32'd0;
                end else if ((!source_done_seen &&
                              (load_timeout_cnt >= SOURCE_TIMEOUT_CYCLES)) ||
                             ( source_done_seen &&
                              (load_timeout_cnt >= WRITE_TIMEOUT_CYCLES))) begin
                    load_busy        <= 1'b0;
                    load_timeout_cnt <= 32'd0;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    load_abort       <= 1'b1;
                    recovery_hold    <= 1'b1;
                    retry_delay_cnt  <= RETRY_DELAY_CYCLES;
                    if (load_retry_count == 2'd2) begin
                        load_retry_count <= 2'd3;
                        scan_kicked      <= 1'b0;
                        video_found      <= 1'b0;
                        if (AUDIO_FIFO_MODE) begin
                            // Flush both independent timelines together after
                            // a rescan; never replay stale queued PCM as new video.
                            playback_started <= 1'b0;
                            display_valid <= 1'b0;
                            auto_play_en <= 1'b0;
                            buffered_count <= 3'd0;
                            ring_write_idx <= 2'd0;
                            ring_read_idx <= 2'd0;
                            audio_display_sequence <= 3'd0;
                            audio_display_sequence_gray <= 3'd0;
                        end
                    end else begin
                        load_retry_count <= load_retry_count + 2'd1;
                    end
                    if (write_stage_overflow)
                        supervisor_fault_code <= 4'd9;
                    else if (source_done_seen && !scaler_pixel_count_good)
                        supervisor_fault_code <= 4'd8;
                    else
                        supervisor_fault_code <= 4'd7;
                end else begin
                    load_timeout_cnt <= load_timeout_cnt + 32'd1;
                end
            end else begin
                load_timeout_cnt <= 32'd0;
            end

            // Update occupancy once per completed write / consumed display
            // frame. Simultaneous refill and playback keep the level steady.
            case ({load_success_event, queue_pop_event})
                2'b10: buffered_count <= buffered_count + 3'd1;
                2'b01: buffered_count <= buffered_count - 3'd1;
                2'b11: buffered_count <= buffered_count;
                default: ;
            endcase

            if (queue_pop_event && !load_success_event &&
                (buffered_count == 3'd1)) begin
                recovery_hold <= 1'b1;
            end else if (recovery_hold && load_success_event &&
                         !queue_pop_event &&
                         (buffered_count >= 3'd1)) begin
                recovery_hold <= 1'b0;
            end

            if (!playback_started && !load_busy &&
                (buffered_count >= PREFILL_FRAMES)) begin
                disp_buf_idx          <= ring_read_idx;
                current_frame_idx     <= slot_frame_idx[ring_read_idx];
                current_frame_sector  <= slot_frame_sector[ring_read_idx];
                ring_read_idx         <= ring_read_idx + 2'd1;
                buffered_count        <= buffered_count - 3'd1;
                playback_started      <= 1'b1;
                first_frame_committed <= 1'b1;
                display_valid         <= 1'b1;
                auto_play_en          <= 1'b1;
                frame_timer           <= 32'd0;
                manual_next_pending   <= 1'b0;
            end else if (queue_pop_event) begin
                if (manual_next_pending)
                    audio_manual_seek_toggle <= ~audio_manual_seek_toggle;
                audio_display_sequence <= audio_display_sequence + 3'd1;
                audio_display_sequence_gray <=
                    ((audio_display_sequence + 3'd1) >> 1) ^
                     (audio_display_sequence + 3'd1);
                disp_buf_idx         <= ring_read_idx;
                current_frame_idx    <= slot_frame_idx[ring_read_idx];
                current_frame_sector <= slot_frame_sector[ring_read_idx];
                ring_read_idx        <= ring_read_idx + 2'd1;
                frame_timer          <= 32'd0;
                manual_next_pending  <= 1'b0;
            end

            // Fill until three complete frames are queued. After playback has
            // started, never overwrite the bank still scanned by HDMI, even
            // while a newly requested display bank is waiting for vblank.
            if (!quiesce_sync[1] && scan_done && video_found && reader_ready && !load_busy &&
                (!AUDIO_FIFO_MODE || audio_fifo_write_ready) &&
                (retry_delay_cnt == 17'd0) &&
                (buffered_count < PREFILL_FRAMES)) begin
                if (playback_started && (buffered_count == 3'd0)) begin
                    load_frame_idx    <= next_load_frame_idx;
                    load_sector       <= next_load_frame_sector;
                    load_frame_sector <= next_load_frame_sector;
                    pending_buf_idx   <= empty_refill_idx;
                    write_buf_idx     <= empty_refill_idx;
                    ring_write_idx    <= empty_refill_idx;
                    ring_read_idx     <= empty_refill_idx;
                    load_start_pulse  <= 1'b1;
                    load_busy         <= 1'b1;
                    source_done_seen  <= 1'b0;
                    write_done_seen   <= 1'b0;
                end else if (!playback_started ||
                             ((ring_write_idx != front_buf_idx) &&
                              (ring_write_idx != disp_buf_idx))) begin
                    load_frame_idx    <= next_load_frame_idx;
                    load_sector       <= next_load_frame_sector;
                    load_frame_sector <= next_load_frame_sector;
                    pending_buf_idx   <= ring_write_idx;
                    write_buf_idx     <= ring_write_idx;
                    load_start_pulse  <= 1'b1;
                    load_busy         <= 1'b1;
                    source_done_seen  <= 1'b0;
                    write_done_seen   <= 1'b0;
                end
            end
            // Final priority after occupancy/pop updates: a soft rescan must
            // reset the video ordinal together with the FIFO's common clear.
            if (AUDIO_FIFO_MODE && !video_found) begin
                playback_started <= 1'b0;
                display_valid <= 1'b0;
                auto_play_en <= 1'b0;
                buffered_count <= 3'd0;
                ring_write_idx <= 2'd0;
                ring_read_idx <= 2'd0;
                manual_next_pending <= 1'b0;
                audio_display_sequence <= 3'd0;
                audio_display_sequence_gray <= 3'd0;
                audio_manual_seek_toggle <= 1'b0;
            end
        end
    end
end

bmp_read #(.VIDEO_WIDTH(SOURCE_WIDTH), .VIDEO_HEIGHT(SOURCE_HEIGHT),
    .AUDIO_SAMPLES_PER_FRAME(AUDIO_SAMPLES_PER_FRAME)) bmp_read_m0(
    .audio_write_en         (audio_write_en),
    .audio_write_addr       (audio_write_addr),
    .audio_write_data       (audio_write_data),
    .audio_frame_done       (reader_audio_done),
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (reader_ready),
    .scan_start             (scan_start_pulse),
    .scan_start_sector      (SCAN_START_SECTOR),
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_done              (scan_done),
    .scan_found_valid       (scan_found_valid),
    .scan_found_sector      (scan_found_sector),
    .scan_found_total       (scan_found_total),
    .load_start             (load_start_pulse),
    .load_abort             (load_abort),
    .load_sector            (load_sector),
    .sd_init_done           (sd_init_done),
    .state_code             (reader_state_code),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    .image_meta_valid       (image_meta_valid),
    .image_width            (image_width),
    .image_height           (image_height),
    .scale_layout_ready     (scale_layout_ready),
    .scale_input_ready      (scale_input_ready),
    .scale_start            (scale_start),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_count      (sd_sec_read_count),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .bmp_data_wr_en         (source_pixel_valid),
    .bmp_data               (source_pixel),
    .bmp_pixel_x            (source_pixel_x),
    .bmp_row_end            (source_row_end),
    .video_frame_count      (reader_frame_count),
    .video_fps              (reader_video_fps),
    .video_data_sector      (reader_video_data_sector),
    .video_last_frame_sector(reader_video_last_frame_sector)
);

bmp_nearest_scaler #(
    .OUT_WIDTH       (640),
    .OUT_HEIGHT      (480),
    .MAX_SRC_WIDTH   (1280),
    .STRETCH_TO_FILL (1)
) bmp_nearest_scaler_m0(
    .clk                    (clk),
    .rst                    (rst),
    .cancel                 (load_abort),
    .image_meta_valid       (image_meta_valid),
    .image_width            (image_width),
    .image_height           (image_height),
    .layout_ready           (scale_layout_ready),
    .scale_start            (scale_start),
    .source_ready           (scale_input_ready),
    .source_pixel_valid     (source_pixel_valid),
    .source_pixel           (source_pixel),
    .source_pixel_x         (source_pixel_x),
    .source_row_end         (source_row_end),
    .write_fifo_full        (scaler_write_stall),
    .write_en               (scaler_write_en),
    .write_data             (scaler_write_data),
    .frame_done             (scaler_frame_done)
);

sd_card_top sd_card_top_m0(
    .clk                    (clk),
    .rst                    (rst),
    .SD_nCS                 (sd_ncs_raw),
    .sd_bus_idle            (sd_bus_idle),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_count      (sd_sec_read_count),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

wire unused_inputs = &{1'b0, key_next, key_auto, interval_toggle,
                       interval_value, scan_found_sector,
                       scan_found_total, video_fps};

endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,
    output reg  press_pulse
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;
reg button_sync0;
reg button_sync1;
reg button_stable;
reg [31:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;
        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else if (cnt >= DEBOUNCE_CYCLES - 1) begin
            if (button_stable && !button_sync1)
                press_pulse <= 1'b1;
            button_stable <= button_sync1;
            cnt <= 32'd0;
        end else begin
            cnt <= cnt + 32'd1;
        end
    end
end

endmodule
