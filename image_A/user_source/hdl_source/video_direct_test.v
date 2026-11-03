`timescale 1ns/1ps

// Direct video-only test source used while TF/SDRAM frame loading is being
// debugged. It shares the existing 640x480 timing and HDMI transmitter.
module video_direct_test #(
    parameter integer BASE_ONLY = 0,
    parameter SHARED_FONT = 0,
    parameter integer CLK_FREQ_HZ = 25_000_000
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        hs,
    input  wire        vs,
    input  wire        de,
    input  wire        key_next,
    input  wire        key_auto,
    input  wire        key3,
    input  wire        key4,
    input  wire        touch_prev_event,
    input  wire        touch_next_event,
    input  wire        touch_auto_start_event,
    input  wire        touch_auto_stop_event,
    input  wire        touch_brightness_event,
    input  wire        touch_contrast_event,
    input  wire        touch_interval_event,
    input  wire        touch_subtitle_commit_event,
    input  wire [6:0]  touch_brightness_value,
    input  wire [6:0]  touch_contrast_value,
    input  wire [3:0]  touch_interval_value,
    input  wire [255:0] touch_subtitle_text,
    input  wire [5:0]  touch_subtitle_length,
    input  wire [2:0]  touch_subtitle_color,
    input  wire        touch_subtitle_bitmap_mode,
    input  wire [15:0] touch_subtitle_bitmap_row,
    output reg  [8:0]  touch_subtitle_bitmap_address,
    input  wire [6:0]  audio_volume,
    input  wire        audio_manual_note_enable,
    input  wire        audio_manual_note_gate,
    input  wire [2:0]  audio_manual_note_index,
    input  wire        compare_enable,
    input  wire [7:0]  compare_position,
    input  wire [1:0]  spectrum_style,
    input  wire        audio_pcm_mode,
    input  wire [2:0]  transition_mode,
    input  wire [3:0]  frame_state,
    input  wire [2:0]  frame_mode,
    input  wire        frame_auto,
    input  wire [3:0]  frame_interval_seconds,
    input  wire [1:0]  frame_buffer,
    input  wire [1:0]  frame_buffer_request,
    input  wire [23:0] base_rgb,
    input  wire        use_base,
    input  wire        audio_sample_valid,
    input  wire [23:0] audio_sample,
    input  wire [2:0]  audio_note_index,
    input  wire        audio_note_active,
    output reg [23:0]  rgb,
    output reg [3:0]   last_key_code,
    output wire        key_next_event,
    output wire        key_prev_event,
    output wire        key_auto_event,
    output wire        frame_switch_ready,
    output wire [9:0] shared_glyph_address,
    input wire [31:0] shared_glyph_word
);
    reg hs_d, vs_d, de_d;
    reg compare_active;
    reg [9:0] compare_edge;
    reg [1:0] stage_style;
    reg [9:0] stage_base, stage_distance, stage_peak_distance;
    reg [23:0] stage_color;
    wire frame_tick_showcase = vs_d && !vs;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            compare_active <= 0; compare_edge <= 320; stage_style <= 0;
        end else if (frame_tick_showcase) begin
            compare_active <= compare_enable;
            compare_edge <= (compare_position > 160) ? 10'd640 :
                            {compare_position, 2'b00};
            stage_style <= (spectrum_style > 2) ? 2'd0 : spectrum_style;
        end
    end

    // Fixed palette and shifts only: no lookup RAM, multiplier or extra sample path.
    function [23:0] stage_palette;
        input [2:0] band;
        begin
            case (band)
                0: stage_palette = 24'h24e8c0;
                1: stage_palette = 24'h20d8f0;
                2: stage_palette = 24'h4098ff;
                3: stage_palette = 24'h8068ff;
                4: stage_palette = 24'hc060f0;
                5: stage_palette = 24'hf060b0;
                6: stage_palette = 24'hff9860;
                default: stage_palette = 24'hffe060;
            endcase
        end
    endfunction
    function [23:0] stage_dim;
        input [23:0] color;
        begin
            stage_dim = {2'b00,color[23:18],2'b00,color[15:10],2'b00,color[7:2]};
        end
    endfunction
    reg [9:0] x;
    reg [8:0] y;
    reg [1:0] mode;
    reg auto_play;
    reg [25:0] auto_count;
    reg [3:0] auto_elapsed_seconds;
    reg [3:0] auto_interval_seconds;
    reg [6:0] brightness_level;
    reg [6:0] contrast_level;
    reg [6:0] volume_level;
    reg [6:0] brightness_request;
    reg [6:0] contrast_request;
    wire [5:0] tile = {x[8:6], y[8:6]};
    wire key_next_pulse;
    wire key_auto_pulse;
    wire next_command_pulse;
    wire prev_command_pulse;
    wire manual_command_pulse;
    wire auto_command_pulse;
    wire key3_pulse;
    wire key4_pulse;
    assign next_command_pulse = key_next_pulse | touch_next_event;
    assign prev_command_pulse = touch_prev_event;
    assign manual_command_pulse = next_command_pulse | prev_command_pulse;
    assign auto_command_pulse = key_auto_pulse |
                                touch_auto_start_event |
                                touch_auto_stop_event;
    assign key_next_event = next_command_pulse;
    assign key_prev_event = prev_command_pulse;
    assign key_auto_event = key_auto_pulse;
    wire auto_second_tick = (auto_count >= (CLK_FREQ_HZ - 1));

    // The OSD uses a tiny 5x7 font and is drawn directly over the test image.
    // It intentionally avoids a frame buffer or a new clock domain.
    reg [5:0] osd_char_index;
    reg [2:0] osd_row_index;
    reg [2:0] osd_col_index;
    reg [7:0] osd_char_code;
    reg [4:0] osd_glyph_row;
    reg signed [10:0] subtitle_x;
    reg [5:0] subtitle_delay;
    reg [1:0] subtitle_message;
    reg [255:0] subtitle_text_active;
    reg [5:0] subtitle_length_active;
    reg [2:0] subtitle_color_active;
    reg       subtitle_bitmap_active;
    reg signed [11:0] subtitle_rel_x;
    reg signed [11:0] subtitle_prefetch_rel_x;
    reg [4:0] subtitle_char_index;
    reg [2:0] subtitle_row_index;
    reg [2:0] subtitle_col_index;
    reg [3:0] subtitle_bitmap_row_index;
    reg [3:0] subtitle_bitmap_col_index;
    reg [7:0] subtitle_char_code;
    reg base_enable_sync0;
    reg base_enable_sync1;
    wire base_active = (BASE_ONLY != 0) ? 1'b1 : base_enable_sync1;
    reg [1:0] frame_buffer_sync0;
    reg [1:0] frame_buffer_sync1;
    reg [1:0] frame_buffer_request_sync0;
    reg [1:0] frame_buffer_request_sync1;
    reg [1:0] transition_phase;
    reg [4:0] transition_level;
    reg [2:0] transition_mode_latched;
    // The tone source supplies the active note, while the final PCM stream
    // supplies the real per-frame amplitude used by the bar display.
    reg [23:0] audio_frame_peak;
    reg [6:0] audio_bar_height [0:7];
    reg [6:0] audio_peak_height [0:7];
    reg [3:0] audio_peak_hold [0:7];
    wire [6:0] audio_bar_next [0:7];
    reg [2:0] audio_bar_slot;
    reg [5:0] audio_bar_column;
    reg [9:0] audio_bar_y_top;
    reg [9:0] audio_peak_y_top;
    reg [23:0] audio_bar_blended_rgb;
    reg [23:0] source_rgb;
    reg [23:0] pixel_rgb;
    integer audio_bar_i;

    localparam integer SUBTITLE_TEXT_WIDTH = 240;
    localparam integer SUBTITLE_DELAY_FRAMES = 60;
    wire [11:0] subtitle_dynamic_width;
    wire signed [11:0] subtitle_active_width;
    assign subtitle_dynamic_width = subtitle_bitmap_active ?
                                    ({6'd0, subtitle_length_active} << 4) :
                                    (subtitle_length_active * 12);
    assign subtitle_active_width = (subtitle_length_active == 0) ?
                                   SUBTITLE_TEXT_WIDTH :
                                   $signed(subtitle_dynamic_width);
    localparam integer CONTROL_KEY_DEBOUNCE_MS = 100;
    localparam [1:0] TRANSITION_IDLE        = 2'd0;
    localparam [1:0] TRANSITION_FADE_OUT    = 2'd1;
    localparam [1:0] TRANSITION_WAIT_SWITCH = 2'd2;
    localparam [1:0] TRANSITION_FADE_IN     = 2'd3;
    localparam [4:0] TRANSITION_FULL_LEVEL  = 5'd16;
    localparam [2:0] EFFECT_FADE            = 3'd0;
    localparam [2:0] EFFECT_WIPE_LEFT       = 3'd1;
    localparam [2:0] EFFECT_WIPE_RIGHT      = 3'd2;
    localparam [2:0] EFFECT_CENTER_EXPAND   = 3'd3;
    localparam [2:0] EFFECT_DIRECT          = 3'd4;
    localparam [2:0] EFFECT_BLINDS          = 3'd5;
    localparam [2:0] EFFECT_CHECKER         = 3'd6;
    localparam [2:0] EFFECT_VERTICAL        = 3'd7;
    localparam [9:0] AUDIO_BAR_X_START = 10'd64;
    localparam [9:0] AUDIO_BAR_X_END = 10'd576;
    localparam [9:0] AUDIO_BAR_Y_TOP = 10'd350;
    localparam [9:0] AUDIO_BAR_Y_BASE = 10'd446;
    localparam [6:0] AUDIO_BAR_IDLE_HEIGHT = 7'd40;
    localparam [6:0] AUDIO_BAR_MAX_HEIGHT = 7'd96;
    localparam [6:0] AUDIO_BAR_RISE_STEP = 7'd4;
    localparam [6:0] AUDIO_BAR_FALL_STEP = 7'd2;

    function [23:0] audio_bar_blend;
        input [23:0] base_color;
        reg [8:0] blend_r;
        reg [8:0] blend_g;
        reg [8:0] blend_b;
        begin
            // 50% yellow overlay: preserve the image underneath the curve.
            blend_r = {1'b0, base_color[23:16]} + 9'd255;
            blend_g = {1'b0, base_color[15:8]}  + 9'd224;
            blend_b = {1'b0, base_color[7:0]}   + 9'd64;
            audio_bar_blend = {blend_r[8:1], blend_g[8:1], blend_b[8:1]};
        end
    endfunction

    // A faint reference track is not measured audio energy. Preserve the
    // existing 40-pixel visual reference without inventing a silence level.
    function [23:0] audio_track_blend;
        input [23:0] base_color;
        reg [8:0] r, g, b;
        begin
            r = {1'b0, base_color[23:16]} - {4'd0, base_color[23:19]} + 9'd31;
            g = {1'b0, base_color[15:8]} - {4'd0, base_color[15:11]} + 9'd28;
            b = {1'b0, base_color[7:0]} - {4'd0, base_color[7:3]} + 9'd8;
            audio_track_blend = {r[7:0], g[7:0], b[7:0]};
        end
    endfunction

    function [6:0] audio_smooth_height;
        input [6:0] current_height;
        input [6:0] target_height;
        reg [8:0] delta, step_size;
        begin
            if (target_height > current_height) begin
                delta = {2'd0, target_height} - {2'd0, current_height};
                // alpha=1/2: approx 24 ms time constant at HDMI 60 Hz.
                step_size = (delta + 9'd1) >> 1;
                audio_smooth_height = current_height + step_size[6:0];
            end else begin
                delta = {2'd0, current_height} - {2'd0, target_height};
                // alpha=3/32: approx 170 ms, rounded up to settle at zero.
                step_size = ((delta << 1) + delta + 9'd31) >> 5;
                audio_smooth_height = current_height - step_size[6:0];
            end
        end
    endfunction

    function [23:0] audio_abs_24;
        input [23:0] sample;
        begin
            audio_abs_24 = sample[23] ? ((~sample) + 1'b1) : sample;
        end
    endfunction

    function [6:0] audio_peak_to_height;
        input [23:0] peak;
        reg [8:0] scaled_height;
        begin
            scaled_height = 9'd40 + {1'b0, peak[23:16]} +
                            {2'b0, peak[23:17]};
            if (scaled_height > 9'd96)
                audio_peak_to_height = AUDIO_BAR_MAX_HEIGHT;
            else
                audio_peak_to_height = scaled_height[6:0];
        end
    endfunction

    wire [6:0] audio_bar_target_height =
        audio_peak_to_height(audio_frame_peak);

    wire [55:0] audio_band_targets;
    wire [6:0] audio_target [0:7];
    genvar audio_band_index;
    generate
        begin : pcm_band_display
            audio_pcm_band_peaks bands (
                .clk(clk), .rst(rst),
                .sample_valid(audio_sample_valid),
                .sample(audio_pcm_mode ? audio_sample : 24'd0),
                .frame_tick(vs_d && !vs), .heights(audio_band_targets)
            );
        end
        for (audio_band_index = 0; audio_band_index < 8;
             audio_band_index = audio_band_index + 1) begin : bar_targets
            assign audio_bar_next[audio_band_index] = audio_smooth_height(
                audio_bar_height[audio_band_index], audio_target[audio_band_index]);
            assign audio_target[audio_band_index] = audio_pcm_mode ?
                audio_band_targets[audio_band_index*7 +: 7] :
                ((audio_note_active && (audio_note_index == audio_band_index)) ?
                 audio_bar_target_height : AUDIO_BAR_IDLE_HEIGHT);
        end
    endgenerate

    // The request side may only switch SDRAM buffers after the old picture
    // has reached black. Keep this asserted until the synchronized front
    // buffer catches up with the requested buffer.
    assign frame_switch_ready =
        (transition_phase == TRANSITION_WAIT_SWITCH) &&
        (frame_buffer_request_sync1 != frame_buffer_sync1);

    function [7:0] adjust_channel;
        input [7:0] channel;
        input [6:0] brightness_i;
        input [6:0] contrast_i;
        reg signed [9:0] centered;
        reg [12:0] contrast_scale_product;
        reg [7:0] contrast_scale;
        reg signed [17:0] contrast_product;
        reg signed [11:0] scaled;
        reg signed [11:0] brightness_offset;
        reg signed [12:0] adjusted;
        begin
            centered = $signed({1'b0, channel}) - 10'sd128;

            // 0..100 maps monotonically to approximately 50%..150%.
            // Multiplication by 41/32 keeps every input step distinct while
            // avoiding a costly divide-by-100 in the pixel path.
            contrast_scale_product = contrast_i * 8'd41;
            contrast_scale = 8'd64 + contrast_scale_product[12:5];
            contrast_product = centered * $signed({1'b0, contrast_scale});
            scaled = contrast_product >>> 7;

            // 0..100 maps exactly to -50..+50 RGB code values.
            brightness_offset = $signed({1'b0, brightness_i}) - 12'sd50;
            adjusted = scaled + 13'sd128 + brightness_offset;

            if (adjusted < 0)
                adjust_channel = 8'd0;
            else if (adjusted > 13'sd255)
                adjust_channel = 8'd255;
            else
                adjust_channel = adjusted[7:0];
        end
    endfunction

    function [23:0] adjust_image;
        input [23:0] color;
        input [6:0] brightness_i;
        input [6:0] contrast_i;
        begin
            adjust_image = {
                adjust_channel(color[23:16], brightness_i, contrast_i),
                adjust_channel(color[15:8], brightness_i, contrast_i),
                adjust_channel(color[7:0], brightness_i, contrast_i)
            };
        end
    endfunction

    function [23:0] fade_image;
        input [23:0] color;
        input [4:0] level;
        reg [12:0] fade_r;
        reg [12:0] fade_g;
        reg [12:0] fade_b;
        begin
            if (level >= TRANSITION_FULL_LEVEL) begin
                fade_image = color;
            end else begin
                fade_r = color[23:16] * level;
                fade_g = color[15:8]  * level;
                fade_b = color[7:0]   * level;
                fade_image = {fade_r[11:4], fade_g[11:4], fade_b[11:4]};
            end
        end
    endfunction

    function [23:0] transition_image;
        input [23:0] color;
        input [2:0]  effect_i;
        input [1:0]  phase_i;
        input [4:0]  level_i;
        input [9:0]  x_i;
        input [8:0]  y_i;
        reg [9:0] span_x;
        reg [8:0] span_y;
        reg [9:0] edge_x;
        reg       show_image;
        begin
            span_x = level_i * 10'd20;
            span_y = level_i * 9'd15;
            edge_x = level_i * 10'd40;
            show_image = 1'b1;

            case (effect_i)
                EFFECT_FADE: begin
                    transition_image = fade_image(color, level_i);
                end
                EFFECT_WIPE_LEFT: begin
                    if (phase_i == TRANSITION_FADE_OUT)
                        show_image = (x_i >= (10'd640 - edge_x));
                    else if ((phase_i == TRANSITION_WAIT_SWITCH) ||
                             (phase_i == TRANSITION_FADE_IN))
                        show_image = (x_i < edge_x);
                    transition_image = show_image ? color : 24'h000000;
                end
                EFFECT_WIPE_RIGHT: begin
                    if (phase_i == TRANSITION_FADE_OUT)
                        show_image = (x_i < edge_x);
                    else if ((phase_i == TRANSITION_WAIT_SWITCH) ||
                             (phase_i == TRANSITION_FADE_IN))
                        show_image = (x_i >= (10'd640 - edge_x));
                    transition_image = show_image ? color : 24'h000000;
                end
                EFFECT_CENTER_EXPAND: begin
                    if (phase_i == TRANSITION_IDLE)
                        show_image = 1'b1;
                    else if (phase_i == TRANSITION_WAIT_SWITCH)
                        show_image = 1'b0;
                    else
                        show_image = (x_i >= (10'd320 - span_x)) &&
                                     (x_i <  (10'd320 + span_x)) &&
                                     (y_i >= (9'd240 - span_y)) &&
                                     (y_i <  (9'd240 + span_y));
                    transition_image = show_image ? color : 24'h000000;
                end
                EFFECT_BLINDS: begin
                    // Sixteen-line cells, common 0..16 visible fraction.
                    show_image = ({1'b0, y_i[3:0]} < level_i);
                    transition_image = show_image ? color : 24'h000000;
                end
                EFFECT_CHECKER: begin
                    // Alternating 32-pixel cells reveal from opposite directions.
                    if (x_i[5] ^ y_i[5])
                        show_image = ({1'b0,x_i[4:0]} < {level_i,1'b0});
                    else
                        show_image = ({1'b0,x_i[4:0]} >= (6'd32 - {level_i,1'b0}));
                    transition_image = show_image ? color : 24'h000000;
                end
                EFFECT_VERTICAL: begin
                    show_image = (y_i >= (9'd240 - span_y)) &&
                                 (y_i < (9'd240 + span_y));
                    transition_image = show_image ? color : 24'h000000;
                end
                default: begin
                    // Direct mode still waits for a protected frame boundary,
                    // but it never inserts a black frame or a pixel mask.
                    transition_image = color;
                end
            endcase
        end
    endfunction

    function [7:0] osd_char;
        input [4:0] index;
        input [2:0] mode_i;
        input       auto_i;
        input [3:0] key_i;
        input [3:0] state_i;
        input [1:0] buffer_i;
        begin
            case (index)
                5'd0:  osd_char = 8'h46; // F
                5'd1:  osd_char = 8'h50; // P
                5'd2:  osd_char = 8'h47; // G
                5'd3:  osd_char = 8'h41; // A
                5'd4:  osd_char = 8'h20; // space
                5'd5:  osd_char = 8'h4f; // O
                5'd6:  osd_char = 8'h53; // S
                5'd7:  osd_char = 8'h44; // D
                5'd8:  osd_char = 8'h20; // space
                5'd9:  osd_char = 8'h4d; // M
                5'd10: osd_char = 8'h3a; // :
                5'd11: osd_char = 8'h30 + mode_i;
                5'd12: osd_char = 8'h20; // space
                5'd13: osd_char = 8'h41; // A
                5'd14: osd_char = 8'h3a; // :
                5'd15: osd_char = auto_i ? 8'h31 : 8'h30;
                5'd16: osd_char = 8'h20; // space
                5'd17: osd_char = 8'h4b; // K
                5'd18: osd_char = 8'h3a; // :
                5'd19: osd_char = (key_i <= 4'd4) ? (8'h30 + key_i) : 8'h3f;
                5'd20: osd_char = 8'h20; // space
                5'd21: osd_char = 8'h53; // S
                5'd22: osd_char = 8'h3a; // :
                5'd23: osd_char = (state_i <= 4'd9) ? (8'h30 + state_i) : 8'h3f;
                5'd24: osd_char = 8'h20; // space
                5'd25: osd_char = 8'h44; // D
                5'd26: osd_char = 8'h3a; // :
                5'd27: osd_char = 8'h30 + buffer_i;
                default: osd_char = 8'h20;
            endcase
        end
    endfunction

    function [7:0] parameter_osd_char;
        input [5:0] index;
        input [6:0] brightness_i;
        input [6:0] contrast_i;
        input [6:0] volume_i;
        input       manual_note_i;
        input       manual_gate_i;
        input [2:0] manual_index_i;
        input [2:0] effect_i;
        input [3:0] interval_i;
        reg [6:0] brightness_magnitude;
        reg [7:0] contrast_percent;
        begin
            brightness_magnitude = (brightness_i < 7'd50) ?
                                   (7'd50 - brightness_i) :
                                   (brightness_i - 7'd50);
            contrast_percent = 8'd50 + contrast_i;
            parameter_osd_char = 8'h20;
            case (index)
                5'd0: parameter_osd_char = 8'h42; // B
                5'd1: parameter_osd_char = 8'h3a; // :
                5'd2: parameter_osd_char = (brightness_i < 7'd50) ? 8'h2d :
                                                (brightness_i > 7'd50) ? 8'h2b : 8'h20;
                5'd3: parameter_osd_char = 8'h30 + (brightness_magnitude / 10);
                5'd4: parameter_osd_char = 8'h30 + (brightness_magnitude % 10);
                5'd5: parameter_osd_char = 8'h20;
                5'd6: parameter_osd_char = 8'h43; // C
                5'd7: parameter_osd_char = 8'h3a; // :
                5'd8: parameter_osd_char = 8'h30 + (contrast_percent / 100);
                5'd9: parameter_osd_char = 8'h30 + ((contrast_percent % 100) / 10);
                5'd10: parameter_osd_char = 8'h30 + (contrast_percent % 10);
                5'd11: parameter_osd_char = 8'h25; // %
                5'd12: parameter_osd_char = 8'h20;
                5'd13: parameter_osd_char = 8'h56; // V
                5'd14: parameter_osd_char = 8'h3a; // :
                5'd15: parameter_osd_char = 8'h30 + (volume_i / 100);
                5'd16: parameter_osd_char = 8'h30 + ((volume_i % 100) / 10);
                5'd17: parameter_osd_char = 8'h30 + (volume_i % 10);
                5'd18: parameter_osd_char = 8'h25; // %
                5'd19: parameter_osd_char = 8'h20;
                5'd20: parameter_osd_char = 8'h54; // T
                5'd21: parameter_osd_char = 8'h3a; // :
                5'd22: parameter_osd_char = !manual_note_i ? 8'h41 :
                                               !manual_gate_i ? 8'h2d :
                                               (8'h30 + manual_index_i);
                5'd23: parameter_osd_char = 8'h20;
                5'd24: parameter_osd_char = 8'h45; // E
                5'd25: parameter_osd_char = 8'h3a; // :
                5'd26: parameter_osd_char = 8'h30 + effect_i;
                6'd27: parameter_osd_char = 8'h20;
                6'd28: parameter_osd_char = 8'h49; // I
                6'd29: parameter_osd_char = 8'h3a; // :
                6'd30: parameter_osd_char = 8'h30 + (interval_i / 10);
                6'd31: parameter_osd_char = 8'h30 + (interval_i % 10);
                6'd32: parameter_osd_char = 8'h53; // S
                default: parameter_osd_char = 8'h20;
            endcase
        end
    endfunction

    function [7:0] subtitle_char;
        input [1:0] message_i;
        input [4:0] index;
        begin
            subtitle_char = 8'h20;
            case (message_i)
                2'd0: begin // FPGA OSD
                    case (index)
                        5'd0: subtitle_char = 8'h46;
                        5'd1: subtitle_char = 8'h50;
                        5'd2: subtitle_char = 8'h47;
                        5'd3: subtitle_char = 8'h41;
                        5'd5: subtitle_char = 8'h4f;
                        5'd6: subtitle_char = 8'h53;
                        5'd7: subtitle_char = 8'h44;
                        default: subtitle_char = 8'h20;
                    endcase
                end
                2'd1: begin // MODE 1
                    case (index)
                        5'd0: subtitle_char = 8'h4d;
                        5'd1: subtitle_char = 8'h4f;
                        5'd2: subtitle_char = 8'h44;
                        5'd3: subtitle_char = 8'h45;
                        5'd5: subtitle_char = 8'h31;
                        default: subtitle_char = 8'h20;
                    endcase
                end
                2'd2: begin // AUTO PLAY
                    case (index)
                        5'd0: subtitle_char = 8'h41;
                        5'd1: subtitle_char = 8'h55;
                        5'd2: subtitle_char = 8'h54;
                        5'd3: subtitle_char = 8'h4f;
                        5'd5: subtitle_char = 8'h50;
                        5'd6: subtitle_char = 8'h4c;
                        5'd7: subtitle_char = 8'h41;
                        5'd8: subtitle_char = 8'h59;
                        default: subtitle_char = 8'h20;
                    endcase
                end
                default: begin // KEY 4
                    case (index)
                        5'd0: subtitle_char = 8'h4b;
                        5'd1: subtitle_char = 8'h45;
                        5'd2: subtitle_char = 8'h59;
                        5'd4: subtitle_char = 8'h34;
                        default: subtitle_char = 8'h20;
                    endcase
                end
            endcase
        end
    endfunction

    function [4:0] osd_font_row;
        input [7:0] char_code;
        input [2:0] row;
        begin
            osd_font_row = 5'b00000;
            case (char_code)
                8'h25: begin // %
                    case (row)
                        3'd0: osd_font_row = 5'b11001;
                        3'd1: osd_font_row = 5'b11010;
                        3'd2: osd_font_row = 5'b00100;
                        3'd3: osd_font_row = 5'b01000;
                        3'd4: osd_font_row = 5'b10110;
                        3'd5: osd_font_row = 5'b00110;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h2b: begin // +
                    case (row)
                        3'd1, 3'd2, 3'd4, 3'd5: osd_font_row = 5'b00100;
                        3'd3: osd_font_row = 5'b11111;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h2d: begin // -
                    case (row)
                        3'd3: osd_font_row = 5'b11111;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h41: begin // A
                    case (row)
                        3'd0: osd_font_row = 5'b01110;
                        3'd1: osd_font_row = 5'b10001;
                        3'd2: osd_font_row = 5'b10001;
                        3'd3: osd_font_row = 5'b11111;
                        3'd4: osd_font_row = 5'b10001;
                        3'd5: osd_font_row = 5'b10001;
                        3'd6: osd_font_row = 5'b10001;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h42: begin // B
                    case (row)
                        3'd0: osd_font_row = 5'b11110;
                        3'd1: osd_font_row = 5'b10001;
                        3'd2: osd_font_row = 5'b10001;
                        3'd3: osd_font_row = 5'b11110;
                        3'd4: osd_font_row = 5'b10001;
                        3'd5: osd_font_row = 5'b10001;
                        3'd6: osd_font_row = 5'b11110;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h43: begin // C
                    case (row)
                        3'd0: osd_font_row = 5'b01111;
                        3'd1: osd_font_row = 5'b10000;
                        3'd2: osd_font_row = 5'b10000;
                        3'd3: osd_font_row = 5'b10000;
                        3'd4: osd_font_row = 5'b10000;
                        3'd5: osd_font_row = 5'b10000;
                        3'd6: osd_font_row = 5'b01111;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h44: begin // D
                    case (row)
                        3'd0: osd_font_row = 5'b11110;
                        3'd1: osd_font_row = 5'b10001;
                        3'd2: osd_font_row = 5'b10001;
                        3'd3: osd_font_row = 5'b10001;
                        3'd4: osd_font_row = 5'b10001;
                        3'd5: osd_font_row = 5'b10001;
                        3'd6: osd_font_row = 5'b11110;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h46: begin // F
                    case (row)
                        3'd0: osd_font_row = 5'b11111;
                        3'd1: osd_font_row = 5'b10000;
                        3'd2: osd_font_row = 5'b10000;
                        3'd3: osd_font_row = 5'b11110;
                        3'd4: osd_font_row = 5'b10000;
                        3'd5: osd_font_row = 5'b10000;
                        3'd6: osd_font_row = 5'b10000;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h45: begin // E
                    case (row)
                        3'd0: osd_font_row = 5'b11111;
                        3'd1: osd_font_row = 5'b10000;
                        3'd2: osd_font_row = 5'b10000;
                        3'd3: osd_font_row = 5'b11110;
                        3'd4: osd_font_row = 5'b10000;
                        3'd5: osd_font_row = 5'b10000;
                        3'd6: osd_font_row = 5'b11111;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h47: begin // G
                    case (row)
                        3'd0: osd_font_row = 5'b01110;
                        3'd1: osd_font_row = 5'b10001;
                        3'd2: osd_font_row = 5'b10000;
                        3'd3: osd_font_row = 5'b10111;
                        3'd4: osd_font_row = 5'b10001;
                        3'd5: osd_font_row = 5'b10001;
                        3'd6: osd_font_row = 5'b01110;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h49: begin // I
                    case (row)
                        3'd0: osd_font_row = 5'b11111;
                        3'd1: osd_font_row = 5'b00100;
                        3'd2: osd_font_row = 5'b00100;
                        3'd3: osd_font_row = 5'b00100;
                        3'd4: osd_font_row = 5'b00100;
                        3'd5: osd_font_row = 5'b00100;
                        3'd6: osd_font_row = 5'b11111;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h4b: begin // K
                    case (row)
                        3'd0: osd_font_row = 5'b10001;
                        3'd1: osd_font_row = 5'b10010;
                        3'd2: osd_font_row = 5'b10100;
                        3'd3: osd_font_row = 5'b11000;
                        3'd4: osd_font_row = 5'b10100;
                        3'd5: osd_font_row = 5'b10010;
                        3'd6: osd_font_row = 5'b10001;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h4d: begin // M
                    case (row)
                        3'd0: osd_font_row = 5'b10001;
                        3'd1: osd_font_row = 5'b11011;
                        3'd2: osd_font_row = 5'b10101;
                        3'd3: osd_font_row = 5'b10101;
                        3'd4: osd_font_row = 5'b10001;
                        3'd5: osd_font_row = 5'b10001;
                        3'd6: osd_font_row = 5'b10001;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h4f: begin // O
                    case (row)
                        3'd0: osd_font_row = 5'b01110;
                        3'd1: osd_font_row = 5'b10001;
                        3'd2: osd_font_row = 5'b10001;
                        3'd3: osd_font_row = 5'b10001;
                        3'd4: osd_font_row = 5'b10001;
                        3'd5: osd_font_row = 5'b10001;
                        3'd6: osd_font_row = 5'b01110;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h4c: begin // L
                    case (row)
                        3'd0: osd_font_row = 5'b10000;
                        3'd1: osd_font_row = 5'b10000;
                        3'd2: osd_font_row = 5'b10000;
                        3'd3: osd_font_row = 5'b10000;
                        3'd4: osd_font_row = 5'b10000;
                        3'd5: osd_font_row = 5'b10000;
                        3'd6: osd_font_row = 5'b11111;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h50: begin // P
                    case (row)
                        3'd0: osd_font_row = 5'b11110;
                        3'd1: osd_font_row = 5'b10001;
                        3'd2: osd_font_row = 5'b10001;
                        3'd3: osd_font_row = 5'b11110;
                        3'd4: osd_font_row = 5'b10000;
                        3'd5: osd_font_row = 5'b10000;
                        3'd6: osd_font_row = 5'b10000;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h53: begin // S
                    case (row)
                        3'd0: osd_font_row = 5'b01111;
                        3'd1: osd_font_row = 5'b10000;
                        3'd2: osd_font_row = 5'b10000;
                        3'd3: osd_font_row = 5'b01110;
                        3'd4: osd_font_row = 5'b00001;
                        3'd5: osd_font_row = 5'b00001;
                        3'd6: osd_font_row = 5'b11110;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h54: begin // T
                    case (row)
                        3'd0: osd_font_row = 5'b11111;
                        3'd1: osd_font_row = 5'b00100;
                        3'd2: osd_font_row = 5'b00100;
                        3'd3: osd_font_row = 5'b00100;
                        3'd4: osd_font_row = 5'b00100;
                        3'd5: osd_font_row = 5'b00100;
                        3'd6: osd_font_row = 5'b00100;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h55: begin // U
                    case (row)
                        3'd0: osd_font_row = 5'b10001;
                        3'd1: osd_font_row = 5'b10001;
                        3'd2: osd_font_row = 5'b10001;
                        3'd3: osd_font_row = 5'b10001;
                        3'd4: osd_font_row = 5'b10001;
                        3'd5: osd_font_row = 5'b10001;
                        3'd6: osd_font_row = 5'b01110;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h56: begin // V
                    case (row)
                        3'd0: osd_font_row = 5'b10001;
                        3'd1: osd_font_row = 5'b10001;
                        3'd2: osd_font_row = 5'b10001;
                        3'd3: osd_font_row = 5'b10001;
                        3'd4: osd_font_row = 5'b10001;
                        3'd5: osd_font_row = 5'b01010;
                        3'd6: osd_font_row = 5'b00100;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h59: begin // Y
                    case (row)
                        3'd0: osd_font_row = 5'b10001;
                        3'd1: osd_font_row = 5'b10001;
                        3'd2: osd_font_row = 5'b01010;
                        3'd3: osd_font_row = 5'b00100;
                        3'd4: osd_font_row = 5'b00100;
                        3'd5: osd_font_row = 5'b00100;
                        3'd6: osd_font_row = 5'b00100;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h30: begin // 0
                    case (row)
                        3'd0: osd_font_row = 5'b01110;
                        3'd1: osd_font_row = 5'b10001;
                        3'd2: osd_font_row = 5'b10011;
                        3'd3: osd_font_row = 5'b10101;
                        3'd4: osd_font_row = 5'b11001;
                        3'd5: osd_font_row = 5'b10001;
                        3'd6: osd_font_row = 5'b01110;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h31: begin // 1
                    case (row)
                        3'd0: osd_font_row = 5'b00100;
                        3'd1: osd_font_row = 5'b01100;
                        3'd2: osd_font_row = 5'b00100;
                        3'd3: osd_font_row = 5'b00100;
                        3'd4: osd_font_row = 5'b00100;
                        3'd5: osd_font_row = 5'b00100;
                        3'd6: osd_font_row = 5'b01110;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h32: begin // 2
                    case (row)
                        3'd0: osd_font_row = 5'b01110;
                        3'd1: osd_font_row = 5'b10001;
                        3'd2: osd_font_row = 5'b00001;
                        3'd3: osd_font_row = 5'b00010;
                        3'd4: osd_font_row = 5'b00100;
                        3'd5: osd_font_row = 5'b01000;
                        3'd6: osd_font_row = 5'b11111;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h33: begin // 3
                    case (row)
                        3'd0: osd_font_row = 5'b11110;
                        3'd1: osd_font_row = 5'b00001;
                        3'd2: osd_font_row = 5'b00001;
                        3'd3: osd_font_row = 5'b01110;
                        3'd4: osd_font_row = 5'b00001;
                        3'd5: osd_font_row = 5'b00001;
                        3'd6: osd_font_row = 5'b11110;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h34: begin // 4
                    case (row)
                        3'd0: osd_font_row = 5'b00010;
                        3'd1: osd_font_row = 5'b00110;
                        3'd2: osd_font_row = 5'b01010;
                        3'd3: osd_font_row = 5'b10010;
                        3'd4: osd_font_row = 5'b11111;
                        3'd5: osd_font_row = 5'b00010;
                        3'd6: osd_font_row = 5'b00010;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h35: begin // 5
                    case (row)
                        3'd0: osd_font_row = 5'b11111;
                        3'd1: osd_font_row = 5'b10000;
                        3'd2: osd_font_row = 5'b10000;
                        3'd3: osd_font_row = 5'b11110;
                        3'd4: osd_font_row = 5'b00001;
                        3'd5: osd_font_row = 5'b00001;
                        3'd6: osd_font_row = 5'b11110;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h36: begin // 6
                    case (row)
                        3'd0: osd_font_row = 5'b01110;
                        3'd1: osd_font_row = 5'b10000;
                        3'd2: osd_font_row = 5'b10000;
                        3'd3: osd_font_row = 5'b11110;
                        3'd4: osd_font_row = 5'b10001;
                        3'd5: osd_font_row = 5'b10001;
                        3'd6: osd_font_row = 5'b01110;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h37: begin // 7
                    case (row)
                        3'd0: osd_font_row = 5'b11111;
                        3'd1: osd_font_row = 5'b00001;
                        3'd2: osd_font_row = 5'b00010;
                        3'd3: osd_font_row = 5'b00100;
                        3'd4: osd_font_row = 5'b01000;
                        3'd5: osd_font_row = 5'b01000;
                        3'd6: osd_font_row = 5'b01000;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h38: begin // 8
                    case (row)
                        3'd0: osd_font_row = 5'b01110;
                        3'd1: osd_font_row = 5'b10001;
                        3'd2: osd_font_row = 5'b10001;
                        3'd3: osd_font_row = 5'b01110;
                        3'd4: osd_font_row = 5'b10001;
                        3'd5: osd_font_row = 5'b10001;
                        3'd6: osd_font_row = 5'b01110;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h39: begin // 9
                    case (row)
                        3'd0: osd_font_row = 5'b01110;
                        3'd1: osd_font_row = 5'b10001;
                        3'd2: osd_font_row = 5'b10001;
                        3'd3: osd_font_row = 5'b01111;
                        3'd4: osd_font_row = 5'b00001;
                        3'd5: osd_font_row = 5'b00001;
                        3'd6: osd_font_row = 5'b01110;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                8'h3a: begin // colon
                    case (row)
                        3'd2: osd_font_row = 5'b00100;
                        3'd4: osd_font_row = 5'b00100;
                        default: osd_font_row = 5'b00000;
                    endcase
                end
                default: osd_font_row = 5'b00000;
            endcase
        end
    endfunction

    // Complete 5x7 Latin font used only by the editable subtitle. Keeping it
    // separate preserves the verified status-OSD glyphs while adding true
    // lowercase forms and common punctuation.
    function [4:0] subtitle_font_row;
        input [7:0] char_code;
        input [2:0] row;
        reg [34:0] glyph;
        begin
            subtitle_font_row = 5'b00000;
            glyph = 35'd0;
            case (char_code)
                8'h41: glyph = {5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001}; // A
                8'h42: glyph = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110}; // B
                8'h43: glyph = {5'b01111,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b01111}; // C
                8'h44: glyph = {5'b11110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b11110}; // D
                8'h45: glyph = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111}; // E
                8'h46: glyph = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000}; // F
                8'h47: glyph = {5'b01110,5'b10001,5'b10000,5'b10111,5'b10001,5'b10001,5'b01110}; // G
                8'h48: glyph = {5'b10001,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001}; // H
                8'h49: glyph = {5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b11111}; // I
                8'h4a: glyph = {5'b00001,5'b00001,5'b00001,5'b00001,5'b10001,5'b10001,5'b01110}; // J
                8'h4b: glyph = {5'b10001,5'b10010,5'b10100,5'b11000,5'b10100,5'b10010,5'b10001}; // K
                8'h4c: glyph = {5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111}; // L
                8'h4d: glyph = {5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001}; // M
                8'h4e: glyph = {5'b10001,5'b11001,5'b10101,5'b10011,5'b10001,5'b10001,5'b10001}; // N
                8'h4f: glyph = {5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110}; // O
                8'h50: glyph = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000}; // P
                8'h51: glyph = {5'b01110,5'b10001,5'b10001,5'b10001,5'b10101,5'b10010,5'b01101}; // Q
                8'h52: glyph = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001}; // R
                8'h53: glyph = {5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110}; // S
                8'h54: glyph = {5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100}; // T
                8'h55: glyph = {5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110}; // U
                8'h56: glyph = {5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01010,5'b00100}; // V
                8'h57: glyph = {5'b10001,5'b10001,5'b10001,5'b10101,5'b10101,5'b11011,5'b10001}; // W
                8'h58: glyph = {5'b10001,5'b10001,5'b01010,5'b00100,5'b01010,5'b10001,5'b10001}; // X
                8'h59: glyph = {5'b10001,5'b10001,5'b01010,5'b00100,5'b00100,5'b00100,5'b00100}; // Y
                8'h5a: glyph = {5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b10000,5'b11111}; // Z
                8'h61: glyph = {5'b00000,5'b00000,5'b01110,5'b00001,5'b01111,5'b10001,5'b01111}; // a
                8'h62: glyph = {5'b10000,5'b10000,5'b10110,5'b11001,5'b10001,5'b10001,5'b11110}; // b
                8'h63: glyph = {5'b00000,5'b00000,5'b01111,5'b10000,5'b10000,5'b10000,5'b01111}; // c
                8'h64: glyph = {5'b00001,5'b00001,5'b01101,5'b10011,5'b10001,5'b10001,5'b01111}; // d
                8'h65: glyph = {5'b00000,5'b00000,5'b01110,5'b10001,5'b11111,5'b10000,5'b01110}; // e
                8'h66: glyph = {5'b00110,5'b01001,5'b01000,5'b11100,5'b01000,5'b01000,5'b01000}; // f
                8'h67: glyph = {5'b00000,5'b01111,5'b10001,5'b10001,5'b01111,5'b00001,5'b01110}; // g
                8'h68: glyph = {5'b10000,5'b10000,5'b10110,5'b11001,5'b10001,5'b10001,5'b10001}; // h
                8'h69: glyph = {5'b00100,5'b00000,5'b01100,5'b00100,5'b00100,5'b00100,5'b01110}; // i
                8'h6a: glyph = {5'b00010,5'b00000,5'b00110,5'b00010,5'b00010,5'b10010,5'b01100}; // j
                8'h6b: glyph = {5'b10000,5'b10000,5'b10010,5'b10100,5'b11000,5'b10100,5'b10010}; // k
                8'h6c: glyph = {5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110}; // l
                8'h6d: glyph = {5'b00000,5'b00000,5'b11010,5'b10101,5'b10101,5'b10101,5'b10101}; // m
                8'h6e: glyph = {5'b00000,5'b00000,5'b10110,5'b11001,5'b10001,5'b10001,5'b10001}; // n
                8'h6f: glyph = {5'b00000,5'b00000,5'b01110,5'b10001,5'b10001,5'b10001,5'b01110}; // o
                8'h70: glyph = {5'b00000,5'b00000,5'b11110,5'b10001,5'b11110,5'b10000,5'b10000}; // p
                8'h71: glyph = {5'b00000,5'b00000,5'b01101,5'b10011,5'b01111,5'b00001,5'b00001}; // q
                8'h72: glyph = {5'b00000,5'b00000,5'b10110,5'b11001,5'b10000,5'b10000,5'b10000}; // r
                8'h73: glyph = {5'b00000,5'b00000,5'b01111,5'b10000,5'b01110,5'b00001,5'b11110}; // s
                8'h74: glyph = {5'b01000,5'b01000,5'b11100,5'b01000,5'b01000,5'b01001,5'b00110}; // t
                8'h75: glyph = {5'b00000,5'b00000,5'b10001,5'b10001,5'b10001,5'b10011,5'b01101}; // u
                8'h76: glyph = {5'b00000,5'b00000,5'b10001,5'b10001,5'b10001,5'b01010,5'b00100}; // v
                8'h77: glyph = {5'b00000,5'b00000,5'b10001,5'b10101,5'b10101,5'b10101,5'b01010}; // w
                8'h78: glyph = {5'b00000,5'b00000,5'b10001,5'b01010,5'b00100,5'b01010,5'b10001}; // x
                8'h79: glyph = {5'b00000,5'b00000,5'b10001,5'b10001,5'b01111,5'b00001,5'b01110}; // y
                8'h7a: glyph = {5'b00000,5'b00000,5'b11111,5'b00010,5'b00100,5'b01000,5'b11111}; // z
                8'h21: glyph = {5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00000,5'b00100}; // !
                8'h22: glyph = {5'b01010,5'b01010,5'b01010,5'b00000,5'b00000,5'b00000,5'b00000}; // double quote
                8'h27: glyph = {5'b00100,5'b00100,5'b01000,5'b00000,5'b00000,5'b00000,5'b00000}; // apostrophe
                8'h28: glyph = {5'b00010,5'b00100,5'b01000,5'b01000,5'b01000,5'b00100,5'b00010}; // (
                8'h29: glyph = {5'b01000,5'b00100,5'b00010,5'b00010,5'b00010,5'b00100,5'b01000}; // )
                8'h2a: glyph = {5'b00100,5'b10101,5'b01110,5'b11111,5'b01110,5'b10101,5'b00100}; // *
                8'h2c: glyph = {5'b00000,5'b00000,5'b00000,5'b00000,5'b00000,5'b00100,5'b01000}; // ,
                8'h2e: glyph = {5'b00000,5'b00000,5'b00000,5'b00000,5'b00000,5'b00000,5'b00100}; // .
                8'h2f: glyph = {5'b00001,5'b00010,5'b00100,5'b01000,5'b10000,5'b00000,5'b00000}; // /
                8'h3b: glyph = {5'b00000,5'b00100,5'b00000,5'b00000,5'b00100,5'b00100,5'b01000}; // ;
                8'h3d: glyph = {5'b00000,5'b00000,5'b11111,5'b00000,5'b11111,5'b00000,5'b00000}; // =
                8'h3f: glyph = {5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b00000,5'b00100}; // ?
                8'h5f: glyph = {5'b00000,5'b00000,5'b00000,5'b00000,5'b00000,5'b00000,5'b11111}; // _
                default: begin
                    subtitle_font_row = osd_font_row(char_code, row);
                    glyph = 35'd0;
                end
            endcase
            if ((char_code >= 8'h41 && char_code <= 8'h5a) ||
                (char_code >= 8'h61 && char_code <= 8'h7a) ||
                char_code == 8'h21 || char_code == 8'h22 ||
                char_code == 8'h27 || char_code == 8'h28 ||
                char_code == 8'h29 || char_code == 8'h2a ||
                char_code == 8'h2c || char_code == 8'h2e ||
                char_code == 8'h2f || char_code == 8'h3b ||
                char_code == 8'h3d || char_code == 8'h3f ||
                char_code == 8'h5f) begin
                case (row)
                    3'd0: subtitle_font_row = glyph[34:30];
                    3'd1: subtitle_font_row = glyph[29:25];
                    3'd2: subtitle_font_row = glyph[24:20];
                    3'd3: subtitle_font_row = glyph[19:15];
                    3'd4: subtitle_font_row = glyph[14:10];
                    3'd5: subtitle_font_row = glyph[9:5];
                    default: subtitle_font_row = glyph[4:0];
                endcase
            end
        end
    endfunction

    function [23:0] subtitle_color_rgb;
        input [2:0] color_index;
        begin
            case (color_index)
                3'd0: subtitle_color_rgb = 24'hffffff; // white
                3'd1: subtitle_color_rgb = 24'hffe070; // yellow
                3'd2: subtitle_color_rgb = 24'h40ffff; // cyan
                3'd3: subtitle_color_rgb = 24'h40ff80; // green
                3'd4: subtitle_color_rgb = 24'hff9000; // orange
                3'd5: subtitle_color_rgb = 24'hff60c0; // pink
                3'd6: subtitle_color_rgb = 24'hff4040; // red
                default: subtitle_color_rgb = 24'hffe070;
            endcase
        end
    endfunction

    key_press_debounce_bank #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_key_bank (
        .clk(clk),.rst(rst),.buttons({key4,key3,key_auto,key_next}),
        .press_pulses({key4_pulse,key3_pulse,key_auto_pulse,key_next_pulse})
    );

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            hs_d        <= 1'b0;
            vs_d        <= 1'b0;
            de_d        <= 1'b0;
            x           <= 10'd0;
            y           <= 9'd0;
            mode        <= 2'd1;
            auto_play   <= 1'b0;
            auto_count  <= 26'd0;
            auto_elapsed_seconds <= 4'd0;
            auto_interval_seconds <= 4'd2;
            brightness_level <= 7'd50;
            contrast_level <= 7'd50;
            volume_level <= 7'd50;
            brightness_request <= 7'd50;
            contrast_request <= 7'd50;
            last_key_code <= 4'd0;
            subtitle_x <= 11'sd640;
            subtitle_delay <= 6'd0;
            subtitle_message <= 2'd0;
            subtitle_text_active <= 256'd0;
            subtitle_length_active <= 6'd0;
            subtitle_color_active <= 3'd1;
            subtitle_bitmap_active <= 1'b0;
            base_enable_sync0 <= 1'b0;
            base_enable_sync1 <= 1'b0;
            frame_buffer_sync0 <= 2'd0;
            frame_buffer_sync1 <= 2'd0;
            frame_buffer_request_sync0 <= 2'd0;
            frame_buffer_request_sync1 <= 2'd0;
            transition_phase <= TRANSITION_IDLE;
            transition_level <= TRANSITION_FULL_LEVEL;
            transition_mode_latched <= EFFECT_FADE;
            audio_frame_peak <= 24'd0;
            for (audio_bar_i = 0; audio_bar_i < 8; audio_bar_i = audio_bar_i + 1) begin
                audio_bar_height[audio_bar_i] <= AUDIO_BAR_IDLE_HEIGHT;
                audio_peak_height[audio_bar_i] <= AUDIO_BAR_IDLE_HEIGHT;
                audio_peak_hold[audio_bar_i] <= 4'd0;
            end
        end else begin
            hs_d       <= hs;
            vs_d       <= vs;
            de_d       <= de;
            base_enable_sync0 <= use_base;
            base_enable_sync1 <= base_enable_sync0;
            frame_buffer_sync0 <= frame_buffer;
            frame_buffer_sync1 <= frame_buffer_sync0;
            frame_buffer_request_sync0 <= frame_buffer_request;
            frame_buffer_request_sync1 <= frame_buffer_request_sync0;
            if (audio_sample_valid &&
                (audio_abs_24(audio_sample) > audio_frame_peak))
                audio_frame_peak <= audio_abs_24(audio_sample);
            if (vs_d && !vs) begin
                x <= 10'd0;
                y <= 9'd0;
                brightness_level <= brightness_request;
                contrast_level <= contrast_request;
                volume_level <= audio_volume;

                audio_frame_peak <= 24'd0;

                // PCM motion is refreshed by HDMI VS, NOT the 8 fps media
                // queue. Tone mode retains its previously accepted motion.
                for (audio_bar_i = 0; audio_bar_i < 8; audio_bar_i = audio_bar_i + 1) begin
                    if (audio_pcm_mode) begin
                        audio_bar_height[audio_bar_i] <= audio_bar_next[audio_bar_i];
                        if (audio_bar_next[audio_bar_i] >= audio_peak_height[audio_bar_i]) begin
                            audio_peak_height[audio_bar_i] <= audio_bar_next[audio_bar_i];
                            audio_peak_hold[audio_bar_i] <= 4'd12;
                        end else if (audio_peak_hold[audio_bar_i] != 4'd0) begin
                            audio_peak_hold[audio_bar_i] <= audio_peak_hold[audio_bar_i] - 1'b1;
                        end else if ((audio_peak_height[audio_bar_i] - audio_bar_next[audio_bar_i]) > 7'd2) begin
                            audio_peak_height[audio_bar_i] <= audio_peak_height[audio_bar_i] - 7'd2;
                        end else begin
                            audio_peak_height[audio_bar_i] <= audio_bar_next[audio_bar_i];
                        end
                    end else if (audio_bar_height[audio_bar_i] < audio_target[audio_bar_i]) begin
                        if ((audio_target[audio_bar_i] - audio_bar_height[audio_bar_i]) <=
                            AUDIO_BAR_RISE_STEP)
                            audio_bar_height[audio_bar_i] <= audio_target[audio_bar_i];
                        else
                            audio_bar_height[audio_bar_i] <=
                                audio_bar_height[audio_bar_i] + AUDIO_BAR_RISE_STEP;
                    end else if (audio_bar_height[audio_bar_i] > audio_target[audio_bar_i]) begin
                        if ((audio_bar_height[audio_bar_i] - audio_target[audio_bar_i]) <=
                            AUDIO_BAR_FALL_STEP)
                            audio_bar_height[audio_bar_i] <= audio_target[audio_bar_i];
                        else
                            audio_bar_height[audio_bar_i] <=
                                audio_bar_height[audio_bar_i] - AUDIO_BAR_FALL_STEP;
                    end
                end

                if (!base_active) begin
                    transition_phase <= TRANSITION_IDLE;
                    transition_level <= TRANSITION_FULL_LEVEL;
                end else begin
                    case (transition_phase)
                        TRANSITION_IDLE: begin
                            transition_level <= TRANSITION_FULL_LEVEL;
                            if (frame_buffer_request_sync1 != frame_buffer_sync1) begin
                                transition_mode_latched <= transition_mode;
                                if (transition_mode == EFFECT_DIRECT) begin
                                    transition_phase <= TRANSITION_WAIT_SWITCH;
                                    transition_level <= TRANSITION_FULL_LEVEL;
                                end else begin
                                    transition_phase <= TRANSITION_FADE_OUT;
                                    transition_level <= TRANSITION_FULL_LEVEL - 1'b1;
                                end
                            end
                        end
                        TRANSITION_FADE_OUT: begin
                            if (frame_buffer_request_sync1 == frame_buffer_sync1) begin
                                // A newer command cancelled the pending switch.
                                transition_phase <= TRANSITION_FADE_IN;
                            end else if (transition_level <= 5'd1) begin
                                transition_level <= 5'd0;
                                transition_phase <= TRANSITION_WAIT_SWITCH;
                            end else begin
                                transition_level <= transition_level - 1'b1;
                            end
                        end
                        TRANSITION_WAIT_SWITCH: begin
                            transition_level <=
                                (transition_mode_latched == EFFECT_DIRECT) ?
                                TRANSITION_FULL_LEVEL : 5'd0;
                            if (frame_buffer_request_sync1 == frame_buffer_sync1) begin
                                if (transition_mode_latched == EFFECT_DIRECT)
                                    transition_phase <= TRANSITION_IDLE;
                                else
                                    transition_phase <= TRANSITION_FADE_IN;
                            end
                        end
                        default: begin // TRANSITION_FADE_IN
                            if (frame_buffer_request_sync1 != frame_buffer_sync1) begin
                                transition_phase <= TRANSITION_FADE_OUT;
                                transition_mode_latched <= transition_mode;
                            end else if (transition_level >=
                                         (TRANSITION_FULL_LEVEL - 1'b1)) begin
                                transition_level <= TRANSITION_FULL_LEVEL;
                                transition_phase <= TRANSITION_IDLE;
                            end else begin
                                transition_level <= transition_level + 1'b1;
                            end
                        end
                    endcase
                end
            end else if (de) begin
                if (x == 10'd639)
                    x <= 10'd0;
                else
                    x <= x + 1'b1;
            end else if (de_d) begin
                x <= 10'd0;
                if (y != 9'd479)
                    y <= y + 1'b1;
            end

            // Move the subtitle once per frame. It leaves the screen completely,
            // pauses, then restarts from the right edge.
            if (touch_subtitle_commit_event) begin
                subtitle_text_active <= touch_subtitle_text;
                subtitle_length_active <=
                    (touch_subtitle_length > 6'd32) ?
                    6'd32 : touch_subtitle_length;
                subtitle_color_active <=
                    (touch_subtitle_color > 3'd6) ?
                    3'd1 : touch_subtitle_color;
                subtitle_bitmap_active <= touch_subtitle_bitmap_mode;
                subtitle_x <= 11'sd640;
                subtitle_delay <= 6'd0;
            end else if (vs_d && !vs) begin
                if (subtitle_delay != 0) begin
                    subtitle_delay <= subtitle_delay - 1'b1;
                end else if (subtitle_x <= -subtitle_active_width) begin
                    subtitle_x <= 11'sd640;
                    subtitle_delay <= SUBTITLE_DELAY_FRAMES[5:0];
                    if (subtitle_length_active == 0)
                        subtitle_message <= (subtitle_message == 2'd3) ?
                                            2'd0 : subtitle_message + 1'b1;
                end else begin
                    subtitle_x <= subtitle_x - 11'sd2;
                end
            end

            // Any manual request has priority and exits automatic playback.
            // Touch commands are explicit; the physical K2 remains a toggle.
            if (manual_command_pulse) begin
                if (prev_command_pulse)
                    mode <= (mode == 2'd0) ? 2'd3 : mode - 1'b1;
                else
                    mode <= (mode == 2'd3) ? 2'd0 : mode + 1'b1;
                auto_play <= 1'b0;
                last_key_code <= 4'd1;
            end else if (touch_auto_stop_event) begin
                auto_play <= 1'b0;
                last_key_code <= 4'd2;
            end else if (touch_auto_start_event) begin
                auto_play <= 1'b1;
                last_key_code <= 4'd2;
            end else if (key_auto_pulse) begin
                auto_play <= ~auto_play;
                last_key_code <= 4'd2;
            end
            if (touch_brightness_event) begin
                last_key_code <= 4'd3;
                brightness_request <= (touch_brightness_value > 7'd100) ?
                                      7'd100 : touch_brightness_value;
            end else if (key3_pulse) begin
                last_key_code <= 4'd3;
                brightness_request <= (brightness_request >= 7'd100) ? 7'd0 :
                                      (brightness_request >= 7'd75) ? 7'd100 :
                                      brightness_request + 7'd25;
            end
            if (touch_contrast_event) begin
                last_key_code <= 4'd4;
                contrast_request <= (touch_contrast_value > 7'd100) ?
                                    7'd100 : touch_contrast_value;
            end else if (key4_pulse) begin
                last_key_code <= 4'd4;
                contrast_request <= (contrast_request >= 7'd100) ? 7'd0 :
                                    (contrast_request >= 7'd75) ? 7'd100 :
                                    contrast_request + 7'd25;
            end

            if (touch_interval_event) begin
                auto_interval_seconds <=
                    ((frame_interval_seconds >= 4'd1) &&
                     (frame_interval_seconds <= 4'd15)) ?
                    frame_interval_seconds : 4'd2;
            end

            // Show the period accepted by the TF slideshow state machine,
            // instead of echoing the touch request on an independent path.
            if ((frame_interval_seconds >= 4'd1) &&
                (frame_interval_seconds <= 4'd15))
                auto_interval_seconds <= frame_interval_seconds;

            if (manual_command_pulse || auto_command_pulse ||
                touch_interval_event || !auto_play) begin
                auto_count <= 26'd0;
                auto_elapsed_seconds <= 4'd0;
            end else begin
                if (auto_second_tick) begin
                    auto_count <= 26'd0;
                    if ((auto_elapsed_seconds + 1'b1) >=
                        auto_interval_seconds) begin
                        auto_elapsed_seconds <= 4'd0;
                        mode <= (mode == 2'd3) ? 2'd0 : mode + 1'b1;
                    end else begin
                        auto_elapsed_seconds <= auto_elapsed_seconds + 1'b1;
                    end
                end else begin
                    auto_count <= auto_count + 1'b1;
                end
            end
        end
    end

    function [4:0] unified_font_row;
        input [7:0] code;
        input [2:0] row;
        input subtitle;
        reg [34:0] glyph;
        reg osd_supported,subtitle_last_row;
        begin
            glyph=0;osd_supported=0;subtitle_last_row=0;
            case(code)
                8'h21:begin glyph=35'h108421004;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h22:begin glyph=35'h294a00000;osd_supported=1'b0;subtitle_last_row=1'b0;end
                8'h25:begin glyph=35'h6744458c0;osd_supported=1'b1;subtitle_last_row=1'b0;end
                8'h27:begin glyph=35'h108800000;osd_supported=1'b0;subtitle_last_row=1'b0;end
                8'h28:begin glyph=35'h088842082;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h29:begin glyph=35'h208210888;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h2a:begin glyph=35'h12aefbaa4;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h2b:begin glyph=35'h0084f9080;osd_supported=1'b1;subtitle_last_row=1'b0;end
                8'h2c:begin glyph=35'h000000088;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h2d:begin glyph=35'h0000f8000;osd_supported=1'b1;subtitle_last_row=1'b0;end
                8'h2e:begin glyph=35'h000000004;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h2f:begin glyph=35'h044444000;osd_supported=1'b0;subtitle_last_row=1'b0;end
                8'h30:begin glyph=35'h3a33ae62e;osd_supported=1'b1;subtitle_last_row=1'b0;end
                8'h31:begin glyph=35'h11842108e;osd_supported=1'b1;subtitle_last_row=1'b0;end
                8'h32:begin glyph=35'h3a211111f;osd_supported=1'b1;subtitle_last_row=1'b0;end
                8'h33:begin glyph=35'h78217043e;osd_supported=1'b1;subtitle_last_row=1'b0;end
                8'h34:begin glyph=35'h08ca97c42;osd_supported=1'b1;subtitle_last_row=1'b0;end
                8'h35:begin glyph=35'h7e10f043e;osd_supported=1'b1;subtitle_last_row=1'b0;end
                8'h36:begin glyph=35'h3a10f462e;osd_supported=1'b1;subtitle_last_row=1'b0;end
                8'h37:begin glyph=35'h7c2222108;osd_supported=1'b1;subtitle_last_row=1'b0;end
                8'h38:begin glyph=35'h3a317462e;osd_supported=1'b1;subtitle_last_row=1'b0;end
                8'h39:begin glyph=35'h3a317842e;osd_supported=1'b1;subtitle_last_row=1'b0;end
                8'h3a:begin glyph=35'h000401000;osd_supported=1'b1;subtitle_last_row=1'b0;end
                8'h3b:begin glyph=35'h008001088;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h3d:begin glyph=35'h001f07c00;osd_supported=1'b0;subtitle_last_row=1'b0;end
                8'h3f:begin glyph=35'h3a2111004;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h41:begin glyph=35'h3a31fc631;osd_supported=1'b1;subtitle_last_row=1'b1;end
                8'h42:begin glyph=35'h7a31f463e;osd_supported=1'b1;subtitle_last_row=1'b1;end
                8'h43:begin glyph=35'h3e108420f;osd_supported=1'b1;subtitle_last_row=1'b1;end
                8'h44:begin glyph=35'h7a318c63e;osd_supported=1'b1;subtitle_last_row=1'b1;end
                8'h45:begin glyph=35'h7e10f421f;osd_supported=1'b1;subtitle_last_row=1'b1;end
                8'h46:begin glyph=35'h7e10f4210;osd_supported=1'b1;subtitle_last_row=1'b1;end
                8'h47:begin glyph=35'h3a30bc62e;osd_supported=1'b1;subtitle_last_row=1'b1;end
                8'h48:begin glyph=35'h4631fc631;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h49:begin glyph=35'h7c842109f;osd_supported=1'b1;subtitle_last_row=1'b1;end
                8'h4a:begin glyph=35'h04210c62e;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h4b:begin glyph=35'h4654c5251;osd_supported=1'b1;subtitle_last_row=1'b1;end
                8'h4c:begin glyph=35'h42108421f;osd_supported=1'b1;subtitle_last_row=1'b1;end
                8'h4d:begin glyph=35'h4775ac631;osd_supported=1'b1;subtitle_last_row=1'b1;end
                8'h4e:begin glyph=35'h47359c631;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h4f:begin glyph=35'h3a318c62e;osd_supported=1'b1;subtitle_last_row=1'b1;end
                8'h50:begin glyph=35'h7a31f4210;osd_supported=1'b1;subtitle_last_row=1'b1;end
                8'h51:begin glyph=35'h3a318d64d;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h52:begin glyph=35'h7a31f5251;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h53:begin glyph=35'h3e107043e;osd_supported=1'b1;subtitle_last_row=1'b1;end
                8'h54:begin glyph=35'h7c8421084;osd_supported=1'b1;subtitle_last_row=1'b1;end
                8'h55:begin glyph=35'h46318c62e;osd_supported=1'b1;subtitle_last_row=1'b1;end
                8'h56:begin glyph=35'h46318c544;osd_supported=1'b1;subtitle_last_row=1'b1;end
                8'h57:begin glyph=35'h4631ad771;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h58:begin glyph=35'h462a22a31;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h59:begin glyph=35'h462a21084;osd_supported=1'b1;subtitle_last_row=1'b1;end
                8'h5a:begin glyph=35'h7c222221f;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h5f:begin glyph=35'h00000001f;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h61:begin glyph=35'h000e0be2f;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h62:begin glyph=35'h4216cc63e;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h63:begin glyph=35'h000f8420f;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h64:begin glyph=35'h042d9c62f;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h65:begin glyph=35'h000e8fe0e;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h66:begin glyph=35'h1928e2108;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h67:begin glyph=35'h01f18bc2e;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h68:begin glyph=35'h4216cc631;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h69:begin glyph=35'h100c2108e;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h6a:begin glyph=35'h080610a4c;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h6b:begin glyph=35'h4212a6292;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h6c:begin glyph=35'h30842108e;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h6d:begin glyph=35'h001aad6b5;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h6e:begin glyph=35'h0016cc631;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h6f:begin glyph=35'h000e8c62e;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h70:begin glyph=35'h001e8fa10;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h71:begin glyph=35'h000d9bc21;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h72:begin glyph=35'h0016cc210;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h73:begin glyph=35'h000f8383e;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h74:begin glyph=35'h211c42126;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h75:begin glyph=35'h00118c66d;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h76:begin glyph=35'h00118c544;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h77:begin glyph=35'h0011ad6aa;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h78:begin glyph=35'h001151151;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h79:begin glyph=35'h00118bc2e;osd_supported=1'b0;subtitle_last_row=1'b1;end
                8'h7a:begin glyph=35'h001f1111f;osd_supported=1'b0;subtitle_last_row=1'b1;end
                default:begin end
            endcase
            unified_font_row=0;
            if(subtitle || osd_supported) begin
                case(row)
                    3'd0:unified_font_row=glyph[34:30];
                    3'd1:unified_font_row=glyph[29:25];
                    3'd2:unified_font_row=glyph[24:20];
                    3'd3:unified_font_row=glyph[19:15];
                    3'd4:unified_font_row=glyph[14:10];
                    3'd5:unified_font_row=glyph[9:5];
                    3'd6:unified_font_row=glyph[4:0];
                    default:if(subtitle && subtitle_last_row) unified_font_row=glyph[4:0];
                endcase
            end
        end
    endfunction
    reg font_query_enable,font_query_subtitle;
    reg [7:0] font_query_code;
    reg [2:0] font_query_row,font_query_column;
    reg [23:0] font_query_color;
    wire [4:0] shared_font_row=unified_font_row(
        font_query_code,font_query_row,font_query_subtitle);
    always @(*) begin
        font_query_enable=0;font_query_subtitle=0;font_query_code=0;
        font_query_row=0;font_query_column=0;font_query_color=0;
        osd_char_index = 6'd0;
        osd_row_index  = 3'd0;
        osd_col_index  = 3'd0;
        osd_char_code  = 8'h20;
        osd_glyph_row  = 5'b00000;
        subtitle_rel_x = 12'sd0;
        subtitle_prefetch_rel_x = 12'sd0;
        subtitle_char_index = 5'd0;
        subtitle_row_index  = 3'd0;
        subtitle_col_index  = 3'd0;
        subtitle_bitmap_row_index = 4'd0;
        subtitle_bitmap_col_index = 4'd0;
        touch_subtitle_bitmap_address = 9'd0;
        subtitle_char_code  = 8'h20;
        audio_bar_slot      = 3'd0;
        audio_bar_column    = 6'd0;
        audio_bar_y_top     = AUDIO_BAR_Y_BASE;
        audio_bar_blended_rgb = 24'h000000;
        stage_base = (stage_style == 2) ? 10'd382 : 10'd446;
        stage_distance = 0; stage_peak_distance = 0;
        stage_color = 0;
        source_rgb = 24'h000000;
        pixel_rgb = 24'h000000;
        if (!de) begin
            pixel_rgb = 24'h000000;
        end else begin
            if (base_active) begin
                pixel_rgb = transition_image(
                    (compare_active && (x < compare_edge)) ? base_rgb :
                    adjust_image(base_rgb, brightness_level, contrast_level),
                    transition_mode_latched, transition_phase,
                    transition_level, x, y);
            end else begin
                case (mode)
                    2'd0: begin
                        case (x[9:7])
                            3'd0: source_rgb = 24'hffffff;
                            3'd1: source_rgb = 24'hffff00;
                            3'd2: source_rgb = 24'h00ffff;
                            3'd3: source_rgb = 24'h00ff00;
                            3'd4: source_rgb = 24'hff00ff;
                            3'd5: source_rgb = 24'hff0000;
                            3'd6: source_rgb = 24'h0000ff;
                            default: source_rgb = 24'h000000;
                        endcase
                    end
                    2'd1: begin
                        case (tile[5:4])
                            2'd0: source_rgb = 24'h163d70;
                            2'd1: source_rgb = 24'h25b7d3;
                            2'd2: source_rgb = 24'he5c84b;
                            default: source_rgb = 24'hd33f49;
                        endcase
                        if ((x[6] ^ y[6]))
                            source_rgb = source_rgb ^ 24'h202020;
                    end
                    2'd2: source_rgb = 24'hff2020;
                    default: begin
                        if ((x < 10'd8) || (x >= 10'd632) ||
                            (y < 9'd8) || (y >= 9'd472))
                            source_rgb = 24'hffffff;
                        else if (((x >= 10'd296) && (x < 10'd344)) ||
                                 ((y >= 9'd216) && (y < 9'd264)))
                            source_rgb = 24'hffb000;
                        else
                            source_rgb = 24'h101820;
                    end
                endcase
                pixel_rgb = adjust_image(source_rgb, brightness_level,
                                         contrast_level);
            end

            // Divider is inside the picture, below status and above subtitles.
            // Endpoint settings are full processed/full original with no edge stripe.
            if (base_active && compare_active &&
                (compare_edge != 0) && (compare_edge < 640) &&
                (x >= compare_edge) && (x < compare_edge + 10'd2) &&
                (y >= 64) && (y < 448) &&
                (transition_phase == TRANSITION_IDLE))
                pixel_rgb = 24'h40ffff;

            // 28 characters, 5x7 pixels, 2x scale, with a one-pixel gap.
            // The background strip makes the status readable over every test image.
            if ((x >= 10'd8) && (x < 10'd352) &&
                (y >= 9'd8) && (y < 9'd28)) begin
                pixel_rgb = 24'h081018;
                if ((x >= 10'd12) && (x < 10'd348) &&
                    (y >= 9'd10) && (y < 9'd24)) begin
                    osd_char_index = (x - 10'd12) / 10'd12;
                    osd_row_index  = (y - 9'd10) >> 1;
                    osd_col_index  = ((x - 10'd12) % 10'd12) >> 1;
                    osd_char_code  = osd_char(osd_char_index,
                                              base_active ? frame_mode : mode,
                                              base_active ? frame_auto : auto_play,
                                              last_key_code, frame_state,
                                              frame_buffer_sync1);
                    font_query_enable=1;
                    font_query_code=osd_char_code;font_query_row=osd_row_index;
                    font_query_column=osd_col_index;
                    font_query_color=(osd_char_index < 5'd9) ? 24'hffffff : 24'hffe070;
                end
            end

            // Persistent parameter readout.  It is drawn after image
            // adjustment so the values remain readable at every setting.
            if ((x >= 10'd8) && (x < 10'd412) &&
                (y >= 9'd30) && (y < 9'd50)) begin
                pixel_rgb = 24'h081018;
                if ((x >= 10'd12) && (x < 10'd408) &&
                    (y >= 9'd32) && (y < 9'd46)) begin
                    osd_char_index = (x - 10'd12) / 10'd12;
                    osd_row_index  = (y - 9'd32) >> 1;
                    osd_col_index  = ((x - 10'd12) % 10'd12) >> 1;
                    osd_char_code  = parameter_osd_char(osd_char_index,
                                                        brightness_level,
                                                        contrast_level,
                                                        volume_level,
                                                        audio_manual_note_enable,
                                                        audio_manual_note_gate,
                                                        audio_manual_note_index,
                                                        transition_mode,
                                                        auto_interval_seconds);
                    font_query_enable=1;
                    font_query_code=osd_char_code;font_query_row=osd_row_index;
                    font_query_column=osd_col_index;font_query_color=24'h80f0ff;
                end
            end

            // PCM: low-to-high bands, independent held peak caps and a faint
            // 40-pixel reference track. Tone mode keeps its note selection.
            if ((stage_style == 0) && (y >= AUDIO_BAR_Y_TOP) && (y < AUDIO_BAR_Y_BASE)) begin
                if ((x >= AUDIO_BAR_X_START) && (x < AUDIO_BAR_X_END)) begin
                    audio_bar_slot = (x - AUDIO_BAR_X_START) >> 6;
                    audio_bar_column = (x - AUDIO_BAR_X_START) & 6'b111111;
                    audio_bar_y_top = AUDIO_BAR_Y_BASE -
                                      audio_bar_height[audio_bar_slot];
                    audio_peak_y_top = AUDIO_BAR_Y_BASE -
                                       audio_peak_height[audio_bar_slot];
                    if ((audio_bar_column >= 6'd12) &&
                        (audio_bar_column < 6'd52)) begin
                        if ((audio_bar_height[audio_bar_slot] != 0) &&
                            (y >= audio_bar_y_top)) begin
                            audio_bar_blended_rgb = audio_bar_blend(pixel_rgb);
                            pixel_rgb = audio_bar_blended_rgb;
                            if ((!audio_pcm_mode) && (y < audio_bar_y_top + 10'd2))
                                pixel_rgb = 24'hffe860;
                        end else if (audio_pcm_mode &&
                                     (y >= AUDIO_BAR_Y_BASE - 10'd40)) begin
                            pixel_rgb = audio_track_blend(pixel_rgb);
                        end
                        if (audio_pcm_mode &&
                            (audio_peak_height[audio_bar_slot] != 0) &&
                            (y >= audio_peak_y_top) && (y < audio_peak_y_top + 10'd2))
                            pixel_rgb = 24'hffe860;
                    end
                end
            end

            // New stage styles reuse the same eight smoothed heights and peaks.
            // The mirror is generated from coordinates; it stores no extra pixels.
            if ((stage_style != 0) && (x >= 64) && (x < 576) &&
                (((stage_style == 1) && (y >= 350) && (y < 446)) ||
                 ((stage_style == 2) && (y >= 278) && (y < 440)))) begin
                audio_bar_slot = (x - 10'd64) >> 6;
                audio_bar_column = (x - 10'd64) & 6'h3f;
                // Keep the source picture unchanged between bars and segments.
                stage_color = stage_palette(audio_bar_slot);
                stage_peak_distance = audio_pcm_mode ? audio_peak_height[audio_bar_slot] : audio_bar_height[audio_bar_slot];
                if (y < stage_base) begin
                    stage_distance = stage_base - y;
                    if ((audio_bar_column >= 12) && (audio_bar_column < 52)) begin
                        if ((stage_distance <= audio_bar_height[audio_bar_slot]) &&
                            (y[2:0] < 6))
                            pixel_rgb = stage_color;
                        if ((stage_peak_distance != 0) &&
                            (stage_distance <= stage_peak_distance) &&
                            (stage_distance + 10'd2 > stage_peak_distance))
                            pixel_rgb = 24'hfff0a0;
                    end
                end else if (stage_style == 2) begin
                    stage_distance = (y - stage_base) << 1;
                    if ((audio_bar_column >= 12) && (audio_bar_column < 52) &&
                        (stage_distance < audio_bar_height[audio_bar_slot]) &&
                        (y[2:0] < 6))
                        pixel_rgb = (stage_distance < 48) ?
                                    stage_dim(stage_color) : stage_dim(stage_dim(stage_color));
                    if ((y == stage_base) &&
                        (audio_bar_column >= 12) && (audio_bar_column < 52))
                        pixel_rgb = 24'h406078;
                end
            end

            // Full-width bottom subtitle bar. Text is clipped at both edges.
            if (y >= 9'd448) begin
                pixel_rgb = 24'h101820;
                subtitle_rel_x = $signed({1'b0, x}) - subtitle_x;
                subtitle_prefetch_rel_x = subtitle_rel_x + 12'sd1;
                if (subtitle_bitmap_active &&
                    (subtitle_prefetch_rel_x >= 0) &&
                    (subtitle_prefetch_rel_x < subtitle_active_width) &&
                    (y >= 9'd454) && (y < 9'd470)) begin
                    subtitle_bitmap_row_index = y - 9'd454;
                    touch_subtitle_bitmap_address = {
                        subtitle_prefetch_rel_x[8:4],
                        subtitle_bitmap_row_index
                    };
                end
                if ((subtitle_rel_x >= 0) &&
                    (subtitle_rel_x < subtitle_active_width)) begin
                    if (subtitle_bitmap_active &&
                        (y >= 9'd454) && (y < 9'd470)) begin
                        subtitle_char_index = subtitle_rel_x[8:4];
                        subtitle_bitmap_row_index = y - 9'd454;
                        subtitle_bitmap_col_index = subtitle_rel_x[3:0];
                        if (touch_subtitle_bitmap_row[
                                4'd15 - subtitle_bitmap_col_index
                            ])
                            pixel_rgb = subtitle_color_rgb(
                                subtitle_color_active
                            );
                    end else if (!subtitle_bitmap_active &&
                                 (y >= 9'd456) && (y < 9'd470)) begin
                        // This branch is guarded by subtitle_rel_x >= 0.
                        // Bound division to the actual coordinate width instead
                        // of inferring a 32-bit signed divide from an integer.
                        subtitle_char_index = $unsigned(subtitle_rel_x) / 12'd12;
                        subtitle_row_index  = (y - 9'd456) >> 1;
                        subtitle_col_index  = ($unsigned(subtitle_rel_x) % 12'd12) >> 1;
                        if (subtitle_length_active != 0)
                            subtitle_char_code = subtitle_text_active[
                                subtitle_char_index * 8 +: 8
                            ];
                        else
                            subtitle_char_code = subtitle_char(
                                subtitle_message,
                                subtitle_char_index
                            );
                        font_query_enable=1;font_query_subtitle=1;
                        font_query_code=subtitle_char_code;font_query_row=subtitle_row_index;
                        font_query_column=subtitle_col_index;
                        font_query_color=(subtitle_length_active==0)?24'hffe070:subtitle_color_rgb(subtitle_color_active);
                    end
                end
            end
        end
    end
    function [7:0] font_rom_index;
        input [7:0] code;
        begin
            font_rom_index={1'b0,code[6:0]};
            case(code)
                8'h25,8'h2b,8'h2d,8'h30,8'h31,8'h32,8'h33,8'h34,8'h35,8'h36,8'h37,8'h38,8'h39,8'h3a,8'h41,8'h42,8'h43,8'h44,8'h45,8'h46,8'h47,8'h49,8'h4b,8'h4c,8'h4d,8'h4f,8'h50,8'h53,8'h54,8'h55,8'h56,8'h59:font_rom_index[7]=1'b1;
                default:begin end
            endcase
        end
    endfunction
    wire [7:0] selected_font=font_rom_index(font_query_code);
    wire [4:0] font_row_pipeline;
    assign shared_glyph_address={2'b11,selected_font[6:0],font_query_row[2]};
    generate if(SHARED_FONT)begin:shared_glyph
        reg [1:0] glyph_row_select;
        always @(posedge clk)glyph_row_select<=font_query_row[1:0];
        assign font_row_pipeline=shared_glyph_word >> (glyph_row_select*5);
    end else begin:local_glyph
    (* rom_style="block",syn_ramstyle="block_ram" *) reg [4:0] font_pixel_rom[0:1023];
    localparam [5119:0] FONT_PIXEL_INIT=5120'h00000000000000000000000000000000000000000000000000ffd0417c007382f8c4008c5445440052ab5ac400211518c4006b6718c4003192847108f782e83c0084210cd8000842f9b4008421e8f80073a318b8008c631cd800ad6b5ae800738842108c94a98a4a10632421180273884230048c631cda107382f8c5e042108e212673a1f8b8007be319b4217be1083c00f7a31cda107be2f0b8000000000000ffc00000000000000000000000000000000000000000000000ffe082083f2108422a318c62a22a318c775ac631211518c63173a318c631210842109ff78217420f8c654f463e6b6558c62e84210f463e73a318c62e8c6319d7318c631ad771ffe10842108c654c525173a3108421ffc842109f8c631fc63173a31bc22e84210f421fffe10f421ff7a318c63e7be108420ff7a31f463e8c631fc62e0000000000210041062e00000000000001f07c00000000000042084000800000401000038217c62e03a317462e021082083f03a31f420e07821f421f0085f928c2078217043e07d041062e038842118403a39ace2e0001041041210000000000000f8000420800000000084f9080212aefbaa44208210888108884208200000020840000000000000d64135900000000000000000000000000294a2100421084000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
    integer font_init_index;
    initial begin
        for(font_init_index=0;font_init_index<1024;font_init_index=font_init_index+1)
            font_pixel_rom[font_init_index]=FONT_PIXEL_INIT[font_init_index*5+:5];
    end

        reg [4:0] glyph_row;
        always @(posedge clk)glyph_row<=font_pixel_rom[{selected_font[6:0],font_query_row}];
        assign font_row_pipeline=glyph_row;
    end endgenerate
    reg [23:0] base_rgb_pipeline,font_color_pipeline;
    reg [2:0] font_column_pipeline;
    reg font_enable_pipeline;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            base_rgb_pipeline<=0;font_color_pipeline<=0;
            font_column_pipeline<=0;font_enable_pipeline<=0;
        end else begin
            base_rgb_pipeline<=pixel_rgb;font_color_pipeline<=font_query_color;
            font_column_pipeline<=font_query_column;
            font_enable_pipeline<=font_query_enable && !font_query_code[7] &&
                (font_query_subtitle || (selected_font[7] && font_query_row!=7));
        end
    end
    always @(*) begin
        rgb=base_rgb_pipeline;
        if(font_enable_pipeline && font_column_pipeline<5 &&
           font_row_pipeline[4-font_column_pipeline])rgb=font_color_pipeline;
    end
endmodule

// Same 48 kHz analysis as the video candidate; BGM may contain content above 12 kHz.
// The current fixed visualization bands end at 11 kHz; audio itself remains full-band.

module audio_pcm_band_peaks (
    input wire clk, input wire rst,
    input wire sample_valid, input wire [23:0] sample,
    input wire frame_tick, output wire [55:0] heights
);
    localparam [4:0] CLEAR=0,IDLE=1,READ_PRIME=2,READ_CAPTURE=3,
        B_ISSUE=4,B_WAIT=5,Y_ADD=6,Y_ROUND=7,A1_ISSUE=8,A1_WAIT=9,
        S1_STORE=10,A2_ISSUE=11,A2_WAIT=12,S2_STORE=13,ENV_CALC=14,
        ENV_STORE=15,MAP_BIN=16,MAP_SCALE=17,SAVE=18,WRITE_STATE=19,NEXT=20;
    reg [4:0] phase;
    reg [2:0] lane,word_index;
    reg [5:0] clear_address;
    reg signed [27:0] input_sample,filtered_sample,mul_a;
    reg signed [23:0] mul_b;
    reg signed [51:0] product,b_product;
    reg signed [53:0] y_acc,state1_current,state2_current;
    reg [31:0] envelope_current,next_envelope;
    reg [23:0] map_amplitude;
    reg [7:0] map_bin;
    reg map_zero,map_full;
    reg [15:0] map_scaled;
    reg [6:0] pending_height[0:7];
    reg [6:0] frame_height[0:7];
    // Per band: S1 in words0..2, S2 in words3..5, envelope in words6..7.
    // Preserve every arithmetic bit; only serialization/storage changes.
    (* syn_ramstyle="block_ram", ram_style="block" *)
    reg [17:0] state_memory[0:511];
    reg [17:0] memory_q;
    wire [8:0] memory_read_address={3'd0,lane,word_index};
    wire [8:0] memory_write_address=(phase==CLEAR)?{3'd0,clear_address}:memory_read_address;
    reg [17:0] memory_din;
    always @(*) begin
        case(word_index)
        0:memory_din=state1_current[17:0];
        1:memory_din=state1_current[35:18];
        2:memory_din=state1_current[53:36];
        3:memory_din=state2_current[17:0];
        4:memory_din=state2_current[35:18];
        5:memory_din=state2_current[53:36];
        6:memory_din=envelope_current[17:0];
        default:memory_din={4'd0,envelope_current[31:18]};
        endcase
    end
    always @(posedge clk) begin
        memory_q<=state_memory[memory_read_address];
        if(!rst && (phase==CLEAR || phase==WRITE_STATE))
            state_memory[memory_write_address]<=(phase==CLEAR)?18'd0:memory_din;
    end
    wire [27:0] fractional_magnitude=filtered_sample[27]?(~filtered_sample+28'd1):filtered_sample;
    wire [23:0] magnitude=fractional_magnitude[27:4];
    wire signed [32:0] envelope_delta=$signed({1'b0,magnitude,8'd0})-$signed({1'b0,envelope_current});
    wire signed [32:0] envelope_sum=$signed({1'b0,envelope_current})+(envelope_delta>>>10);
    integer reset_lane;
    function signed [23:0] coeff_b0;
        input [2:0] index;
        begin
            case(index)
            0:coeff_b0=24'sd17087; 1:coeff_b0=24'sd34033;
            2:coeff_b0=24'sd67501; 3:coeff_b0=24'sd132725;
            4:coeff_b0=24'sd256274; 5:coeff_b0=24'sd475717;
            6:coeff_b0=24'sd807765; default:coeff_b0=24'sd548968;
            endcase
        end
    endfunction
    function signed [23:0] coeff_a1;
        input [2:0] index;
        begin
            case(index)
            0:coeff_a1=-24'sd8353875; 1:coeff_a1=-24'sd8318314;
            2:coeff_a1=-24'sd8244769; 3:coeff_a1=-24'sd8088386;
            4:coeff_a1=-24'sd7741491; 5:coeff_a1=-24'sd6933234;
            6:coeff_a1=-24'sd4999510; default:coeff_a1=-24'sd2450913;
            endcase
        end
    endfunction
    function signed [23:0] coeff_a2;
        input [2:0] index;
        begin
            case(index)
            0:coeff_a2=24'sd4160130; 1:coeff_a2=24'sd4126238;
            2:coeff_a2=24'sd4059303; 3:coeff_a2=24'sd3928854;
            4:coeff_a2=24'sd3681756; 5:coeff_a2=24'sd3242870;
            6:coeff_a2=24'sd2578774; default:coeff_a2=24'sd3096369;
            endcase
        end
    endfunction
    function [27:0] rounded_sample;
        input signed [53:0] accumulator;
        reg signed [53:0] rounded;
        begin
            rounded = accumulator + 54'sd2097152;
            // A positive excess smaller than one output LSB already has
            // output bits 7ffffff. Testing the five sign-extension bits is
            // therefore exactly equivalent to both original comparisons.
            case(rounded[53:49])
                5'b00000,5'b11111:rounded_sample=rounded[49:22];
                default:rounded_sample=rounded[53]?28'h8000000:28'h7ffffff;
            endcase
        end
    endfunction
    // Sixteen subdivisions per octave; the within-octave approximation is
    // linear. Reference8..8192 in16-bit PCM units spans about60 dB. Fixed
    // mapping, not per-band AGC: lower volume cannot be normalized back up.
    function [7:0] log_bin;
        input [23:0] amplitude;
        begin
            casez(amplitude[20:11])
                10'b1?????????:log_bin={4'd9,amplitude[19:16]};
                10'b01????????:log_bin={4'd8,amplitude[18:15]};
                10'b001???????:log_bin={4'd7,amplitude[17:14]};
                10'b0001??????:log_bin={4'd6,amplitude[16:13]};
                10'b00001?????:log_bin={4'd5,amplitude[15:12]};
                10'b000001????:log_bin={4'd4,amplitude[14:11]};
                10'b0000001???:log_bin={4'd3,amplitude[13:10]};
                10'b00000001??:log_bin={4'd2,amplitude[12:9]};
                10'b000000001?:log_bin={4'd1,amplitude[11:8]};
                default:log_bin={4'd0,amplitude[10:7]};
            endcase
        end
    endfunction

    genvar out_lane;
    generate for(out_lane=0;out_lane<8;out_lane=out_lane+1) begin:outputs
        assign heights[out_lane*7+:7]=frame_height[out_lane];
        always @(posedge clk or posedge rst) begin
            if(rst) frame_height[out_lane]<=0;
            else if(frame_tick) frame_height[out_lane]<=pending_height[out_lane];
        end
    end endgenerate
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            phase<=CLEAR;lane<=0;word_index<=0;clear_address<=0;
            input_sample<=0;filtered_sample<=0;mul_a<=0;mul_b<=0;
            product<=0;b_product<=0;y_acc<=0;state1_current<=0;state2_current<=0;
            envelope_current<=0;next_envelope<=0;map_amplitude<=0;
            map_bin<=0;map_zero<=1;map_full<=0;map_scaled<=0;
            for(reset_lane=0;reset_lane<8;reset_lane=reset_lane+1)
                pending_height[reset_lane]<=0;
        end else case(phase)
        CLEAR:begin
            if(clear_address==63) phase<=IDLE;
            else clear_address<=clear_address+1'b1;
        end
        IDLE:if(sample_valid) begin
            input_sample<=$signed({sample,4'd0});lane<=0;word_index<=0;phase<=READ_PRIME;
        end
        READ_PRIME:phase<=READ_CAPTURE;
        READ_CAPTURE:begin
            case(word_index)
            0:state1_current[17:0]<=memory_q;
            1:state1_current[35:18]<=memory_q;
            2:state1_current[53:36]<=memory_q;
            3:state2_current[17:0]<=memory_q;
            4:state2_current[35:18]<=memory_q;
            5:state2_current[53:36]<=memory_q;
            6:envelope_current[17:0]<=memory_q;
            7:envelope_current[31:18]<=memory_q[13:0];
            endcase
            if(word_index==7) phase<=B_ISSUE;
            else begin word_index<=word_index+1'b1;phase<=READ_PRIME;end
        end
        B_ISSUE:begin mul_a<=input_sample;mul_b<=coeff_b0(lane);phase<=B_WAIT;end
        B_WAIT:begin product<=mul_a*mul_b;phase<=Y_ADD;end
        Y_ADD:begin b_product<=product;y_acc<=state1_current+{{2{product[51]}},product};phase<=Y_ROUND;end
        Y_ROUND:begin filtered_sample<=rounded_sample(y_acc);phase<=A1_ISSUE;end
        A1_ISSUE:begin mul_a<=filtered_sample;mul_b<=coeff_a1(lane);phase<=A1_WAIT;end
        A1_WAIT:begin product<=mul_a*mul_b;phase<=S1_STORE;end
        S1_STORE:begin state1_current<=state2_current-{{2{product[51]}},product};phase<=A2_ISSUE;end
        A2_ISSUE:begin mul_a<=filtered_sample;mul_b<=coeff_a2(lane);phase<=A2_WAIT;end
        A2_WAIT:begin product<=mul_a*mul_b;phase<=S2_STORE;end
        S2_STORE:begin state2_current<=-{{2{b_product[51]}},b_product}-{{2{product[51]}},product};phase<=ENV_CALC;end
        ENV_CALC:begin next_envelope<=envelope_sum[31:0];phase<=ENV_STORE;end
        ENV_STORE:begin envelope_current<=next_envelope;map_amplitude<=next_envelope[31:8];phase<=MAP_BIN;end
        MAP_BIN:begin
            map_bin<=log_bin(map_amplitude);map_zero<=(map_amplitude<=2048);
            map_full<=(map_amplitude>=2097152);phase<=MAP_SCALE;
        end
        MAP_SCALE:begin
            map_scaled<=({8'd0,map_bin}<<7)+({8'd0,map_bin}<<4)+({8'd0,map_bin}<<3)+({8'd0,map_bin}<<1)+16'd128;
            phase<=SAVE;
        end
        SAVE:begin pending_height[lane]<=map_zero?7'd0:(map_full?7'd96:map_scaled[14:8]);word_index<=0;phase<=WRITE_STATE;end
        WRITE_STATE:begin
            if(word_index==7) phase<=NEXT;
            else word_index<=word_index+1'b1;
        end
        NEXT:if(lane==7) phase<=IDLE;
             else begin lane<=lane+1'b1;word_index<=0;phase<=READ_PRIME;end
        default:phase<=CLEAR;
        endcase
    end
endmodule

// Four independent debouncers share only a 1ms timebase. Each transition
// must remain stable for >=100ms; quantization adds at most one ms.
module key_press_debounce_bank #(parameter integer CLK_FREQ_HZ=25_000_000)(
    input wire clk,input wire rst,input wire [3:0] buttons,
    output reg [3:0] press_pulses
);
    localparam integer TICK_CYCLES=CLK_FREQ_HZ/1000;
    localparam integer TICK_BITS=(TICK_CYCLES>1)?$clog2(TICK_CYCLES):1;
    reg [TICK_BITS-1:0] divider;
    wire ms_tick=(divider==TICK_CYCLES-1);
    reg [3:0] sync0,sync1,stable;
    reg [6:0] elapsed_ms[0:3];
    integer i;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            divider<=0;sync0<=4'hf;sync1<=4'hf;stable<=4'hf;press_pulses<=0;
            for(i=0;i<4;i=i+1)elapsed_ms[i]<=0;
        end else begin
            divider<=ms_tick?0:divider+1'b1;
            sync0<=buttons;sync1<=sync0;press_pulses<=0;
            for(i=0;i<4;i=i+1)begin
                if(sync1[i]==stable[i])elapsed_ms[i]<=0;
                else if(ms_tick)begin
                    if(elapsed_ms[i]==100)begin
                        press_pulses[i]<=stable[i] && !sync1[i];
                        stable[i]<=sync1[i];elapsed_ms[i]<=0;
                    end else elapsed_ms[i]<=elapsed_ms[i]+1'b1;
                end
            end
        end
    end
endmodule

// Two independent synchronous read ports; cover tail is masked on its port.
// ASCII rows use the original zero quarter, without reducing alpha precision.
module showcase_shared_font_rom(
    input wire clk,
    input wire [9:0] tile_address,
    input wire [9:0] glyph_address,
    output reg [31:0] tile_word,
    output reg [31:0] glyph_word
);
    (* rom_style="block",syn_ramstyle="block_ram" *)reg [31:0] memory[0:1023];
    localparam [32767:0] SHARED_INIT=32768'h00000000000000000000000000000000000000000000000000000000000000000000000000000000000ffd0400017c000007382f0008c4000008c5440005440000052ab5000ac400000211510008c4000006b6710008c4000003192800047108000f782e00083c0000084210000cd8000000842f0009b4000008421e0008f80000073a310008b8000008c631000cd800000ad6b5000ae800000738840002108c00094a98000a4a10000632420001180200073884000230040008c631000cda100007382f0008c5e000042108000e212600073a1f0008b8000007be310009b4210007be1000083c00000f7a31000cda100007be2f0000b8000000000000000000000ffc00000000000000000000000000000000000000000000000000000000000000000000000000000ffe080002083f0002108400022a310008c62a00022a310008c775000ac631000211510008c63100073a310008c631000210840002109f000f78210007420f0008c654000f463e0006b6550008c62e00084210000f463e00073a310008c62e0008c6310009d7310008c631000ad771000ffe10000842100008c654000c525100073a3100008421000ffc840002109f0008c631000fc63100073a31000bc22e00084210000f421f000ffe10000f421f000f7a310008c63e0007be100008420f000f7a31000f463e0008c631000fc62e0000000000000000000210040001062e00000000000000000000001f00007c00000000000000000000042084000000800000000400001000000038210007c62e00003a310007462e000021080002083f00003a31000f420e00007821000f421f0000085f000928c2000078210007043e00007d040001062e000038840002118400003a39000ace2e0000001000041041000210000000000000000000000f8000000420800000000000000084000f9080000212ae000fbaa40004208200010888000108880004208200000000000020840000000000000000000000d60004135900000000000000000000000000000000000000000000294a00021004000210840000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000bf15000015783838782eb0d0c05703030302020100c0c0d0f03e06000057ff0000808000000000006f00000090d5000000b81e0b0707070b1dd5bf0000b490000079b0b0395e0e0e5e0b1d3838fe0e0e0e5efe0000b0753f2c0156ff0bd0c040001d0a07030e1d2c74b0e00000000000f90b1c283b560040f83d3838281e070707000040005ef400002d34342d5e07075f004040000b09182cf8180a0a0000003474b0e0d002030a0d293f000055ff0000004000002d3834386d0a070b2d0b00006feb0a1d150b000078d000000e2c282c5600000055fe0d0d050f00005dfd00000000000a0a1ebf0a0055ff070000c0400a0a0a0a0d2870d00b0b0000000000fd1e2c2c0e56000050020a0d1df84000000e06000059f800000000003f150000015b0a68e00b1d282c400000011e0600005af80000808080edf48000001e2834345d0b070300004040343434281e0700005df4000000000102000000fe2e382c1f5b000080f42e0b0b191b00006ee400000000001800002f340000fe070e02001d6240000083a000801c240019d0280a02711e28b0e4400000ffc0c000fd0000000000180a00001a7680d2633ad28202028089b8e000001f002d1dff0c0202fa0280a4a89c090701000c4c8c0002020200898080000000180b0000014b0000a86801000102e8b1e45c29fe28286aa824240306090d090a06032f28282ff42424f40f000000a828bf002424fe00000019070000008100001ae5000024f400002f00bb1cff244200fe9070303030001c181f343600ff184060fe30303e00000f00000dff0d0000fc0000907418000000003800000015383838783f000000f838383878f80000157f0000e5ff0000408000001f2f7df801020203b9bfbf0057ffff07d0d0c0c00707075bc000000000000003d0ffffd007ffff071e2f160094ffbf0000eaff560050feadd0d0d0d702030090a4ff6f0000a5ff5b00004006070707a7dbd5d0d0febf060040f9ff3f017ff9f8bfe50000e7070707010b7efef89000aa7e0b02aa019ffffd87d74707ff0b1f1af4d0400003030000000001030000f9ff0b0b0f1fef824040e0f4bc7d005afffe16ffff50b0f4a4001f1a00002f1f0f0b0b408080e500000007070303c0d0d0e02e2e2e6e02020201e1e1f0f00000051f010155fff0f0f5ff000050f8ff24bd2fff00004000000a1f000040f80000067f0000a0f00500000040e0f82e072fbdf0f9900000ffff0307d0d0000007afff0080eaff0000000020b4b5b6b7b8f4e0c0e0faffe02dbdfd2dbd2f0600bbffbfbde0faff0000aaff002dbdfd000000bfbfbcbcffff00000f1f0f0fffff4040ffffb4b4b4b4c0c0c0000f0f0f0040404000b4b4b4000000092f000064fd0000a0f40b010000e0fd6f07000187ff2ffef48000021f7f7ffde04090000000bf3e3c7c01070f2ffdfeee5e0000020364f8f0d078b8b8b87e180000070f0b00b8b8b8001f1f1f1f00003f3f1e00ffff0000f8f8c0ffff0000ffff2e1fffff002e2e2e2e3d3d7cff2f2f00d0fefe2e2e2e2e2e000000010b0000b8b80f1f2e2ef8bc3c3c7ff9e0802d3d19003c3c3d3e3ebcf4f0000000b83f3f3f07e0d0c0c0b8bab8b890f4bd2fb8b8bbff20b4f4e0070b0b0bc08080800a000103bfbef8e00b1f3e3fc04000ff0b0000ff800000ffb8b8b8f83f000002ff00a0f4f87d2800010000000002010080e0f97f000056ff0700aaffd000afff0001ffff0059ffff1f070000fae0bd2faa00004055000001420f7ef8f4c000000a0000ff071f7fffe08040ffe0000000000040f40000a0f800011f3f0050f4f806000000fe2f070000c0e0b800020f3ebff9d0000000002f3d1e0bffbcf4e0ff2f010101fff0f0f0ffc0c0c0ff1e1e1ef40000067c7c7fff0064f4e41e1e1e1e1f1e0000fdbc7c7cffff0001ffff7df4feff0b1f0040d06f7c7c7cff070f1f1fd080ffff7df8f0d02f000000ff7c7c7c0f1f2e007c7c7c00000090f07fbdf8f4ff010000e05000021f7ffcf4d00000070028bdfd070b0f1fd0c24b0b6ffef480fcb8b8b801020202f0f0e0e02e2e3d3d090000003c7c7c7c00000010020203037c7c7cb8000b0b0056fffe00fffff9b8f4f44000d0e5ffffb8b9ffff0055ffffb8b8b8b8b8b80000000002070000e0f407010000f09000000000e0e000007c7c000000091f1f030082d2f4fcf0f001032fbef8e07e2f0f07010181c10b1f3e7cc04000007c7c7c7c0000207402010000e1f1f579e0e1e2e3f8f0e0c07c7e7f7ff8f0d0803d2e2fffe7ebefff804000ff000000f87f7e7db80b000000ff010101ffe0e0e0f8010207f4f0e0d0010100000b060000c080000000092f1b000090f4010b2fbd90f080280001071f60f8e080bd1f07010b4bdbfb424b5fbce08000007e2f07033ef8f4f8ffff0078ffff0b0bffff00f0c7cb0f1fff8b420200d0e0d07f7f78781e2e2d3d0307070bd0c08080787f7f783c3c7c7f0b0f1fff400000f8001f1f0078ffff7800ffff00f0fffff07fc0c000ff2d3d7cf8000000787800007c7800000000f8fe0000020b0000b4b40b0f0f1fef4b020180d0f2ff3ffdf4d7400016ffb4b4fffe005aff9500e0f0002e1a0000bf7ebdfe47000007a50000fff4b4b4ff030b0f2eefcf4f0b07004040ffb4b400ff0f2eb83db8f4600b070707878bc0c0ffff070bffffc08000002f2f0f0bffff4000ffff0000f4f4000002000090f8be03020202d0d0d2d23c3cffff1f020000c2420200d0e0e0003c3c3c00000000c000000001000000e00000000b000060f8c0c0ffff0102ffff1f2f2e3dff40000082070b0ff4e0c0402f3e3d7c3d3d3d3db8b8f4f43c3c7c7c07070707c0c0c0c07c7c7c7d01010156f0f0f0f507070700d5ffff0056ffff007f7f0000ffff0101f0f0000001010100e0e0e0000000001f000101f900f0f0f01f000000ff030303ffd0d0d0f901010101010101f0f0f0f0000060f40303ffff0101c1c1f3fbfffef0d04000030303030102070bfcf4e0c003030300d0d0d0001f3e7df8051f1f0055ffff0bf5ffffc040e0e0000f1f1b0080400000ffff2f2fffffe0e00001010055ffff006fffff2fe0e0e0e02f2f2f2f02020000e0e00000000001072f2f6fff000055ffd00000000000000700000006000000800000053f000050f01f060000f4ff2f020040e0fe00072ffe6ffee000e0400000bff8f4f4f0000000000000027f2fbff4e0d0f4f8f4f4f4f4070f2f3d7d1f0f07000040c0f4f4faff0024f8f4000001010302ffffd0e0fefe1b7f3400fef4f4f40f0f0f1f404040400000007f000000f4ffff0f0fffff40407f000000f40000000f0f00004040000000000b0b000002020000d0d0d0d0d0d00b0b0b5b808080ef000015ff0000afff02020202d0d0d0d220b4f4f01f1f0000ffef0b0bff948080fa00006095020b020242c2f2d7dbeffdd0800000f87e0f020000c0f0bf2a0202fcf8f0e08080828b000040d097070000ffff0202f4f4000082808080f87f0a000040010b02026bffd0d0ffff0000f0f00b0b0b008080800007000000ea000000550000000000f4ff000007ff0000808000000016000000b0fff4f4f4ff070707808787805affef0bffff4747f4d08080f4f4f4ff000000ff000a1f1bff00e0fdff00062f8066fee00bffff0b47474747bf0b010081fbffbffee040400b0b0b0b4740404780000080020b1f3efbd24000d0e0b47e22baf6d2ffffd0d0ffff070700010202bcf4ffff0000ffff2f1ffefdc2420202d0d0d0ff070707ff8080808000010000b8f4a00002000000ff00000080000000000064fe000000400000001b00005bff000080c0bf070000e4fe6f060040f6ff022ffff4fff99000fa400000400000000001070fbffee080f8ff1b010090f9bf000000d0000000052f7dbcf90f1f3ebdc0400055000000502f2f0000ffff070fffffd080f8f800000007070700d0d0d52f7d2855000000550007075700c0c0c007070000ffff0b1fffff40c0ffff0000c0c0000007020000e0f4900000000000;

    integer i;
    initial for(i=0;i<1024;i=i+1)memory[i]=SHARED_INIT[i*32+:32];
    always @(posedge clk)tile_word<=memory[tile_address];
    always @(posedge clk)glyph_word<=memory[glyph_address];
endmodule
