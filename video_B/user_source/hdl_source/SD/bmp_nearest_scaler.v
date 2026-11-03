module bmp_nearest_scaler #(
    parameter integer OUT_WIDTH     = 640,
    parameter integer OUT_HEIGHT    = 480,
    parameter integer MAX_SRC_WIDTH = 1280,
    parameter integer STRETCH_TO_FILL = 1
)(
    input                       clk,
    input                       rst,
    input                       cancel,

    input                       image_meta_valid,
    input      [15:0]           image_width,
    input      [15:0]           image_height,
    output reg                  layout_ready,

    input                       scale_start,
    output reg                  source_ready,
    input                       source_pixel_valid,
    input      [23:0]           source_pixel,
    input      [15:0]           source_pixel_x,
    input                       source_row_end,

    input                       write_fifo_full,
    output reg                  write_en,
    output reg [31:0]           write_data,
    output reg                  frame_done
);

localparam OS_IDLE       = 3'd0;
localparam OS_PAD_BEFORE = 3'd1;
localparam OS_WAIT_ROW   = 3'd2;
localparam OS_ROW        = 3'd3;
localparam OS_PAD_AFTER  = 3'd4;

reg [2:0] output_state;

reg [15:0] source_width;
reg [15:0] source_height;
reg [15:0] target_width;
reg [15:0] target_height;
reg [15:0] left_padding;
reg [15:0] pad_before_rows;
reg [15:0] pad_after_rows;

reg        layout_busy;
reg        width_limited;
reg [31:0] divide_remainder;
reg [15:0] divide_divisor;
reg [15:0] divide_quotient;

reg [15:0] output_column;
reg [15:0] padding_rows_left;

reg        write_bank;
reg        pending_valid;
reg        pending_bank;
reg [2:0]  pending_repeats;
reg        active_bank;
reg [2:0]  active_repeats;
reg [15:0] source_rows_seen;
reg        all_source_rows_seen;
reg [16:0] vertical_accumulator;

// Vertical scaling is deliberately iterative. A source row is hundreds of
// clocks long, so spending up to four clocks here removes the former
// add-plus-three-subtract combinational chain without reducing throughput.
reg        vertical_calc_active;
reg [17:0] vertical_work;
reg [2:0]  vertical_repeat_work;
reg        vertical_bank_pending;

reg [15:0] horizontal_issued;
reg [15:0] horizontal_source_x;
reg [16:0] horizontal_accumulator;
reg [16:0] next_horizontal_accumulator;
reg [15:0] next_horizontal_source_x;
reg [17:0] horizontal_sum_work;

reg        read_pixel_valid;
reg [23:0] read_pixel_data;

// One 4096x24 dual-port block RAM holds two 2048-address banks. Keeping the
// bank in the address, instead of muxing two arrays, matches TD's documented
// BRAM inference template and avoids implementing the rows in LUT RAM.
(* ram_style = "bram" *) reg [23:0] line_buffer [0:4095];

wire [31:0] width_cross_product;
wire [31:0] height_cross_product;
wire [16:0] image_end_column;
wire        in_image_region;
wire        consume_read_pixel;
wire        issue_read_pixel;
wire [11:0] line_write_address;
wire [11:0] line_read_address;

assign width_cross_product  = image_width * OUT_HEIGHT;
assign height_cross_product = image_height * OUT_WIDTH;
assign image_end_column     = {1'b0, left_padding} + {1'b0, target_width};
assign in_image_region      = (output_column >= left_padding) &&
                              ({1'b0, output_column} < image_end_column);
assign consume_read_pixel   = (output_state == OS_ROW) && in_image_region &&
                              read_pixel_valid && !write_fifo_full;
assign issue_read_pixel     = (output_state == OS_ROW) && in_image_region &&
                              (horizontal_issued < target_width) &&
                              (!read_pixel_valid || consume_read_pixel);
assign line_write_address   = {write_bank, source_pixel_x[10:0]};
assign line_read_address    = {active_bank, horizontal_source_x[10:0]};

// The quotient is at most 640. Repeated subtraction avoids synthesizing a
// large variable divider in the timing-sensitive image path.
always @(posedge clk or posedge rst) begin
    if (rst) begin
        source_width     <= 16'd0;
        source_height    <= 16'd0;
        target_width     <= 16'd0;
        target_height    <= 16'd0;
        left_padding     <= 16'd0;
        pad_before_rows  <= 16'd0;
        pad_after_rows   <= 16'd0;
        layout_busy      <= 1'b0;
        layout_ready     <= 1'b0;
        width_limited    <= 1'b0;
        divide_remainder <= 32'd0;
        divide_divisor   <= 16'd1;
        divide_quotient  <= 16'd0;
    end else if (cancel) begin
        layout_busy  <= 1'b0;
        layout_ready <= 1'b0;
    end else if (image_meta_valid) begin
        source_width    <= image_width;
        source_height   <= image_height;
        divide_quotient <= 16'd0;

        if (STRETCH_TO_FILL != 0) begin
            // Stretch mode maps the source axes independently to the complete
            // HDMI canvas. No letterbox/pillarbox padding is emitted.
            target_width     <= OUT_WIDTH;
            target_height    <= OUT_HEIGHT;
            left_padding     <= 16'd0;
            pad_before_rows  <= 16'd0;
            pad_after_rows   <= 16'd0;
            layout_busy      <= 1'b0;
            layout_ready     <= 1'b1;
            width_limited    <= 1'b0;
            divide_remainder <= 32'd0;
            divide_divisor   <= 16'd1;
        end else begin
            layout_ready <= 1'b0;
            layout_busy  <= 1'b1;

            if (width_cross_product > height_cross_product) begin
                width_limited    <= 1'b1;
                target_width     <= OUT_WIDTH;
                divide_remainder <= image_height * OUT_WIDTH;
                divide_divisor   <= image_width;
            end else begin
                width_limited    <= 1'b0;
                target_height    <= OUT_HEIGHT;
                divide_remainder <= image_width * OUT_HEIGHT;
                divide_divisor   <= image_height;
            end
        end
    end else if (layout_busy) begin
        if (divide_remainder >= divide_divisor) begin
            divide_remainder <= divide_remainder - divide_divisor;
            divide_quotient  <= divide_quotient + 16'd1;
        end else begin
            layout_busy  <= 1'b0;
            layout_ready <= 1'b1;

            if (width_limited) begin
                target_height   <= (divide_quotient == 16'd0) ? 16'd1 : divide_quotient;
                left_padding    <= 16'd0;
                pad_before_rows <= (OUT_HEIGHT - ((divide_quotient == 16'd0) ? 16'd1 : divide_quotient)) >> 1;
                pad_after_rows  <= (OUT_HEIGHT - ((divide_quotient == 16'd0) ? 16'd1 : divide_quotient)) -
                                   ((OUT_HEIGHT - ((divide_quotient == 16'd0) ? 16'd1 : divide_quotient)) >> 1);
            end else begin
                target_width    <= (divide_quotient == 16'd0) ? 16'd1 : divide_quotient;
                left_padding    <= (OUT_WIDTH - ((divide_quotient == 16'd0) ? 16'd1 : divide_quotient)) >> 1;
                pad_before_rows <= 16'd0;
                pad_after_rows  <= 16'd0;
            end
        end
    end
end

// Horizontal nearest-neighbour phase accumulator. The supported source range
// is no more than 2x the fitted width, so at most two subtractions are needed.
always @(*) begin
    horizontal_sum_work = horizontal_accumulator + source_width;
    next_horizontal_source_x = horizontal_source_x;

    if (horizontal_sum_work >= target_width) begin
        horizontal_sum_work = horizontal_sum_work - target_width;
        next_horizontal_source_x = next_horizontal_source_x + 16'd1;
        if (horizontal_sum_work >= target_width) begin
            horizontal_sum_work = horizontal_sum_work - target_width;
            next_horizontal_source_x = next_horizontal_source_x + 16'd1;
        end
    end

    next_horizontal_accumulator = horizontal_sum_work[16:0];
end

// True dual-port style line buffer: SD input writes one bank while the scaler
// reads the previously completed row from the other bank.
always @(posedge clk) begin
    if (source_pixel_valid && source_ready && (source_pixel_x < MAX_SRC_WIDTH))
        line_buffer[line_write_address] <= source_pixel;
end

always @(posedge clk) begin
    if (issue_read_pixel)
        read_pixel_data <= line_buffer[line_read_address];
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        output_state               <= OS_IDLE;
        source_ready               <= 1'b0;
        write_en                   <= 1'b0;
        write_data                 <= 32'd0;
        frame_done                 <= 1'b0;
        output_column              <= 16'd0;
        padding_rows_left          <= 16'd0;
        write_bank                 <= 1'b0;
        pending_valid              <= 1'b0;
        pending_bank               <= 1'b0;
        pending_repeats            <= 3'd0;
        active_bank                <= 1'b0;
        active_repeats             <= 3'd0;
        source_rows_seen           <= 16'd0;
        all_source_rows_seen       <= 1'b0;
        vertical_accumulator       <= 17'd0;
        vertical_calc_active       <= 1'b0;
        vertical_work              <= 18'd0;
        vertical_repeat_work       <= 3'd0;
        vertical_bank_pending      <= 1'b0;
        horizontal_issued          <= 16'd0;
        horizontal_source_x        <= 16'd0;
        horizontal_accumulator     <= 17'd0;
        read_pixel_valid           <= 1'b0;
    end else if (cancel) begin
        output_state               <= OS_IDLE;
        source_ready               <= 1'b0;
        write_en                   <= 1'b0;
        frame_done                 <= 1'b0;
        pending_valid              <= 1'b0;
        all_source_rows_seen       <= 1'b0;
        vertical_calc_active       <= 1'b0;
        read_pixel_valid           <= 1'b0;
    end else begin
        write_en   <= 1'b0;
        frame_done <= 1'b0;

        if (scale_start) begin
            output_column        <= 16'd0;
            padding_rows_left   <= pad_before_rows;
            write_bank          <= 1'b0;
            pending_valid       <= 1'b0;
            active_repeats      <= 3'd0;
            source_rows_seen    <= 16'd0;
            all_source_rows_seen <= 1'b0;
            vertical_accumulator <= 17'd0;
            vertical_calc_active <= 1'b0;
            vertical_work        <= 18'd0;
            vertical_repeat_work <= 3'd0;
            horizontal_issued    <= 16'd0;
            horizontal_source_x  <= 16'd0;
            horizontal_accumulator <= 17'd0;
            read_pixel_valid     <= 1'b0;

            if (pad_before_rows == 16'd0) begin
                output_state <= OS_WAIT_ROW;
                source_ready <= 1'b1;
            end else begin
                output_state <= OS_PAD_BEFORE;
                source_ready <= 1'b0;
            end
        end else begin
            case (output_state)
                OS_IDLE: begin
                    source_ready     <= 1'b0;
                    read_pixel_valid <= 1'b0;
                end

                OS_PAD_BEFORE: begin
                    if (!write_fifo_full) begin
                        write_en   <= 1'b1;
                        write_data <= 32'd0;
                        if (output_column == OUT_WIDTH - 1) begin
                            output_column <= 16'd0;
                            if (padding_rows_left == 16'd1) begin
                                padding_rows_left <= 16'd0;
                                output_state      <= OS_WAIT_ROW;
                                source_ready      <= 1'b1;
                            end else begin
                                padding_rows_left <= padding_rows_left - 16'd1;
                            end
                        end else begin
                            output_column <= output_column + 16'd1;
                        end
                    end
                end

                OS_WAIT_ROW: begin
                    read_pixel_valid <= 1'b0;
                    if (pending_valid) begin
                        active_bank            <= pending_bank;
                        active_repeats         <= pending_repeats;
                        pending_valid          <= 1'b0;
                        output_column          <= 16'd0;
                        horizontal_issued      <= 16'd0;
                        horizontal_source_x    <= 16'd0;
                        horizontal_accumulator <= 17'd0;
                        output_state           <= OS_ROW;
                    end else if (all_source_rows_seen &&
                                 !vertical_calc_active) begin
                        source_ready <= 1'b0;
                        output_column <= 16'd0;
                        padding_rows_left <= pad_after_rows;
                        if (pad_after_rows == 16'd0) begin
                            frame_done   <= 1'b1;
                            output_state <= OS_IDLE;
                        end else begin
                            output_state <= OS_PAD_AFTER;
                        end
                    end
                end

                OS_ROW: begin
                    if (in_image_region) begin
                        if (consume_read_pixel) begin
                            write_en   <= 1'b1;
                            write_data <= {read_pixel_data[23:16], read_pixel_data[15:8],
                                           read_pixel_data[7:0], 8'd0};

                            if (output_column == OUT_WIDTH - 1) begin
                                read_pixel_valid <= 1'b0;
                                if (active_repeats > 3'd1) begin
                                    active_repeats         <= active_repeats - 3'd1;
                                    output_column          <= 16'd0;
                                    horizontal_issued      <= 16'd0;
                                    horizontal_source_x    <= 16'd0;
                                    horizontal_accumulator <= 17'd0;
                                end else if (pending_valid) begin
                                    active_bank            <= pending_bank;
                                    active_repeats         <= pending_repeats;
                                    pending_valid          <= 1'b0;
                                    output_column          <= 16'd0;
                                    horizontal_issued      <= 16'd0;
                                    horizontal_source_x    <= 16'd0;
                                    horizontal_accumulator <= 17'd0;
                                end else if (all_source_rows_seen &&
                                             !vertical_calc_active) begin
                                    source_ready      <= 1'b0;
                                    output_column     <= 16'd0;
                                    padding_rows_left <= pad_after_rows;
                                    if (pad_after_rows == 16'd0) begin
                                        frame_done   <= 1'b1;
                                        output_state <= OS_IDLE;
                                    end else begin
                                        output_state <= OS_PAD_AFTER;
                                    end
                                end else begin
                                    output_column <= 16'd0;
                                    output_state  <= OS_WAIT_ROW;
                                end
                            end else begin
                                output_column <= output_column + 16'd1;
                            end
                        end
                    end else if (!write_fifo_full) begin
                        write_en   <= 1'b1;
                        write_data <= 32'd0;
                        if (output_column == OUT_WIDTH - 1) begin
                            read_pixel_valid <= 1'b0;
                            if (active_repeats > 3'd1) begin
                                active_repeats         <= active_repeats - 3'd1;
                                output_column          <= 16'd0;
                                horizontal_issued      <= 16'd0;
                                horizontal_source_x    <= 16'd0;
                                horizontal_accumulator <= 17'd0;
                            end else if (pending_valid) begin
                                active_bank            <= pending_bank;
                                active_repeats         <= pending_repeats;
                                pending_valid          <= 1'b0;
                                output_column          <= 16'd0;
                                horizontal_issued      <= 16'd0;
                                horizontal_source_x    <= 16'd0;
                                horizontal_accumulator <= 17'd0;
                            end else if (all_source_rows_seen &&
                                         !vertical_calc_active) begin
                                source_ready      <= 1'b0;
                                output_column     <= 16'd0;
                                padding_rows_left <= pad_after_rows;
                                if (pad_after_rows == 16'd0) begin
                                    frame_done   <= 1'b1;
                                    output_state <= OS_IDLE;
                                end else begin
                                    output_state <= OS_PAD_AFTER;
                                end
                            end else begin
                                output_column <= 16'd0;
                                output_state  <= OS_WAIT_ROW;
                            end
                        end else begin
                            output_column <= output_column + 16'd1;
                        end
                    end

                    if (issue_read_pixel) begin
                        horizontal_issued      <= horizontal_issued + 16'd1;
                        horizontal_source_x    <= next_horizontal_source_x;
                        horizontal_accumulator <= next_horizontal_accumulator;
                        read_pixel_valid       <= 1'b1;
                    end else if (consume_read_pixel) begin
                        read_pixel_valid <= 1'b0;
                    end
                end

                OS_PAD_AFTER: begin
                    if (!write_fifo_full) begin
                        write_en   <= 1'b1;
                        write_data <= 32'd0;
                        if (output_column == OUT_WIDTH - 1) begin
                            output_column <= 16'd0;
                            if (padding_rows_left == 16'd1) begin
                                padding_rows_left <= 16'd0;
                                frame_done        <= 1'b1;
                                output_state      <= OS_IDLE;
                            end else begin
                                padding_rows_left <= padding_rows_left - 16'd1;
                            end
                        end else begin
                            output_column <= output_column + 16'd1;
                        end
                    end
                end

                default: begin
                    output_state     <= OS_IDLE;
                    source_ready     <= 1'b0;
                    pending_valid    <= 1'b0;
                    read_pixel_valid <= 1'b0;
                end
            endcase

            // Capture the completed source-row descriptor after the output
            // controller runs. If one descriptor is consumed in this cycle,
            // the new descriptor remains queued rather than being lost.
            if (source_pixel_valid && source_ready && source_row_end) begin
                vertical_work        <= {1'b0, vertical_accumulator} +
                                        {2'b00, target_height};
                vertical_repeat_work <= 3'd0;
                vertical_calc_active <= 1'b1;
                vertical_bank_pending <= write_bank;
                source_rows_seen     <= source_rows_seen + 16'd1;
                write_bank           <= ~write_bank;

                if (source_rows_seen == source_height - 16'd1) begin
                    all_source_rows_seen <= 1'b1;
                    source_ready         <= 1'b0;
                end
            end

            // One subtract per cycle replaces the previous three-deep
            // arithmetic chain. The accepted image range needs at most three
            // repeats, and the next source row cannot finish before this
            // calculation has committed its descriptor.
            if (vertical_calc_active) begin
                if ((vertical_work >= {2'b00, source_height}) &&
                    (vertical_repeat_work < 3'd3)) begin
                    vertical_work <= vertical_work -
                                     {2'b00, source_height};
                    vertical_repeat_work <= vertical_repeat_work + 1'b1;
                end else begin
                    vertical_calc_active <= 1'b0;
                    vertical_accumulator <= vertical_work[16:0];
                    if (vertical_repeat_work != 3'd0) begin
                        pending_valid   <= 1'b1;
                        pending_bank    <= vertical_bank_pending;
                        pending_repeats <= vertical_repeat_work;
                    end
                end
            end
        end
    end
end

endmodule
