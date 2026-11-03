`timescale 1ns/1ps

// Development-only image source. It writes generated frames through the same
// SDRAM/FIFO interface used by the TF reader, so the downstream path is shared.
module rom_frame_source #(
    parameter integer CLK_FREQ_HZ  = 100_000_000,
    parameter integer FRAME_WIDTH  = 640,
    parameter integer FRAME_HEIGHT = 480,
    parameter integer FRAME_PIXELS = 307_200
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        mem_init_done,
    input  wire        key_next,
    input  wire        key_auto,
    input  wire        key_next_toggle,
    input  wire        key_auto_toggle,
    input  wire        write_finish_toggle,
    output reg  [3:0] state_code,
    output reg         display_valid,
    output reg  [1:0]  write_buf_idx,
    output reg  [1:0]  disp_buf_idx,
    output wire [3:0]  image_index_dbg,
    output wire        auto_play_dbg,
    output wire        write_req,
    input  wire        write_req_ack,
    input  wire        write_fifo_full,
    output wire        write_en,
    output wire [31:0] write_data
);

    localparam [2:0] S_WAIT_MEM    = 3'd0;
    localparam [2:0] S_REQUEST     = 3'd1;
    localparam [2:0] S_STREAM      = 3'd2;
    localparam [2:0] S_WAIT_FINISH = 3'd3;
    localparam [2:0] S_DISPLAY     = 3'd4;
    localparam [2:0] S_FIFO_SETTLE = 3'd5;

    // Leave ample headroom for SDRAM burst and refresh pauses. The write FIFO
    // has no backpressure output, so the development source must be slower
    // than the worst-case memory service rate to avoid dropping pixels.
    reg [3:0] stream_div;
    reg [5:0] fifo_settle_count;
    reg [18:0] pixel_count;
    reg [9:0]  pixel_x;
    reg [8:0]  pixel_y;
    reg [1:0]  image_index;
    reg [2:0]  state;
    reg        auto_play;
    reg [31:0] auto_count;
    reg [26:0] finish_timeout_count;
    reg        mem_init_sync0;
    reg        mem_init_sync1;
    reg        finish_sync0;
    reg        finish_sync1;
    reg        finish_seen;
    reg        key_next_toggle_sync0;
    reg        key_next_toggle_sync1;
    reg        key_next_toggle_seen;
    reg        key_auto_toggle_sync0;
    reg        key_auto_toggle_sync1;
    reg        key_auto_toggle_seen;

    wire key_next_press;
    wire key_auto_press;
    wire touch_next_event;
    wire touch_auto_event;
    wire next_command_pulse;
    wire auto_command_pulse;
    wire finish_pulse;
    wire auto_tick;
    wire stream_write;
    wire [23:0] pixel_rgb;

    assign write_req   = (state == S_REQUEST);
    assign stream_write = (state == S_STREAM) && (stream_div == 4'd0) &&
                          !write_fifo_full;
    assign write_en    = stream_write;
    assign write_data  = {pixel_rgb, 8'h00};
    assign finish_pulse = finish_sync1 ^ finish_seen;
    assign touch_next_event = key_next_toggle_sync1 ^ key_next_toggle_seen;
    assign touch_auto_event = key_auto_toggle_sync1 ^ key_auto_toggle_seen;
    assign next_command_pulse = key_next_press | touch_next_event;
    assign auto_command_pulse = key_auto_press | touch_auto_event;
    assign auto_tick    = (auto_count >= (CLK_FREQ_HZ * 2 - 1));
    assign image_index_dbg = {2'b00, image_index};
    assign auto_play_dbg   = auto_play;

    key_press_debounce #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .DEBOUNCE_MS (1000)
    ) u_key_next (
        .clk         (clk),
        .rst         (rst),
        .button_in   (key_next),
        .press_pulse (key_next_press)
    );

    key_press_debounce #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .DEBOUNCE_MS (1000)
    ) u_key_auto (
        .clk         (clk),
        .rst         (rst),
        .button_in   (key_auto),
        .press_pulse (key_auto_press)
    );

    function [23:0] test_pixel;
        input [9:0] px;
        input [8:0] py;
        input [1:0] mode;
        reg [2:0] tile;
        reg [2:0] band;
        reg [7:0] grad_r;
        reg [7:0] grad_g;
        reg [7:0] grad_b;
        begin
            tile  = {px[8:6], py[8:6]};
            band  = px[9:7];
            grad_r = px[9:2];
            grad_g = py[8:1];
            grad_b = px[8:1] ^ py[8:1];
            case (mode)
                2'd0: begin
                    case (band)
                        3'd0: test_pixel = 24'hffffff;
                        3'd1: test_pixel = 24'hffff00;
                        3'd2: test_pixel = 24'h00ffff;
                        3'd3: test_pixel = 24'h00ff00;
                        3'd4: test_pixel = 24'hff00ff;
                        3'd5: test_pixel = 24'hff0000;
                        3'd6: test_pixel = 24'h0000ff;
                        default: test_pixel = 24'h000000;
                    endcase
                end
                2'd1: begin
                    case (tile[2:1])
                        2'd0: test_pixel = 24'h163d70;
                        2'd1: test_pixel = 24'h25b7d3;
                        2'd2: test_pixel = 24'he5c84b;
                        default: test_pixel = 24'hd33f49;
                    endcase
                    if (tile[0])
                        test_pixel = test_pixel ^ 24'h202020;
                end
                2'd2: test_pixel = {grad_r, grad_g, grad_b};
                default: begin
                    if ((px < 10'd8) || (px >= FRAME_WIDTH - 8) ||
                        (py < 9'd8) || (py >= FRAME_HEIGHT - 8))
                        test_pixel = 24'hffffff;
                    else if ((px >= 10'd296) && (px < 10'd344) ||
                             (py >= 9'd216) && (py < 9'd264))
                        test_pixel = 24'hffb000;
                    else
                        test_pixel = 24'h101820;
                end
            endcase
        end
    endfunction

    assign pixel_rgb = test_pixel(pixel_x, pixel_y, image_index);

    always @(*) begin
        case (state)
            S_WAIT_MEM:    state_code = 4'd1;
            S_REQUEST:     state_code = 4'd2;
            S_FIFO_SETTLE: state_code = 4'd2;
            S_STREAM:      state_code = 4'd3;
            S_WAIT_FINISH: state_code = 4'd4;
            S_DISPLAY:     state_code = auto_play ? 4'd6 : 4'd5;
            default:       state_code = 4'd0;
        endcase
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state            <= S_WAIT_MEM;
            display_valid    <= 1'b0;
            write_buf_idx    <= 2'd0;
            disp_buf_idx     <= 2'd0;
            stream_div       <= 4'd0;
            fifo_settle_count <= 6'd0;
            pixel_count      <= 19'd0;
            pixel_x          <= 10'd0;
            pixel_y          <= 9'd0;
            // Start with a pattern distinct from the HDMI diagnostic bars so
            // SDRAM frame completion is visible without relying on a key.
            // Use the framed/cross pattern so SDRAM readback is visually
            // distinct from the direct fallback pattern during bring-up.
            image_index      <= 2'd3;
            auto_play        <= 1'b0;
            auto_count       <= 32'd0;
            finish_timeout_count <= 27'd0;
            mem_init_sync0   <= 1'b0;
            mem_init_sync1   <= 1'b0;
            finish_sync0     <= 1'b0;
            finish_sync1     <= 1'b0;
            finish_seen      <= 1'b0;
            key_next_toggle_sync0 <= 1'b0;
            key_next_toggle_sync1 <= 1'b0;
            key_next_toggle_seen  <= 1'b0;
            key_auto_toggle_sync0 <= 1'b0;
            key_auto_toggle_sync1 <= 1'b0;
            key_auto_toggle_seen  <= 1'b0;
        end else begin
            mem_init_sync0 <= mem_init_done;
            mem_init_sync1 <= mem_init_sync0;
            finish_sync0   <= write_finish_toggle;
            finish_sync1   <= finish_sync0;
            key_next_toggle_sync0 <= key_next_toggle;
            key_next_toggle_sync1 <= key_next_toggle_sync0;
            key_next_toggle_seen  <= key_next_toggle_sync1;
            key_auto_toggle_sync0 <= key_auto_toggle;
            key_auto_toggle_sync1 <= key_auto_toggle_sync0;
            key_auto_toggle_seen  <= key_auto_toggle_sync1;

            if (state != S_WAIT_FINISH)
                finish_timeout_count <= 27'd0;

            if (auto_command_pulse)
                auto_play <= ~auto_play;

            if (state == S_WAIT_MEM) begin
                if (mem_init_sync1)
                    state <= S_REQUEST;
            end else if (state == S_REQUEST) begin
                if (write_req_ack) begin
                    // frame_fifo_write keeps its async FIFO reset asserted
                    // until the synchronized request drops. Wait here so the
                    // first generated pixel cannot be discarded by that reset.
                    state       <= S_FIFO_SETTLE;
                    stream_div  <= 4'd0;
                    fifo_settle_count <= 6'd0;
                    pixel_count <= 19'd0;
                    pixel_x     <= 10'd0;
                    pixel_y     <= 9'd0;
                end
            end else if (state == S_FIFO_SETTLE) begin
                if (fifo_settle_count == 6'd63) begin
                    state <= S_STREAM;
                    stream_div <= 4'd0;
                end else begin
                    fifo_settle_count <= fifo_settle_count + 1'b1;
                end
            end else if (state == S_STREAM) begin
                stream_div <= stream_div + 1'b1;
                if (stream_write) begin
                    if (pixel_count == FRAME_PIXELS - 1) begin
                        state       <= S_WAIT_FINISH;
                        pixel_count <= 19'd0;
                        pixel_x     <= 10'd0;
                        pixel_y     <= 9'd0;
                    end else begin
                        pixel_count <= pixel_count + 1'b1;
                        if (pixel_x == FRAME_WIDTH - 1) begin
                            pixel_x <= 10'd0;
                            pixel_y <= pixel_y + 1'b1;
                        end else begin
                            pixel_x <= pixel_x + 1'b1;
                        end
                    end
                end
            end else if (state == S_WAIT_FINISH) begin
                if (finish_pulse) begin
                    finish_seen   <= finish_sync1;
                    disp_buf_idx  <= write_buf_idx;
                    display_valid <= 1'b1;
                    state         <= S_DISPLAY;
                    auto_count    <= 32'd0;
                    finish_timeout_count <= 27'd0;
                end else if (finish_timeout_count >= CLK_FREQ_HZ - 1) begin
                    // A new request resets the writer/FIFO and retries the same
                    // frame instead of leaving the UI permanently in S:4.
                    state <= S_REQUEST;
                    finish_timeout_count <= 27'd0;
                end else begin
                    finish_timeout_count <= finish_timeout_count + 1'b1;
                end
            end else if (state == S_DISPLAY) begin
                finish_seen <= finish_sync1;
                if (auto_play) begin
                    if (auto_tick)
                        auto_count <= 32'd0;
                    else
                        auto_count <= auto_count + 1'b1;
                end else begin
                    auto_count <= 32'd0;
                end

                if (next_command_pulse || (auto_play && auto_tick)) begin
                    image_index   <= (image_index == 2'd3) ? 2'd0 : image_index + 1'b1;
                    write_buf_idx  <= (disp_buf_idx == 2'd0) ? 2'd1 : 2'd0;
                    state          <= S_REQUEST;
                end
            end
        end
    end

endmodule
