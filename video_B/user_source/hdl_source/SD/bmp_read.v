module bmp_read #(
    parameter integer VIDEO_WIDTH = 512,
    parameter integer VIDEO_HEIGHT = 384,
    parameter integer AUDIO_SAMPLES_PER_FRAME = 3000
)(
    output reg                  audio_write_en,
    output reg [11:0]           audio_write_addr,
    output reg [15:0]           audio_write_data,
    output reg                  audio_frame_done,
    input                       clk,
    input                       rst,
    output                      ready,

    input                       scan_start,
    input  [31:0]               scan_start_sector,
    input  [31:0]               scan_max_sector,
    input  [4:0]                scan_target_count,
    output reg                  scan_done,
    output reg                  scan_found_valid,
    output reg [31:0]           scan_found_sector,
    output reg [4:0]            scan_found_total,

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
    output reg [15:0]           sd_sec_read_count,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,

    output reg                  bmp_data_wr_en,
    output reg [23:0]           bmp_data,
    output reg [15:0]           bmp_pixel_x,
    output reg                  bmp_row_end,

    output reg [31:0]           video_frame_count,
    output reg [7:0]            video_fps,
    output reg [31:0]           video_data_sector,
    output reg [31:0]           video_last_frame_sector
);

localparam ST_IDLE        = 3'd0;
localparam ST_SCAN        = 3'd1;
localparam ST_LOAD_WAIT   = 3'd2;
localparam ST_LOAD_SETTLE = 3'd3;
localparam ST_SCALE_WAIT  = 3'd4;
localparam ST_LOAD_DATA   = 3'd5;
localparam ST_AUDIO_DATA  = 3'd6;

localparam [15:0] VIDEO_FRAME_SECTORS = VIDEO_WIDTH * VIDEO_HEIGHT / 256;
localparam [15:0] VIDEO_READ_BURST_SECTORS = 16'd4;
localparam [26:0] SD_WAIT_LIMIT       = 27'd100_000_000;

reg [2:0]  state;
reg [9:0]  rd_cnt;
reg [31:0] scan_sector;
reg [31:0] load_sector_latched;
reg [15:0] load_sector_count;
reg [5:0]  fifo_settle_cnt;
reg [26:0] sd_wait_cnt;
reg        sd_wait_timeout;
reg [3:0]  idle_state_code;

reg [7:0]  header_0;
reg [7:0]  header_1;
reg [7:0]  header_2;
reg [7:0]  header_3;
reg [15:0] header_width;
reg [15:0] header_height;
reg [7:0]  header_fps;
reg [7:0]  header_format;
reg [31:0] header_frame_count;
reg [15:0] header_frame_sectors;
reg [31:0] header_last_frame_offset;
reg        header_match_latched;
reg [31:0] header_audio_rate;
reg [15:0] header_audio_samples;
reg [15:0] header_audio_format;
reg [12:0] audio_byte_count;
reg [7:0] audio_low;

reg [7:0]  rgb565_low;
reg        rgb565_byte_phase;
reg [15:0] pixel_x_count;
reg [15:0] pixel_y_count;
wire [15:0] rgb565_word;
wire [7:0]  rgb_r;
wire [7:0]  rgb_g;
wire [7:0]  rgb_b;
wire        header_match;

assign ready = (state == ST_IDLE);
assign rgb565_word = {sd_sec_read_data, rgb565_low};
assign rgb_r = {rgb565_word[15:11], rgb565_word[15:13]};
assign rgb_g = {rgb565_word[10:5],  rgb565_word[10:9]};
assign rgb_b = {rgb565_word[4:0],   rgb565_word[4:2]};
assign header_match = (header_0 == "R") &&
                      (header_1 == "V") &&
                      (header_2 == "A") &&
                      (header_3 == "1") &&
                      (header_width == VIDEO_WIDTH) &&
                      (header_height == VIDEO_HEIGHT) &&
                      (header_fps == 8'd30) &&
                      (header_format == 8'd1) &&
                      (header_frame_count != 32'd0) &&
                      (header_frame_sectors == VIDEO_FRAME_SECTORS + 16'd12) &&
                      (header_audio_rate == 32'd24000) &&
                      (header_audio_samples == AUDIO_SAMPLES_PER_FRAME) &&
                      (header_audio_format == 16'd1);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rd_cnt <= 10'd0;
    end else if (state == ST_SCAN) begin
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
        header_0             <= 8'd0;
        header_1             <= 8'd0;
        header_2             <= 8'd0;
        header_3             <= 8'd0;
        header_width         <= 16'd0;
        header_height        <= 16'd0;
        header_fps           <= 8'd0;
        header_format        <= 8'd0;
        header_frame_count   <= 32'd0;
        header_frame_sectors <= 16'd0;
        header_last_frame_offset <= 32'd0;
        header_match_latched <= 1'b0;
        header_audio_rate <= 32'd0;
        header_audio_samples <= 16'd0;
        header_audio_format <= 16'd0;
    end else if (!sd_init_done || load_abort) begin
        header_match_latched <= 1'b0;
    end else if (state == ST_SCAN) begin
        if (sd_sec_read_data_valid) begin
            case (rd_cnt)
                10'd24: header_audio_rate[7:0] <= sd_sec_read_data;
                10'd25: header_audio_rate[15:8] <= sd_sec_read_data;
                10'd26: header_audio_rate[23:16] <= sd_sec_read_data;
                10'd27: header_audio_rate[31:24] <= sd_sec_read_data;
                10'd28: header_audio_samples[7:0] <= sd_sec_read_data;
                10'd29: header_audio_samples[15:8] <= sd_sec_read_data;
                10'd30: header_audio_format[7:0] <= sd_sec_read_data;
                10'd31: header_audio_format[15:8] <= sd_sec_read_data;
                10'd0:  begin header_0 <= sd_sec_read_data; header_match_latched <= 1'b0; end
                10'd1:  header_1 <= sd_sec_read_data;
                10'd2:  header_2 <= sd_sec_read_data;
                10'd3:  header_3 <= sd_sec_read_data;
                10'd4:  header_width[7:0] <= sd_sec_read_data;
                10'd5:  header_width[15:8] <= sd_sec_read_data;
                10'd6:  header_height[7:0] <= sd_sec_read_data;
                10'd7:  header_height[15:8] <= sd_sec_read_data;
                10'd8:  header_fps <= sd_sec_read_data;
                10'd9:  header_format <= sd_sec_read_data;
                10'd12: header_frame_count[7:0] <= sd_sec_read_data;
                10'd13: header_frame_count[15:8] <= sd_sec_read_data;
                10'd14: header_frame_count[23:16] <= sd_sec_read_data;
                10'd15: header_frame_count[31:24] <= sd_sec_read_data;
                10'd16: header_frame_sectors[7:0] <= sd_sec_read_data;
                10'd17: header_frame_sectors[15:8] <= sd_sec_read_data;
                10'd20: header_last_frame_offset[7:0] <= sd_sec_read_data;
                10'd21: header_last_frame_offset[15:8] <= sd_sec_read_data;
                10'd22: header_last_frame_offset[23:16] <= sd_sec_read_data;
                10'd23: header_last_frame_offset[31:24] <= sd_sec_read_data;
                10'd32: header_match_latched <= header_match;
                default: ;
            endcase
        end
    end else begin
        header_match_latched <= 1'b0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        fifo_settle_cnt <= 6'd0;
        sd_wait_cnt     <= 27'd0;
        sd_wait_timeout <= 1'b0;
    end else begin
        if (state == ST_LOAD_SETTLE) begin
            if (fifo_settle_cnt != 6'd63)
                fifo_settle_cnt <= fifo_settle_cnt + 6'd1;
        end else begin
            fifo_settle_cnt <= 6'd0;
        end

        if ((state == ST_SCAN) || (state == ST_LOAD_DATA) || (state == ST_AUDIO_DATA)) begin
            if (sd_sec_read_data_valid || sd_sec_read_end) begin
                sd_wait_cnt     <= 27'd0;
                sd_wait_timeout <= 1'b0;
            end else if (!sd_wait_timeout) begin
                if (sd_wait_cnt >= (SD_WAIT_LIMIT - 1'b1))
                    sd_wait_timeout <= 1'b1;
                else
                    sd_wait_cnt <= sd_wait_cnt + 27'd1;
            end
        end else begin
            sd_wait_cnt     <= 27'd0;
            sd_wait_timeout <= 1'b0;
        end
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        audio_byte_count <= 13'd0;
        audio_low <= 8'd0;
        audio_write_en <= 1'b0;
        audio_write_addr <= 12'd0;
        audio_write_data <= 16'd0;
    end else begin
        audio_write_en <= 1'b0;
        if (state != ST_AUDIO_DATA || load_abort) begin
            audio_byte_count <= 13'd0;
        end else if (sd_sec_read_data_valid) begin
            audio_byte_count <= audio_byte_count + 1'b1;
            if (audio_byte_count < AUDIO_SAMPLES_PER_FRAME * 2) begin
                if (!audio_byte_count[0]) audio_low <= sd_sec_read_data;
                else begin
                    audio_write_en <= 1'b1;
                    audio_write_addr <= audio_byte_count[12:1];
                    audio_write_data <= {sd_sec_read_data, audio_low};
                end
            end
        end
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_data_wr_en   <= 1'b0;
        bmp_data         <= 24'd0;
        bmp_pixel_x      <= 16'd0;
        bmp_row_end      <= 1'b0;
        rgb565_low       <= 8'd0;
        rgb565_byte_phase <= 1'b0;
        pixel_x_count    <= 16'd0;
        pixel_y_count    <= 16'd0;
    end else if (state == ST_LOAD_DATA) begin
        bmp_data_wr_en <= 1'b0;
        bmp_row_end    <= 1'b0;

        if (sd_sec_read_data_valid &&
            (pixel_y_count < VIDEO_HEIGHT)) begin
            if (!rgb565_byte_phase) begin
                rgb565_low        <= sd_sec_read_data;
                rgb565_byte_phase <= 1'b1;
            end else begin
                rgb565_byte_phase <= 1'b0;
                bmp_data_wr_en    <= 1'b1;
                bmp_data          <= {rgb_r, rgb_g, rgb_b};
                bmp_pixel_x       <= pixel_x_count;

                if (pixel_x_count == VIDEO_WIDTH - 1'b1) begin
                    pixel_x_count <= 16'd0;
                    pixel_y_count <= pixel_y_count + 16'd1;
                    bmp_row_end   <= 1'b1;
                end else begin
                    pixel_x_count <= pixel_x_count + 16'd1;
                end
            end
        end
    end else begin
        bmp_data_wr_en    <= 1'b0;
        bmp_row_end       <= 1'b0;
        rgb565_byte_phase <= 1'b0;
        pixel_x_count     <= 16'd0;
        pixel_y_count     <= 16'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state                <= ST_IDLE;
        state_code           <= 4'd0;
        sd_sec_read          <= 1'b0;
        sd_sec_read_addr     <= 32'd0;
        sd_sec_read_count    <= 16'd1;
        write_req            <= 1'b0;
        scan_done            <= 1'b0;
        scan_found_valid     <= 1'b0;
        scan_found_sector    <= 32'd0;
        scan_found_total     <= 5'd0;
        scan_sector          <= 32'd0;
        load_sector_latched  <= 32'd0;
        load_sector_count    <= 16'd0;
        image_meta_valid     <= 1'b0;
        image_width          <= VIDEO_WIDTH;
        image_height         <= VIDEO_HEIGHT;
        scale_start          <= 1'b0;
        idle_state_code      <= 4'd1;
        video_frame_count    <= 32'd0;
        video_fps            <= 8'd0;
        video_data_sector    <= 32'd0;
        video_last_frame_sector <= 32'd0;
        audio_frame_done <= 1'b0;
    end else if (!sd_init_done) begin
        audio_frame_done <= 1'b0;
        state                <= ST_IDLE;
        state_code           <= 4'd0;
        sd_sec_read          <= 1'b0;
        sd_sec_read_count    <= 16'd1;
        write_req            <= 1'b0;
        scan_done            <= 1'b0;
        scan_found_valid     <= 1'b0;
        scan_found_total     <= 5'd0;
        load_sector_count    <= 16'd0;
        image_meta_valid     <= 1'b0;
        scale_start          <= 1'b0;
        idle_state_code      <= 4'd1;
        video_frame_count    <= 32'd0;
        video_fps            <= 8'd0;
        video_data_sector    <= 32'd0;
        video_last_frame_sector <= 32'd0;
    end else if (load_abort) begin
        audio_frame_done <= 1'b0;
        state                <= ST_IDLE;
        state_code           <= 4'd7;
        sd_sec_read          <= 1'b0;
        sd_sec_read_count    <= 16'd1;
        write_req            <= 1'b0;
        scan_found_valid     <= 1'b0;
        load_sector_count    <= 16'd0;
        image_meta_valid     <= 1'b0;
        scale_start          <= 1'b0;
        idle_state_code      <= 4'd7;
    end else begin
        audio_frame_done <= 1'b0;
        scan_found_valid <= 1'b0;
        image_meta_valid <= 1'b0;
        scale_start      <= 1'b0;

        case (state)
            ST_IDLE: begin
                state_code  <= idle_state_code;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;

                if (scan_start) begin
                    scan_done         <= 1'b0;
                    scan_found_total  <= 5'd0;
                    scan_sector       <= scan_start_sector;
                    sd_sec_read_addr  <= scan_start_sector;
                    idle_state_code   <= 4'd1;
                    state             <= ST_SCAN;
                end else if (load_start) begin
                    load_sector_latched <= load_sector;
                    load_sector_count   <= 16'd0;
                    image_width         <= VIDEO_WIDTH;
                    image_height        <= VIDEO_HEIGHT;
                    image_meta_valid    <= 1'b1;
                    write_req           <= 1'b1;
                    idle_state_code     <= 4'd5;
                    state               <= ST_LOAD_WAIT;
                end
            end

            ST_SCAN: begin
                state_code  <= 4'd2;
                sd_sec_read_count <= 16'd1;
                sd_sec_read <= 1'b1;

                if (sd_wait_timeout) begin
                    sd_sec_read       <= 1'b0;
                    scan_done         <= 1'b1;
                    idle_state_code   <= 4'd7;
                    state             <= ST_IDLE;
                end else if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (header_match_latched) begin
                        scan_found_valid  <= 1'b1;
                        scan_found_sector <= scan_sector;
                        scan_found_total  <= 5'd1;
                        scan_done         <= 1'b1;
                        video_frame_count <= header_frame_count;
                        video_fps         <= header_fps;
                        video_data_sector <= scan_sector + 32'd1;
                        video_last_frame_sector <= scan_sector + 32'd1 +
                                                   header_last_frame_offset;
                        idle_state_code   <= 4'd5;
                        state             <= ST_IDLE;
                    end else if (scan_sector >= scan_max_sector) begin
                        scan_done       <= 1'b1;
                        idle_state_code <= 4'd6;
                        state           <= ST_IDLE;
                    end else begin
                        scan_sector      <= scan_sector + 32'd1;
                        sd_sec_read_addr <= scan_sector + 32'd1;
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
                state_code <= 4'd3;
                if ((fifo_settle_cnt == 6'd63) && scale_layout_ready) begin
                    scale_start <= 1'b1;
                    state       <= ST_SCALE_WAIT;
                end
            end

            ST_SCALE_WAIT: begin
                state_code <= 4'd3;
                if (scale_input_ready) begin
                    sd_sec_read_addr <= load_sector_latched;
                    if (VIDEO_FRAME_SECTORS > VIDEO_READ_BURST_SECTORS)
                        sd_sec_read_count <= VIDEO_READ_BURST_SECTORS;
                    else
                        sd_sec_read_count <= VIDEO_FRAME_SECTORS;
                    state <= ST_LOAD_DATA;
                end
            end

            ST_LOAD_DATA: begin
                state_code  <= 4'd4;
                sd_sec_read <= 1'b1;

                if (sd_wait_timeout) begin
                    sd_sec_read       <= 1'b0;
                    idle_state_code   <= 4'd9;
                    state             <= ST_IDLE;
                end else if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    // Image bursts are four sectors until the last (possibly
                    // short) burst. Compare the current count with a constant
                    // threshold, avoiding add->compare on the state/CE path.
                    if ((VIDEO_FRAME_SECTORS <= VIDEO_READ_BURST_SECTORS) ||
                        (load_sector_count >=
                         VIDEO_FRAME_SECTORS - VIDEO_READ_BURST_SECTORS)) begin
                        sd_sec_read_addr <= load_sector_latched + VIDEO_FRAME_SECTORS;
                        sd_sec_read_count <= 16'd4;
                        load_sector_count <= 16'd0;
                        state <= ST_AUDIO_DATA;
                    end else begin
                        load_sector_count <= load_sector_count +
                                             sd_sec_read_count;
                        sd_sec_read_addr  <= sd_sec_read_addr +
                                             sd_sec_read_count;
                        if ((VIDEO_FRAME_SECTORS > 2*VIDEO_READ_BURST_SECTORS) &&
                            (load_sector_count <
                             VIDEO_FRAME_SECTORS - 2*VIDEO_READ_BURST_SECTORS))
                            sd_sec_read_count <= VIDEO_READ_BURST_SECTORS;
                        else
                            sd_sec_read_count <= VIDEO_FRAME_SECTORS -
                                                 VIDEO_READ_BURST_SECTORS -
                                                 load_sector_count;
                    end
                end
            end

            ST_AUDIO_DATA: begin
                state_code <= 4'd4;
                sd_sec_read <= 1'b1;
                if (sd_wait_timeout) begin
                    sd_sec_read <= 1'b0;
                    idle_state_code <= 4'd9;
                    state <= ST_IDLE;
                end else if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if ((load_sector_count + sd_sec_read_count) >= 16'd12) begin
                        audio_frame_done <= (audio_byte_count == 13'd6144);
                        idle_state_code <= (audio_byte_count == 13'd6144) ? 4'd5 : 4'd9;
                        state <= ST_IDLE;
                    end else begin
                        load_sector_count <= load_sector_count + sd_sec_read_count;
                        sd_sec_read_addr <= sd_sec_read_addr + sd_sec_read_count;
                        sd_sec_read_count <= 16'd4;
                    end
                end
            end

            default: begin
                state           <= ST_IDLE;
                state_code      <= 4'd1;
                idle_state_code <= 4'd1;
                sd_sec_read     <= 1'b0;
                write_req       <= 1'b0;
            end
        endcase
    end
end

wire unused_inputs = &{1'b0, scan_target_count, bmp_width, bmp_height};

endmodule
