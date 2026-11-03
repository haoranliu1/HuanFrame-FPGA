
module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd6
)(
    input                       clk,
    input                       rst,
    input                       quiesce,
    output                      quiesced,
    input                       key_next,
    input                       key_auto,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg                  display_valid,
    output      [3:0]           state_code,
    output      [63:0]          diagnostic_sd_data,
    output      [2:0]           image_index_dbg,
    output                         auto_play_dbg,

    // Debounced events are generated in the video clock domain and crossed
    // here as toggles so TF control uses the same accepted key event.
    input                       key_next_toggle,
    input                       key_prev_toggle,
    input                       image_select_toggle,
    input [2:0]                 image_select_index,
    input                       key_auto_toggle,
    input                       touch_auto_start_toggle,
    input                       touch_auto_stop_toggle,
    input                       interval_toggle,
    input  [3:0]                interval_value,

    input                       write_finish_toggle,
    output reg [1:0]            write_buf_idx,
    output reg [1:0]            disp_buf_idx,
    output [3:0]                interval_seconds_dbg,

    output                      write_req,
    input                       write_req_ack,
    input                       write_fifo_full,
    output                      write_en,
    output [31:0]               write_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO
    ,input [1:0] bgm_mode
    ,input [3:0] bgm_track
    ,input bgm_play
    ,input bgm_restart_toggle
    ,input [10:0] bgm_fifo_level
    ,input bgm_fifo_full
    ,input bgm_flush_busy
    ,output bgm_flush_toggle
    ,output bgm_fifo_play
    ,output bgm_sample_write
    ,output [15:0] bgm_sample_data
    ,output [4:0] bgm_track_count
    ,output [3:0] bgm_fault
    ,input [31:0] bgm_library_sector,bgm_library_bytes,bgm_catalog_id
    ,input bgm_config_valid
);

localparam [31:0] SOURCE_TIMEOUT_CYCLES = 32'd3_000_000_000; // 30 s for the larger BMP
localparam [31:0] WRITE_TIMEOUT_CYCLES  = 32'd200_000_000;   // 2 s after scaler done
localparam [20:0] FRAME_PIXEL_COUNT     = 21'd691200;

wire key_next_press;
wire key_prev_press;
wire key_auto_press;
wire touch_auto_start_press;
wire touch_auto_stop_press;

wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire [3:0]       state_code_i;
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
wire [15:0]      bmp_pixel_x;
wire             bmp_row_end;
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
wire             sd_init_done_raw;
reg              sd_init_done;
// Separate the controller's initialization decode from media/parser control.
// Ready is monotonic until global reset. CMD16 still occupies the physical
// bus after raw-ready, so this one-cycle delay does not skip its completion.
always @(posedge clk or posedge rst) begin
    if (rst) sd_init_done <= 1'b0;
    else sd_init_done <= sd_init_done_raw;
end
wire             bmp_ready;
wire             scan_done;
wire             scan_found_valid;
wire [31:0]      scan_found_sector;
wire [2:0]       scan_found_total;

reg              scan_start_pulse;
reg              load_start_pulse;
reg [31:0]       load_sector;
reg              scan_kicked;
reg              first_image_committed;
reg              auto_play_en;
reg [31:0]       auto_cnt;
reg [3:0]        auto_elapsed_seconds;
reg [3:0]        auto_interval_seconds;
reg [2:0]        img_found_count;
reg [2:0]        img_idx;              // 当前真正显示中的图片编号
reg [2:0]        load_idx;             // 当前正在写入的图片编号
reg [1:0]        pending_buf_idx;      // 当前正在写入的目标缓冲区
localparam integer IMAGE_SECTOR_WIDTH =
    (SCAN_MAX_SECTOR <= 32'd131071) ? 17 : 32;
reg [IMAGE_SECTOR_WIDTH-1:0] img_sector0;
reg [IMAGE_SECTOR_WIDTH-1:0] img_sector1;
reg [IMAGE_SECTOR_WIDTH-1:0] img_sector2;
reg [IMAGE_SECTOR_WIDTH-1:0] img_sector3;
reg [IMAGE_SECTOR_WIDTH-1:0] img_sector4;
reg [IMAGE_SECTOR_WIDTH-1:0] img_sector5;
reg              next_req_pending;
reg              prev_req_pending;
reg select_pending;
reg [2:0] select_index;
reg [2:0] select_sync;
reg [8:0] touch_controls_m0;
reg [2:0] select_index_m1,select_index_m2;
// Opposite-edge first sampling keeps the related-clock crossings timed and
// avoids coincident launch/capture hold failures from independent PLL skew.
always @(negedge clk or posedge rst) begin
    if(rst) touch_controls_m0<=0;
    else touch_controls_m0<={image_select_index,image_select_toggle,
        touch_auto_stop_toggle,touch_auto_start_toggle,key_auto_toggle,
        key_prev_toggle,key_next_toggle};
end
wire select_event=select_sync[2]^select_sync[1];
wire [2:0] manual_target;
reg              load_busy;
reg              load_issue_pending;
reg [31:0]       load_timeout_cnt;
reg [1:0]        scan_retry_count;
reg [26:0]       scan_retry_wait_cnt;
reg [3:0]        supervisor_fault_code;
reg [20:0]       scaler_pixel_count;
reg              scaler_pixel_count_good;
reg              write_stage_overflow;

reg              load_abort;
reg [1:0] quiesce_sync;
always @(posedge clk or posedge rst) begin
    if (rst) quiesce_sync <= 2'd0;
    else quiesce_sync <= {quiesce_sync[0], quiesce};
end
wire sd_bus_idle;
wire sd_ncs_raw;
wire bgm_arbiter_idle;
// Two-entry elastic bridge between the registered scaler output and the
// asynchronous SDRAM write FIFO.  The old direct connection let the scaler
// advance on the current full flag even though its registered write pulse was
// consumed one clock later.  If the FIFO became full on that intervening
// clock, a pixel could be counted by the scaler but rejected by the FIFO.
reg              write_stage0_valid;
reg [31:0]       write_stage0_data;
reg              write_stage1_valid;
reg [31:0]       write_stage1_data;
wire             write_stage_pop;
wire pack_input_ready, pack_valid, pack_idle;
wire [31:0] packed_data;
rgb888_word_packer pack_pixels(
    .clk(clk),.rst(rst || load_abort || scale_start),
    .in_valid(write_stage0_valid),.in_ready(pack_input_ready),
    .pixel(write_stage0_data[31:8]),
    .out_valid(pack_valid),.out_ready(!write_fifo_full),.word_data(packed_data),
    .idle(pack_idle)
);

// Selected is not the same as busy: the legacy CMD17 controller leaves CS
// low in S_WAIT. Only release it after all three real controller layers idle.
assign quiesced = quiesce_sync[1] && !load_busy && bmp_ready &&
                   sd_bus_idle && !sd_sec_read && !write_req &&
                   !write_stage0_valid && !write_stage1_valid && pack_idle &&
                   !load_start_pulse && !scan_start_pulse && bgm_arbiter_idle;
assign SD_nCS = quiesced ? 1'b1 : sd_ncs_raw;

// bmp_ready 先表示“源文件读取/送 FIFO 完成”；真正切显示要等 write_finish_toggle 同步后
reg              source_done_seen;
reg              write_done_seen;

// 同步 mem_clk 域的 write_finish_toggle
reg [2:0]        wrfin_tgl_sync;
reg [2:0]        key_next_tgl_sync;
reg [2:0]        key_prev_tgl_sync;
reg [2:0]        key_auto_tgl_sync;
reg [2:0]        touch_auto_start_tgl_sync;
reg [2:0]        touch_auto_stop_tgl_sync;
reg [2:0]        interval_tgl_sync;
reg [3:0]        interval_value_sync0;
reg [3:0]        interval_value_sync1;
wire             write_finish_pulse;
wire             key_next_event_sync;
wire             key_prev_event_sync;
wire             key_auto_event_sync;
wire             touch_auto_start_event_sync;
wire             touch_auto_stop_event_sync;
wire             interval_event_sync;

wire auto_tick;
wire auto_advance_tick;
wire [2:0] next_from_current;
wire [2:0] prev_from_current;

assign write_stage_pop = write_stage0_valid && pack_input_ready;
assign write_en   = pack_valid && !write_fifo_full;
assign write_data = packed_data;
// Assert backpressure as soon as the first bridge entry is occupied.  One
// additional registered scaler beat can still arrive, which is why the bridge
// contains a second entry.
assign scaler_write_stall = write_stage0_valid;
assign auto_tick  = (auto_cnt == (CLK_FREQ_HZ - 1));
assign auto_advance_tick = auto_tick &&
                           ((auto_elapsed_seconds + 1'b1) >=
                            auto_interval_seconds);
assign next_from_current = next_index_limited(img_idx, img_found_count);
assign prev_from_current = prev_index_limited(img_idx, img_found_count);
assign manual_target=select_pending ? select_index :
                     prev_req_pending ? prev_from_current : next_from_current;
assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
assign state_code = (supervisor_fault_code != 4'd0) ?
                    supervisor_fault_code : state_code_i;
assign key_next_event_sync = key_next_tgl_sync[2] ^ key_next_tgl_sync[1];
assign key_prev_event_sync = key_prev_tgl_sync[2] ^ key_prev_tgl_sync[1];
assign key_auto_event_sync = key_auto_tgl_sync[2] ^ key_auto_tgl_sync[1];
assign touch_auto_start_event_sync = touch_auto_start_tgl_sync[2] ^
                                     touch_auto_start_tgl_sync[1];
assign touch_auto_stop_event_sync = touch_auto_stop_tgl_sync[2] ^
                                    touch_auto_stop_tgl_sync[1];
assign interval_event_sync = interval_tgl_sync[2] ^
                             interval_tgl_sync[1];
assign key_next_press = key_next_event_sync;
assign key_prev_press = key_prev_event_sync;
assign key_auto_press = key_auto_event_sync;
assign touch_auto_start_press = touch_auto_start_event_sync;
assign touch_auto_stop_press = touch_auto_stop_event_sync;
// Before the first frame is visible, reuse M as a scan-found counter capped at
// five. After commit it returns to its normal meaning: displayed image index.
assign image_index_dbg = display_valid ? img_idx :
                         ((img_found_count >= 3'd5) ? 3'd5 : img_found_count);
assign auto_play_dbg = auto_play_en;
assign interval_seconds_dbg = auto_interval_seconds;

// Hold every produced pixel until the downstream asynchronous FIFO accepts
// it.  Simultaneous pop/push keeps ordering intact; the second entry absorbs
// the one-cycle response latency of the scaler's registered write output.
always @(posedge clk or posedge rst) begin
    if (rst) begin
        write_stage0_valid <= 1'b0;
        write_stage0_data  <= 32'd0;
        write_stage1_valid <= 1'b0;
        write_stage1_data  <= 32'd0;
        write_stage_overflow <= 1'b0;
    end else if (!sd_init_done || load_abort || scale_start) begin
        write_stage0_valid <= 1'b0;
        write_stage0_data  <= 32'd0;
        write_stage1_valid <= 1'b0;
        write_stage1_data  <= 32'd0;
        write_stage_overflow <= 1'b0;
    end else begin
        case ({scaler_write_en, write_stage_pop})
            2'b00: begin
                // Hold both entries.
            end

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

function [2:0] next_index_limited;
    input [2:0] cur;
    input [2:0] count;
    begin
        case (count)
            3'd0: next_index_limited = 3'd0;
            3'd1: next_index_limited = 3'd0;
            3'd2: next_index_limited = (cur == 3'd1) ? 3'd0 : (cur + 3'd1);
            3'd3: next_index_limited = (cur == 3'd2) ? 3'd0 : (cur + 3'd1);
            3'd4: next_index_limited = (cur == 3'd3) ? 3'd0 : (cur + 3'd1);
            3'd5: next_index_limited = (cur == 3'd4) ? 3'd0 : (cur + 3'd1);
            default: next_index_limited = (cur == 3'd5) ? 3'd0 : (cur + 3'd1);
        endcase
    end
endfunction

function [2:0] prev_index_limited;
    input [2:0] cur;
    input [2:0] count;
    begin
        case (count)
            3'd0: prev_index_limited = 3'd0;
            3'd1: prev_index_limited = 3'd0;
            3'd2: prev_index_limited = (cur == 3'd0) ? 3'd1 : (cur - 3'd1);
            3'd3: prev_index_limited = (cur == 3'd0) ? 3'd2 : (cur - 3'd1);
            3'd4: prev_index_limited = (cur == 3'd0) ? 3'd3 : (cur - 3'd1);
            3'd5: prev_index_limited = (cur == 3'd0) ? 3'd4 : (cur - 3'd1);
            default: prev_index_limited = (cur == 3'd0) ? 3'd5 : (cur - 3'd1);
        endcase
    end
endfunction

function [31:0] sector_lut;
    input [2:0] idx;
    begin
        case (idx)
            3'd0: sector_lut = img_sector0;
            3'd1: sector_lut = img_sector1;
            3'd2: sector_lut = img_sector2;
            3'd3: sector_lut = img_sector3;
            3'd4: sector_lut = img_sector4;
            3'd5: sector_lut = img_sector5;
            default: sector_lut = img_sector0;
        endcase
    end
endfunction

function [1:0] next_buf_lut;
    input [1:0] cur_disp_buf;
    input       valid_now;
    begin
        if (!valid_now)
            next_buf_lut = 2'd0;                 // 首图固定写 buffer0
        else if (cur_disp_buf == 2'd0)
            next_buf_lut = 2'd1;
        else
            next_buf_lut = 2'd0;
    end
endfunction

// Count the registered pixels actually produced by the scaler.  This makes a
// premature frame_done distinguishable from a downstream SDRAM stall.
always @(posedge clk or posedge rst) begin
    if (rst) begin
        scaler_pixel_count      <= 21'd0;
        scaler_pixel_count_good <= 1'b0;
    end else if (!sd_init_done || load_abort || scale_start) begin
        scaler_pixel_count      <= 21'd0;
        scaler_pixel_count_good <= 1'b0;
    end else begin
        if (load_busy && scaler_write_en)
            scaler_pixel_count <= scaler_pixel_count + 21'd1;

        if (load_busy && scaler_frame_done) begin
            scaler_pixel_count_good <=
                (scaler_write_en ?
                 (scaler_pixel_count == FRAME_PIXEL_COUNT - 21'd1) :
                 (scaler_pixel_count == FRAME_PIXEL_COUNT));
        end
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync        <= 3'b000;
        select_sync<=0;select_pending<=0;select_index<=0;
        select_index_m1<=0;select_index_m2<=0;
        key_next_tgl_sync     <= 3'b000;
        key_prev_tgl_sync     <= 3'b000;
        key_auto_tgl_sync     <= 3'b000;
        touch_auto_start_tgl_sync <= 3'b000;
        touch_auto_stop_tgl_sync  <= 3'b000;
        interval_tgl_sync         <= 3'b000;
        interval_value_sync0      <= 4'd2;
        interval_value_sync1      <= 4'd2;
        scan_start_pulse      <= 1'b0;
        load_start_pulse      <= 1'b0;
        load_sector           <= 32'd0;
        scan_kicked           <= 1'b0;
        first_image_committed <= 1'b0;
        auto_play_en          <= 1'b0;
        auto_cnt              <= 32'd0;
        auto_elapsed_seconds  <= 4'd0;
        auto_interval_seconds <= 4'd2;
        img_found_count       <= 3'd0;
        img_idx               <= 3'd0;
        load_idx              <= 3'd0;
        pending_buf_idx       <= 2'd0;
        write_buf_idx         <= 2'd0;
        disp_buf_idx          <= 2'd0;
        img_sector0           <= 32'd0;
        img_sector1           <= 32'd0;
        img_sector2           <= 32'd0;
        img_sector3           <= 32'd0;
        img_sector4           <= 32'd0;
        img_sector5           <= 32'd0;
        next_req_pending      <= 1'b0;
        prev_req_pending      <= 1'b0;
        load_busy             <= 1'b0;
        load_issue_pending    <= 1'b0;
        load_timeout_cnt      <= 32'd0;
        scan_retry_count      <= 2'd0;
        scan_retry_wait_cnt   <= 27'd0;
        supervisor_fault_code <= 4'd0;
        load_abort            <= 1'b0;
        source_done_seen      <= 1'b0;
        write_done_seen       <= 1'b0;
        display_valid         <= 1'b0;
    end else begin
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        select_index_m1<=touch_controls_m0[8:6];select_index_m2<=select_index_m1;
        select_sync<={select_sync[1:0],touch_controls_m0[5]};
        key_next_tgl_sync <= {key_next_tgl_sync[1:0], touch_controls_m0[0]};
        key_prev_tgl_sync <= {key_prev_tgl_sync[1:0], touch_controls_m0[1]};
        key_auto_tgl_sync <= {key_auto_tgl_sync[1:0], touch_controls_m0[2]};
        touch_auto_start_tgl_sync <= {touch_auto_start_tgl_sync[1:0],
                                      touch_controls_m0[3]};
        touch_auto_stop_tgl_sync <= {touch_auto_stop_tgl_sync[1:0],
                                     touch_controls_m0[4]};
        interval_tgl_sync <= {interval_tgl_sync[1:0], interval_toggle};
        interval_value_sync0 <= interval_value;
        interval_value_sync1 <= interval_value_sync0;
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;
        load_abort       <= 1'b0;

        if (!sd_init_done) begin
            select_pending<=0;
            scan_kicked           <= 1'b0;
            first_image_committed <= 1'b0;
            auto_play_en          <= 1'b0;
            auto_cnt              <= 32'd0;
            auto_elapsed_seconds  <= 4'd0;
            img_found_count       <= 3'd0;
            img_idx               <= 3'd0;
            load_idx              <= 3'd0;
            pending_buf_idx       <= 2'd0;
            write_buf_idx         <= 2'd0;
            disp_buf_idx          <= 2'd0;
            img_sector0           <= 32'd0;
            img_sector1           <= 32'd0;
            img_sector2           <= 32'd0;
            img_sector3           <= 32'd0;
            img_sector4           <= 32'd0;
            img_sector5           <= 32'd0;
            next_req_pending      <= 1'b0;
            prev_req_pending      <= 1'b0;
            load_busy             <= 1'b0;
            load_issue_pending    <= 1'b0;
            load_timeout_cnt      <= 32'd0;
            scan_retry_count      <= 2'd0;
            scan_retry_wait_cnt   <= 27'd0;
            supervisor_fault_code <= 4'd0;
            load_abort            <= 1'b0;
            source_done_seen      <= 1'b0;
            write_done_seen       <= 1'b0;
            display_valid         <= 1'b0;
        end else begin
            // Select the sector from the registered target image index. The
            // extra cycle keeps next/previous arithmetic off the 32-bit mux path.
            if (load_issue_pending) begin
                load_sector        <= sector_lut(load_idx);
                load_start_pulse   <= 1'b1;
                load_issue_pending <= 1'b0;
            end

            if (interval_event_sync) begin
                auto_interval_seconds <=
                    ((interval_value_sync1 >= 4'd1) &&
                     (interval_value_sync1 <= 4'd15)) ?
                    interval_value_sync1 : 4'd2;
                auto_cnt             <= 32'd0;
                auto_elapsed_seconds <= 4'd0;
            end

            // 扫描阶段缓存前 6 张图的起始 sector
            if (scan_found_valid) begin
                case (img_found_count)
                    3'd0: img_sector0 <= scan_found_sector;
                    3'd1: img_sector1 <= scan_found_sector;
                    3'd2: img_sector2 <= scan_found_sector;
                    3'd3: img_sector3 <= scan_found_sector;
                    3'd4: img_sector4 <= scan_found_sector;
                    3'd5: img_sector5 <= scan_found_sector;
                    default: ;
                endcase

                if (img_found_count < 3'd6)
                    img_found_count <= img_found_count + 3'd1;

                scan_retry_count    <= 2'd0;
                scan_retry_wait_cnt <= 27'd0;
            end else if (scan_done && (img_found_count == 3'd0) &&
                         (state_code_i == 4'd7) &&
                         (scan_retry_count < 2'd3)) begin
                // Retry only a lost SD read transaction. Do not repeatedly
                // rescan the whole card when the scan completed normally.
                if (scan_retry_wait_cnt >= (CLK_FREQ_HZ - 1)) begin
                    scan_retry_wait_cnt <= 27'd0;
                    scan_retry_count    <= scan_retry_count + 2'd1;
                    scan_kicked         <= 1'b0;
                end else begin
                    scan_retry_wait_cnt <= scan_retry_wait_cnt + 27'd1;
                end
            end else begin
                scan_retry_wait_cnt <= 27'd0;
            end

            // Remember that the scaler completed its output frame, but do not
            // switch buffers until the SDRAM writer drains the complete frame.
            if (load_busy && scaler_frame_done)
                source_done_seen <= 1'b1;

            // 记住写帧完成脉冲，避免“先写完后源结束”导致脉冲丢失而卡死
            if (load_busy && write_finish_pulse)
                write_done_seen <= 1'b1;

            // The SDRAM writer is the authoritative end-to-end completion
            // handshake: it can finish only after exactly one 640x480 frame
            // has been accepted from the scaler FIFO. Do not additionally
            // gate the commit on the scaler's one-cycle frame_done pulse.
            if (load_busy && (write_done_seen || write_finish_pulse)) begin
                load_busy             <= 1'b0;
                load_timeout_cnt      <= 32'd0;
                source_done_seen      <= 1'b0;
                write_done_seen       <= 1'b0;
                supervisor_fault_code <= 4'd0;
                disp_buf_idx          <= pending_buf_idx;
                img_idx               <= load_idx;
                display_valid         <= 1'b1;
                first_image_committed <= 1'b1;
            end else if (load_busy) begin
                // Loading and writer drain are separate transactions.  A slow
                // TF image gets up to ten seconds.  Once frame_done arrives,
                // restart the timer and give the SDRAM writer two seconds to
                // empty the elastic bridge/FIFO and assert write_finish.
                if (scaler_frame_done && !source_done_seen) begin
                    load_timeout_cnt <= 32'd0;
                end else if ((!source_done_seen &&
                              (load_timeout_cnt >= SOURCE_TIMEOUT_CYCLES)) ||
                             ( source_done_seen &&
                              (load_timeout_cnt >= WRITE_TIMEOUT_CYCLES))) begin
                    load_busy             <= 1'b0;
                    load_timeout_cnt      <= 32'd0;
                    source_done_seen      <= 1'b0;
                    write_done_seen       <= 1'b0;
                    load_abort            <= 1'b1;
                    // S6: scaler never completed.
                    // S7: exactly 307200 scaler pixels were produced, but the
                    //     SDRAM writer did not finish.
                    // S8: scaler asserted frame_done with a wrong pixel count.
                    // S9: the elastic bridge overflow invariant was violated.
                    if (!source_done_seen)
                        supervisor_fault_code <= 4'd6;
                    else if (write_stage_overflow)
                        supervisor_fault_code <= 4'd9;
                    else if (!scaler_pixel_count_good)
                        supervisor_fault_code <= 4'd8;
                    else
                        supervisor_fault_code <= 4'd7;
                end else begin
                    load_timeout_cnt <= load_timeout_cnt + 32'd1;
                end
            end else begin
                load_timeout_cnt <= 32'd0;
            end

            // 上电后自动发起一次“扫描前 6 张 BMP”
            if (!quiesce_sync[1] && !scan_kicked && bmp_ready) begin
                scan_start_pulse      <= 1'b1;
                scan_kicked           <= 1'b1;
                scan_retry_wait_cnt   <= 27'd0;
                supervisor_fault_code <= 4'd0;
                first_image_committed <= 1'b0;
                auto_play_en          <= 1'b0;
                auto_cnt              <= 32'd0;
                auto_elapsed_seconds  <= 4'd0;
                img_found_count       <= 3'd0;
                img_idx               <= 3'd0;
                load_idx              <= 3'd0;
                pending_buf_idx       <= 2'd0;
                write_buf_idx         <= 2'd0;
                disp_buf_idx          <= 2'd0;
                next_req_pending      <= 1'b0;
                prev_req_pending      <= 1'b0;
                display_valid         <= 1'b0;
                load_busy             <= 1'b0;
                load_issue_pending    <= 1'b0;
                source_done_seen      <= 1'b0;
                write_done_seen       <= 1'b0;
            end else begin
                // Manual commands have priority and replace any older queued
                // direction. Explicit screen start/stop commands are kept
                // separate from the physical K2 toggle.
                if (select_event && scan_done && select_index_m2<img_found_count) begin
                    select_pending<=1;select_index<=select_index_m2;
                    prev_req_pending<=0;next_req_pending<=0;
                    auto_play_en<=0;auto_cnt<=0;auto_elapsed_seconds<=0;
                end else if (key_prev_press && scan_done && (img_found_count > 3'd0)) begin
                    select_pending<=0;
                    prev_req_pending <= 1'b1;
                    next_req_pending <= 1'b0;
                    auto_play_en     <= 1'b0;
                    auto_cnt         <= 32'd0;
                    auto_elapsed_seconds <= 4'd0;
                end else if (key_next_press && scan_done && (img_found_count > 3'd0)) begin
                    select_pending<=0;
                    next_req_pending <= 1'b1;
                    prev_req_pending <= 1'b0;
                    auto_play_en     <= 1'b0;
                    auto_cnt         <= 32'd0;
                    auto_elapsed_seconds <= 4'd0;
                end else if (touch_auto_stop_press) begin
                    auto_play_en <= 1'b0;
                    auto_cnt     <= 32'd0;
                    auto_elapsed_seconds <= 4'd0;
                end else if (touch_auto_start_press && scan_done &&
                             (img_found_count > 3'd1)) begin
                    auto_play_en <= 1'b1;
                    auto_cnt     <= 32'd0;
                    auto_elapsed_seconds <= 4'd0;
                end else if (key_auto_press && scan_done && (img_found_count > 3'd1)) begin
                    auto_play_en <= ~auto_play_en;
                    auto_cnt     <= 32'd0;
                    auto_elapsed_seconds <= 4'd0;
                end

                // Count the configured display dwell time. Loading time is
                // excluded so every committed image remains visible for the
                // full requested 1..15 second interval.
                if (select_event || key_prev_press || key_next_press || key_auto_press ||
                    touch_auto_start_press || touch_auto_stop_press ||
                    interval_event_sync || !auto_play_en) begin
                    // Do not let the old auto-play value in this clocked
                    // process overwrite the command above.
                    auto_cnt <= 32'd0;
                    auto_elapsed_seconds <= 4'd0;
                end else if (scan_done && auto_play_en && display_valid && !load_busy && first_image_committed && (img_found_count > 3'd1)) begin
                    if (auto_tick) begin
                        auto_cnt <= 32'd0;
                        if (auto_advance_tick)
                            auto_elapsed_seconds <= 4'd0;
                        else
                            auto_elapsed_seconds <= auto_elapsed_seconds + 1'b1;
                    end else begin
                        auto_cnt <= auto_cnt + 32'd1;
                    end
                end else begin
                    auto_cnt <= 32'd0;
                    auto_elapsed_seconds <= 4'd0;
                end

                // 首图自动加载到 buffer0
                if (!quiesce_sync[1] && scan_done && !first_image_committed && bmp_ready && !load_busy && (img_found_count != 3'd0)) begin
                    load_idx         <= 3'd0;
                    load_sector      <= img_sector0;
                    pending_buf_idx  <= 2'd0;
                    write_buf_idx    <= 2'd0;
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    load_issue_pending <= 1'b0;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    supervisor_fault_code <= 4'd0;
                    next_req_pending <= 1'b0;
                    prev_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                    auto_elapsed_seconds <= 4'd0;
                end
                // 手动请求优先：按请求方向写到非当前显示的缓冲区。
                else if (!quiesce_sync[1] && scan_done && bmp_ready && display_valid && !load_busy &&
                         !select_event && !key_prev_press && !key_next_press &&
                         (select_pending || prev_req_pending || next_req_pending) &&
                         (img_found_count != 3'd0)) begin
                    load_idx         <= manual_target;
                    load_issue_pending <= 1'b1;
                    select_pending   <= 0;
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    supervisor_fault_code <= 4'd0;
                    next_req_pending <= 1'b0;
                    prev_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                    auto_elapsed_seconds <= 4'd0;
                end
                // 自动播放下一张：同样写到“非当前显示”的另一块 buffer
                else if (!quiesce_sync[1] && scan_done && bmp_ready && display_valid && !load_busy &&
                         auto_play_en && auto_advance_tick &&
                         !select_event && !select_pending &&
                         !interval_event_sync && !key_prev_press &&
                         !key_next_press && !key_auto_press &&
                         !touch_auto_start_press && !touch_auto_stop_press &&
                         (img_found_count > 3'd1)) begin
                    load_idx         <= next_from_current;
                    load_issue_pending <= 1'b1;
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    supervisor_fault_code <= 4'd0;
                    auto_cnt         <= 32'd0;
                    auto_elapsed_seconds <= 4'd0;
                end
            end
        end
    end
end

bmp_read bmp_read_m0(
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (bmp_ready),

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
    .state_code             (state_code_i),
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
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data),
    .bmp_pixel_x            (bmp_pixel_x),
    .bmp_row_end            (bmp_row_end)
);

bmp_nearest_scaler #(
    .OUT_WIDTH              (960),
    .OUT_HEIGHT             (720),
    .MAX_SRC_WIDTH          (1280)
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
    .source_pixel_valid     (bmp_data_wr_en),
    .source_pixel           (bmp_data),
    .source_pixel_x         (bmp_pixel_x),
    .source_row_end         (bmp_row_end),
    .write_fifo_full        (scaler_write_stall),
    .write_en               (scaler_write_en),
    .write_data             (scaler_write_data),
    .frame_done             (scaler_frame_done)
);

wire bgm_request,bgm_ack,bgm_valid,bgm_end,bgm_urgent;
wire [31:0] bgm_address;
wire [7:0] bgm_data;
wire card_request,card_valid,card_end;
wire [31:0] card_address;
wire [7:0] card_data;
bgm_library_player bgm_player(
    .clk(clk),.rst(rst),.init_done(sd_init_done),.quiesce(quiesce_sync[1]),
    .mode(bgm_mode),.track(bgm_track),.play(bgm_play),.restart_toggle(bgm_restart_toggle),
    .configured_sector(bgm_library_sector),.configured_bytes(bgm_library_bytes),
    .configured_id(bgm_catalog_id),.config_valid(bgm_config_valid),
    .request(bgm_request),.address(bgm_address),.ack(bgm_ack),
    .data(bgm_data),.valid(bgm_valid),.sector_end(bgm_end),.urgent(bgm_urgent),
    .fifo_play(bgm_fifo_play),.flush_toggle(bgm_flush_toggle),.flush_busy(bgm_flush_busy),
    .fifo_level(bgm_fifo_level),.fifo_full(bgm_fifo_full),
    .sample_write(bgm_sample_write),.sample_data(bgm_sample_data),
    .track_count(bgm_track_count),.fault(bgm_fault),.ready()
);
bgm_sector_arbiter bgm_arbiter(
    .clk(clk),.rst(rst),.init_done(sd_init_done),.bus_idle(sd_bus_idle),
    .image_request(sd_sec_read),.image_address(sd_sec_read_addr),
    .bgm_request(bgm_request),.bgm_address(bgm_address),.bgm_urgent(bgm_urgent),
    .bgm_ack(bgm_ack),.card_request(card_request),.card_address(card_address),
    .card_data(card_data),.card_valid(card_valid),.card_end(card_end),
    .image_data(sd_sec_read_data),.image_valid(sd_sec_read_data_valid),.image_end(sd_sec_read_end),
    .bgm_data(bgm_data),.bgm_valid(bgm_valid),.bgm_end(bgm_end),.idle(bgm_arbiter_idle)
);
sd_card_top sd_card_top_m0(
    .diagnostic_data         (diagnostic_sd_data),
    .clk                    (clk),
    .rst                    (rst),
    .SD_nCS                 (sd_ncs_raw),
    .sd_bus_idle            (sd_bus_idle),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done_raw),
    .sd_sec_read            (card_request),
    .sd_sec_read_addr       (card_address),
    .sd_sec_read_data       (card_data),
    .sd_sec_read_data_valid (card_valid),
    .sd_sec_read_end        (card_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

endmodule

// Four RGB888 pixels become three32-bit words, without losing any color bits.
// Both sides use ready/valid. A blocked word is held byte-for-byte stable.
module rgb888_word_packer(
    input clk,input rst,input in_valid,output in_ready,input [23:0] pixel,
    output reg out_valid,input out_ready,output reg [31:0] word_data,output idle
);
    reg [1:0] phase;
    reg [23:0] carry;
    assign in_ready=!out_valid || out_ready;
    assign idle=phase==0 && !out_valid;
    always @(posedge clk or posedge rst) begin
        if(rst) begin phase<=0;carry<=0;out_valid<=0;word_data<=0;end
        else begin
            if(out_ready) out_valid<=0;
            if(in_valid && in_ready) begin
                case(phase)
                    0: begin carry<=pixel;phase<=1;end
                    1: begin word_data<={carry,pixel[23:16]};carry<={8'd0,pixel[15:0]};phase<=2;out_valid<=1;end
                    2: begin word_data<={carry[15:0],pixel[23:8]};carry<={16'd0,pixel[7:0]};phase<=3;out_valid<=1;end
                    3: begin word_data<={carry[7:0],pixel};phase<=0;out_valid<=1;end
                endcase
            end
        end
    end
endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
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
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule
