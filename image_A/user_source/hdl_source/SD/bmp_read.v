module bmp_read(
    input                       clk,
    input                       rst,
    output                      ready,

    // 上电扫描：从 scan_start_sector 开始，顺序寻找前 scan_target_count 张 BMP
    input                       scan_start,
    input  [31:0]               scan_start_sector,
    input  [31:0]               scan_max_sector,
    input  [2:0]                scan_target_count,
    output reg                  scan_done,
    output reg                  scan_found_valid,
    output reg [31:0]           scan_found_sector,
    output reg [2:0]            scan_found_total,

    // 按指定扇区加载一张图到 SDRAM
    input                       load_start,
    input                       load_abort,
    input  [31:0]               load_sector,

    input                       sd_init_done,
    output reg [3:0]            state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,

    output reg                  image_meta_valid,
    output reg [15:0]           image_width,
    output reg [15:0]           image_height,
    input                       scale_layout_ready,
    input                       scale_input_ready,
    output reg                  scale_start,

    output reg                  write_req,
    input                       write_req_ack,

    output reg                  sd_sec_read,
    output reg [31:0]           sd_sec_read_addr,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,

    output reg                  bmp_data_wr_en,
    output reg [23:0]           bmp_data,
    output reg [15:0]           bmp_pixel_x,
    output reg                  bmp_row_end
);

localparam ST_IDLE        = 3'd0;
localparam ST_SCAN        = 3'd1;
localparam ST_LOAD_HDR    = 3'd2;
localparam ST_LOAD_WAIT   = 3'd3;
// Match the verified ROM source: let the asynchronous write FIFO reset
// deassert and settle after write_req_ack before accepting the first pixel.
localparam ST_LOAD_SETTLE = 3'd4;
localparam ST_LOAD_DATA   = 3'd5;
localparam ST_SCALE_WAIT  = 3'd6;

localparam [15:0] BMP_MIN_WIDTH  = 16'd320;
localparam [15:0] BMP_MAX_WIDTH  = 16'd1280;
localparam [15:0] BMP_MIN_HEIGHT = 16'd180;
localparam [15:0] BMP_MAX_HEIGHT = 16'd960;

reg [2:0]  state;
reg [9:0]  rd_cnt;

reg        header_0_match;
reg        header_1_match;
reg [31:0] file_len;
reg [31:0] pixel_offset;
reg [31:0] width;
reg [31:0] height;
reg        bit_count_low_match;
reg        bit_count_high_match;
reg        compression_nonzero;

reg [31:0] scan_sector;
reg [31:0] load_sector_latched;
reg [31:0] bmp_len_cnt;
reg [1:0]  bmp_byte_idx;
// Header acceptance already limits width<=1280 and height<=960:
// RGB24 row stride<=3840, x<1280, and the completed row count<=960.
reg [11:0] bmp_row_byte_idx;
reg [11:0] bmp_last_row_byte;
reg [10:0] bmp_last_pixel_x;
reg [11:0] bmp_pixel_bytes_per_row;
reg [9:0]  bmp_row_idx;
reg [10:0] bmp_pixel_x_count;
reg [5:0]  fifo_settle_cnt;
reg [26:0] sd_wait_cnt;
reg        sd_wait_timeout;
reg        header_match_latched;
reg [31:0] file_sector_count_latched;
reg [3:0]  idle_state_code;
reg        scan_saw_bm;

// Allow a slow card or the first access after FPGA reconfiguration up to one
// second. A real 512-byte SPI transfer normally completes much sooner.
localparam [26:0] SD_WAIT_LIMIT = 27'd100_000_000;

wire header_match;
reg bmp_data_valid;
reg [7:0] bmp_load_byte;
wire [31:0] file_sector_count;
wire [31:0] next_scan_sector_if_match;
wire [31:0] next_scan_sector_if_miss;

// Parallel byte comparisons avoid the long 32-bit subtract carry chain in
// TD's default relational-operator mapping. Preserve full unsigned range.
function unsigned_less32;
    input [31:0] a;
    input [31:0] b;
    reg [3:0] eq_byte, lt_byte;
    begin
        eq_byte = {a[31:24]==b[31:24], a[23:16]==b[23:16],
                   a[15:8]==b[15:8], a[7:0]==b[7:0]};
        lt_byte = {a[31:24]<b[31:24], a[23:16]<b[23:16],
                   a[15:8]<b[15:8], a[7:0]<b[7:0]};
        unsigned_less32 = lt_byte[3] |
                         (eq_byte[3] & lt_byte[2]) |
                         (&eq_byte[3:2] & lt_byte[1]) |
                         (&eq_byte[3:1] & lt_byte[0]);
    end
endfunction

assign ready = (state == ST_IDLE);
assign header_match = header_0_match && header_1_match &&
                      (width[31:16]  == 16'd0) &&
                      (height[31:16] == 16'd0) &&
                      (width[15:0]  >= BMP_MIN_WIDTH) &&
                      (width[15:0]  <= BMP_MAX_WIDTH) &&
                      (height[15:0] >= BMP_MIN_HEIGHT) &&
                      (height[15:0] <= BMP_MAX_HEIGHT) &&
                      bit_count_low_match && bit_count_high_match &&
                      !compression_nonzero;
// Separate file-range decoding from RGB assembly and row-end clock enables.
// Header parsing continues to use the original byte stream independently.
always @(posedge clk or posedge rst) begin
    if(rst) begin
        bmp_data_valid <= 1'b0;
        bmp_load_byte <= 8'd0;
    end else begin
        bmp_data_valid <= (state == ST_LOAD_DATA) && !load_abort &&
                         sd_sec_read_data_valid &&
                         !unsigned_less32(bmp_len_cnt, pixel_offset) &&
                         unsigned_less32(bmp_len_cnt, file_len);
        if(sd_sec_read_data_valid) bmp_load_byte <= sd_sec_read_data;
    end
end
assign file_sector_count = (file_len == 32'd0) ? 32'd1 : ((file_len + 32'd511) >> 9);
assign next_scan_sector_if_match = scan_sector + file_sector_count_latched;
assign next_scan_sector_if_miss  = scan_sector + 32'd1;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rd_cnt <= 10'd0;
    end else if ((state == ST_SCAN) || (state == ST_LOAD_HDR)) begin
        if (sd_sec_read_data_valid)
            rd_cnt <= rd_cnt + 10'd1;
        else if (sd_sec_read_end)
            rd_cnt <= 10'd0;
    end else begin
        rd_cnt <= 10'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_0_match <= 1'b0;
        header_1_match <= 1'b0;
        file_len     <= 32'd0;
        pixel_offset <= 32'd54;
        width        <= 32'd0;
        height       <= 32'd0;
        bit_count_low_match <= 1'b0;
        bit_count_high_match <= 1'b0;
        compression_nonzero <= 1'b0;
    end else if (((state == ST_SCAN) || (state == ST_LOAD_HDR)) && sd_sec_read_data_valid) begin
        case (rd_cnt)
            10'd0 : begin
                header_0_match <= (sd_sec_read_data == "B");
                compression_nonzero <= 1'b0;
            end
            10'd1 : header_1_match <= (sd_sec_read_data == "M");

            10'd2 : file_len[7:0] <= sd_sec_read_data;
            10'd3 : file_len[15:8] <= sd_sec_read_data;
            10'd4 : file_len[23:16] <= sd_sec_read_data;
            10'd5 : file_len[31:24] <= sd_sec_read_data;

            10'd10: pixel_offset[7:0] <= sd_sec_read_data;
            10'd11: pixel_offset[15:8] <= sd_sec_read_data;
            10'd12: pixel_offset[23:16] <= sd_sec_read_data;
            10'd13: pixel_offset[31:24] <= sd_sec_read_data;

            10'd18: width[7:0] <= sd_sec_read_data;
            10'd19: width[15:8] <= sd_sec_read_data;
            10'd20: width[23:16] <= sd_sec_read_data;
            10'd21: width[31:24] <= sd_sec_read_data;

            10'd22: height[7:0] <= sd_sec_read_data;
            10'd23: height[15:8] <= sd_sec_read_data;
            10'd24: height[23:16] <= sd_sec_read_data;
            10'd25: height[31:24] <= sd_sec_read_data;

            10'd28: bit_count_low_match <= (sd_sec_read_data == 8'd24);
            10'd29: bit_count_high_match <= (sd_sec_read_data == 8'd0);

            10'd30,10'd31,10'd32,10'd33:
                if(sd_sec_read_data != 0) compression_nonzero <= 1'b1;
            default: ;
        endcase
    end
end

// The decoded header remains stable for hundreds of clocks before the sector
// ends. Register it early so the range comparators are not part of the scan
// state transition path.
always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_match_latched      <= 1'b0;
        file_sector_count_latched <= 32'd1;
    end else begin
        // Consume these only at the end of a complete 512-byte header
        // transaction. All header bytes (0..33) have then been stable for
        // hundreds of clocks. Continuous registration removes a long
        // state/byte-index clock-enable cone without changing that boundary.
        header_match_latched      <= header_match;
        file_sector_count_latched <= file_sector_count;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_len_cnt <= 32'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (sd_sec_read_data_valid)
            bmp_len_cnt <= bmp_len_cnt + 32'd1;
    end else begin
        bmp_len_cnt <= 32'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        fifo_settle_cnt <= 6'd0;
        sd_wait_cnt     <= 27'd0;
        sd_wait_timeout <= 1'b0;
    end else begin
        if (state == ST_LOAD_WAIT) begin
            fifo_settle_cnt <= 6'd0;
        end else if (state == ST_LOAD_SETTLE) begin
            if (fifo_settle_cnt != 6'd63)
                fifo_settle_cnt <= fifo_settle_cnt + 6'd1;
        end else begin
            fifo_settle_cnt <= 6'd0;
        end

        if ((state == ST_SCAN) || (state == ST_LOAD_HDR) ||
            (state == ST_LOAD_DATA)) begin
            if (sd_sec_read_data_valid || sd_sec_read_end) begin
                sd_wait_cnt <= 27'd0;
                sd_wait_timeout <= 1'b0;
            end else if (!sd_wait_timeout) begin
                if (sd_wait_cnt >= (SD_WAIT_LIMIT - 1'b1)) begin
                    sd_wait_timeout <= 1'b1;
                end else begin
                    sd_wait_cnt <= sd_wait_cnt + 27'd1;
                end
            end
        end else begin
            sd_wait_cnt <= 27'd0;
            sd_wait_timeout <= 1'b0;
        end
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_data_wr_en <= 1'b0;
        bmp_data       <= 24'd0;
        bmp_byte_idx   <= 2'd0;
        bmp_row_byte_idx <= 32'd0;
        bmp_pixel_x    <= 16'd0;
        bmp_pixel_x_count <= 16'd0;
        bmp_row_idx    <= 16'd0;
        bmp_row_end    <= 1'b0;
    end else if (!load_abort && ((state == ST_LOAD_DATA) || bmp_data_valid)) begin
        bmp_data_wr_en <= 1'b0;
        bmp_row_end    <= 1'b0;

        if (bmp_data_valid && (bmp_row_idx < image_height)) begin
            if (bmp_row_byte_idx == bmp_last_row_byte)
                bmp_row_byte_idx <= 32'd0;
            else
                bmp_row_byte_idx <= bmp_row_byte_idx + 32'd1;

            if (bmp_row_byte_idx < bmp_pixel_bytes_per_row) begin
            case (bmp_byte_idx)
                2'd0: begin
                    bmp_data[7:0]  <= bmp_load_byte;
                    bmp_byte_idx   <= 2'd1;
                end
                2'd1: begin
                    bmp_data[15:8] <= bmp_load_byte;
                    bmp_byte_idx   <= 2'd2;
                end
                2'd2: begin
                    bmp_data_wr_en  <= 1'b1;
                    bmp_data[23:16] <= bmp_load_byte;
                    bmp_pixel_x     <= bmp_pixel_x_count;
                    bmp_byte_idx    <= 2'd0;

                    if (bmp_pixel_x_count == bmp_last_pixel_x) begin
                        bmp_pixel_x_count <= 16'd0;
                        bmp_row_idx <= bmp_row_idx + 16'd1;
                        bmp_row_end <= 1'b1;
                    end else begin
                        bmp_pixel_x_count <= bmp_pixel_x_count + 16'd1;
                    end
                end
                default: begin
                    bmp_byte_idx <= 2'd0;
                end
            endcase
            end else begin
                // BMP rows are padded to a 4-byte boundary. Padding bytes are
                // part of the file but must never become output pixels.
                bmp_byte_idx <= 2'd0;
            end
        end else begin
            bmp_data_wr_en <= 1'b0;
        end
    end else begin
        bmp_data_wr_en <= 1'b0;
        bmp_byte_idx   <= 2'd0;
        bmp_row_byte_idx <= 32'd0;
        bmp_pixel_x    <= 16'd0;
        bmp_pixel_x_count <= 16'd0;
        bmp_row_idx    <= 16'd0;
        bmp_row_end    <= 1'b0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
        image_meta_valid  <= 1'b0;
        image_width       <= 16'd0;
        image_height      <= 16'd0;
        bmp_last_row_byte <= 12'd0;
        bmp_last_pixel_x <= 11'd0;
        bmp_pixel_bytes_per_row <= 32'd0;
        scale_start       <= 1'b0;
        idle_state_code   <= 4'd1;
        scan_saw_bm       <= 1'b0;
    end else if (!sd_init_done || load_abort) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
        image_meta_valid  <= 1'b0;
        image_width       <= 16'd0;
        image_height      <= 16'd0;
        bmp_last_row_byte <= 12'd0;
        bmp_last_pixel_x <= 11'd0;
        bmp_pixel_bytes_per_row <= 32'd0;
        scale_start       <= 1'b0;
        idle_state_code   <= 4'd1;
        scan_saw_bm       <= 1'b0;
    end else begin
        scan_found_valid <= 1'b0;
        image_meta_valid <= 1'b0;
        scale_start      <= 1'b0;

        case (state)
            ST_IDLE: begin
                state_code  <= idle_state_code;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;

                if (scan_start) begin
                    idle_state_code <= 4'd1;
                    scan_saw_bm     <= 1'b0;
                    scan_done        <= 1'b0;
                    scan_found_total <= 3'd0;
                    scan_sector      <= scan_start_sector;
                    sd_sec_read_addr <= scan_start_sector;
                    state            <= ST_SCAN;
                end else if (load_start) begin
                    idle_state_code   <= 4'd5;
                    load_sector_latched <= load_sector;
                    sd_sec_read_addr    <= load_sector;
                    state               <= ST_LOAD_HDR;
                end
            end

            ST_SCAN: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_wait_timeout) begin
                    // A lost SD transaction must not leave the scanner in a
                    // permanent read state. Return to idle so the supervisor
                    // can retry or report that no valid image was found.
                    sd_sec_read <= 1'b0;
                    scan_done   <= 1'b1;
                    idle_state_code <= 4'd7;
                    state       <= ST_IDLE;
                end else if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;

                    if (header_0_match && header_1_match)
                        scan_saw_bm <= 1'b1;

                    if (header_match_latched) begin
                        scan_found_valid  <= 1'b1;
                        scan_found_sector <= scan_sector;
                        scan_found_total  <= scan_found_total + 3'd1;

                        if ((scan_found_total + 3'd1 >= scan_target_count) || (next_scan_sector_if_match > scan_max_sector)) begin
                            scan_done        <= 1'b1;
                            idle_state_code  <= 4'd5;
                            state            <= ST_IDLE;
                            sd_sec_read_addr <= next_scan_sector_if_match;
                            scan_sector      <= next_scan_sector_if_match;
                        end else begin
                            sd_sec_read_addr <= next_scan_sector_if_match;
                            scan_sector      <= next_scan_sector_if_match;
                        end
                    end else begin
                        if (scan_sector >= scan_max_sector) begin
                            scan_done <= 1'b1;
                            idle_state_code <= (scan_saw_bm ||
                                                (header_0_match && header_1_match)) ?
                                               4'd8 : 4'd6;
                            state     <= ST_IDLE;
                        end else begin
                            sd_sec_read_addr <= next_scan_sector_if_miss;
                            scan_sector      <= next_scan_sector_if_miss;
                        end
                    end
                end
            end

            ST_LOAD_HDR: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_wait_timeout) begin
                    sd_sec_read <= 1'b0;
                    idle_state_code <= 4'd9;
                    state       <= ST_IDLE;
                end else if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (header_match_latched) begin
                        idle_state_code   <= 4'd5;
                        image_width       <= width[15:0];
                        image_height      <= height[15:0];
                        bmp_pixel_bytes_per_row <= width[15:0] * 32'd3;
                        // Precompute terminal indices once per accepted header;
                        // no width-minus-one carry chain in the pixel enable path.
                        bmp_last_row_byte <= (((width[15:0] * 32'd3) + 32'd3) & 32'hffff_fffc) - 1'b1;
                        bmp_last_pixel_x <= width[10:0] - 11'd1;
                        image_meta_valid  <= 1'b1;
                        write_req        <= 1'b1;
                        sd_sec_read_addr <= load_sector_latched;
                        state            <= ST_LOAD_WAIT;
                    end else begin
                        idle_state_code <= 4'd9;
                        state <= ST_IDLE;
                    end
                end
            end

            ST_LOAD_WAIT: begin
                state_code <= 4'd3;
                if (write_req_ack) begin
                    write_req <= 1'b0;
                    state     <= ST_LOAD_SETTLE;
                end
            end

            ST_LOAD_SETTLE: begin
                state_code  <= 4'd3;
                sd_sec_read <= 1'b0;
                if ((fifo_settle_cnt == 6'd63) && scale_layout_ready) begin
                    scale_start <= 1'b1;
                    state <= ST_SCALE_WAIT;
                end
            end

            ST_SCALE_WAIT: begin
                state_code  <= 4'd3;
                sd_sec_read <= 1'b0;
                if (scale_input_ready) begin
                    state <= ST_LOAD_DATA;
                end
            end

            ST_LOAD_DATA: begin
                state_code  <= 4'd4;
                sd_sec_read <= 1'b1;

                if (sd_wait_timeout) begin
                    sd_sec_read <= 1'b0;
                    idle_state_code <= 4'd9;
                    state       <= ST_IDLE;
                end else if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (bmp_len_cnt >= file_len) begin
                        idle_state_code <= 4'd5;
                        state <= ST_IDLE;
                    end else begin
                        sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
                    end
                end
            end

            default: begin
                state       <= ST_IDLE;
                state_code  <= 4'd1;
                idle_state_code <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;
            end
        endcase
    end
end

endmodule
