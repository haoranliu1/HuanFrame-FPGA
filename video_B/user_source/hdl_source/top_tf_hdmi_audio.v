
module top(
    input                       clk,
    input                       key1,           // physical KEY1/A2; manual next
    input                       key2,           // physical KEY2/B2; auto play
    input                       key3,           // physical KEY3/B1; reserved event input
    input                       key4,           // physical KEY4/C1; reserved event input
    input                       touch_uart_rx,  // TJC screen TX -> J2-1/FPGA P4

    // On-board RTL8211E RGMII interface
    input                       phy1_rgmii_rx_clk,
    input                       phy1_rgmii_rx_ctl,
    input [3:0]                 phy1_rgmii_rx_data,
    output                      phy1_rgmii_tx_clk,
    output                      phy1_rgmii_tx_ctl,
    output [3:0]                phy1_rgmii_tx_data,

	output [5:0]                seg_sel,
	output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter FRAME_PIXELS  = 24'd307200;   // 640*480
parameter BUF0_ADDR     = 24'd0;
parameter BUF1_ADDR     = FRAME_PIXELS;
parameter BUF2_ADDR     = FRAME_PIXELS * 2;
parameter BUF3_ADDR     = FRAME_PIXELS * 3;
// Development build switch. Set to 1 until a valid TF card is available;
// set to 0 for the competition TF/BMP path.
// TF/BMP debug build. The verified ROM/SDRAM baseline remains available as a
// separately archived bitstream while the real card path is being repaired.
localparam NO_TF_MODE   = 1'b0;
// Keep a direct-pattern fallback until the first internally generated frame
// has completed its SDRAM write. The HDMI path then uses SDRAM readback.
localparam NO_TF_SDRAM_OUTPUT = 1'b1;
// Local/video image B deliberately removes the Ethernet protocol stack.
// Keeping this as a synthesis-time constant makes it easy to audit and keeps
// the TF/HDMI/touch functions identical to the verified network baseline.
localparam ENABLE_NETWORK = 1'b0;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [23:0] vout_data;
wire [23:0] overlay_base_rgb;
wire        display_valid;
wire [7:0]  diag_rgb_r;
wire [7:0]  diag_rgb_g;
wire [7:0]  diag_rgb_b;
wire [23:0] direct_test_rgb;
wire [3:0]  direct_last_key_code;
wire        seg_scan_rst_n;

wire [3:0]  state_code;
wire [6:0]  seg_data_0;
wire [6:0]  seg_data_key1;
wire [6:0]  seg_data_key2;
wire [6:0]  seg_data_key3;
wire [6:0]  seg_data_key4;
wire [6:0]  seg_data_last_key;

wire        video_read_req;
wire        video_read_req_ack;
wire        video_sdram_read_req;
wire        video_read_en;
wire [31:0] video_read_data;
wire        video_read_fifo_empty;
wire        video_read_ready;

wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack_mem;
wire        sd_card_write_req_ack;
wire        sd_write_fifo_full;
wire        frame_write_finish;
reg         frame_write_toggle_mem;
reg         sd_card_write_req_ack_sync0;
reg         sd_card_write_req_ack_sync1;

wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;
wire [3:0]  frame_image_index;
wire        frame_auto_play;
wire [3:0]  frame_auto_interval_seconds;
wire [1:0]  reservoir_level_gray;
wire        key_next_video_event;
wire        key_prev_video_event;
wire        key_auto_video_event;
reg         key_next_toggle_video;
reg         key_prev_toggle_video;
reg         key_auto_toggle_video;
reg         touch_auto_start_toggle_video;
reg         touch_auto_stop_toggle_video;
wire        touch_manual_prev_toggle_clk;
wire        touch_manual_next_toggle_clk;
wire        touch_auto_start_toggle_clk;
wire        touch_auto_stop_toggle_clk;
wire        touch_brightness_toggle_clk;
wire        touch_contrast_toggle_clk;
wire        touch_volume_toggle_clk;
wire [6:0]  touch_brightness_value_clk;
wire [6:0]  touch_contrast_value_clk;
wire [6:0]  touch_volume_value_clk;
wire        touch_manual_note_enable_clk;
wire        touch_manual_note_gate_clk;
wire [2:0]  touch_manual_note_index_clk;
wire        touch_transition_mode_toggle_clk;
wire [2:0]  touch_transition_mode_value_clk;
wire        touch_interval_toggle_clk;
wire [3:0]  touch_interval_value_clk;
wire        touch_subtitle_commit_toggle_clk;
wire [255:0] touch_subtitle_text_clk;
wire [5:0]  touch_subtitle_length_clk;
wire [2:0]  touch_subtitle_color_clk;
wire        network_ready;
wire        network_subtitle_commit_toggle_clk;
wire [255:0] network_subtitle_text_clk;
wire [5:0]  network_subtitle_length_clk;
wire [2:0]  network_subtitle_color_clk;
wire        network_subtitle_bitmap_mode_clk;
wire        network_subtitle_bitmap_bank_clk;
wire [8:0]  network_bitmap_read_address_video;
wire [15:0] network_bitmap_read_data_video;
wire [7:0]  network_packet_count_clk;
wire        touch_debug_toggle_clk;
wire        touch_boot_toggle_clk;
wire        touch_boot_target_video_clk;
wire        boot_quiesce;
wire        source_quiesced;
reg [2:0]   touch_manual_prev_sync;
reg [2:0]   touch_manual_next_sync;
reg [2:0]   touch_auto_start_sync;
reg [2:0]   touch_auto_stop_sync;
reg [2:0]   touch_brightness_sync;
reg [2:0]   touch_contrast_sync;
reg [2:0]   touch_volume_sync;
reg [2:0]   touch_transition_mode_sync;
reg [2:0]   touch_interval_sync;
reg [2:0]   touch_subtitle_commit_sync;
reg [2:0]   network_subtitle_commit_sync;
reg [6:0]   touch_brightness_value_sync0;
reg [6:0]   touch_brightness_value_sync1;
reg [6:0]   touch_contrast_value_sync0;
reg [6:0]   touch_contrast_value_sync1;
reg [6:0]   touch_volume_value_sync0;
reg [6:0]   touch_volume_value_sync1;
reg [6:0]   audio_volume_level;
reg         touch_manual_note_enable_sync0;
reg         touch_manual_note_enable_sync1;
reg         touch_manual_note_gate_sync0;
reg         touch_manual_note_gate_sync1;
reg [2:0]   touch_manual_note_index_sync0;
reg [2:0]   touch_manual_note_index_sync1;
reg [2:0]   touch_transition_mode_value_sync0;
reg [2:0]   touch_transition_mode_value_sync1;
reg [3:0]   touch_interval_value_sync0;
reg [3:0]   touch_interval_value_sync1;
reg [255:0] touch_subtitle_text_sync0;
reg [255:0] touch_subtitle_text_sync1;
reg [5:0]   touch_subtitle_length_sync0;
reg [5:0]   touch_subtitle_length_sync1;
reg [2:0]   touch_subtitle_color_sync0;
reg [2:0]   touch_subtitle_color_sync1;
reg [255:0] network_subtitle_text_sync0;
reg [255:0] network_subtitle_text_sync1;
reg [5:0]   network_subtitle_length_sync0;
reg [5:0]   network_subtitle_length_sync1;
reg [2:0]   network_subtitle_color_sync0;
reg [2:0]   network_subtitle_color_sync1;
reg         network_subtitle_bitmap_mode_sync0;
reg         network_subtitle_bitmap_mode_sync1;
reg         network_subtitle_bitmap_bank_sync0;
reg         network_subtitle_bitmap_bank_sync1;
reg [7:0]   network_packet_count_sync0;
reg [7:0]   network_packet_count_sync1;
reg [2:0]   transition_mode_level;
wire        touch_manual_prev_video_event;
wire        touch_manual_next_video_event;
wire        touch_auto_start_video_event;
wire        touch_auto_stop_video_event;
wire        touch_brightness_video_event;
wire        touch_contrast_video_event;
wire        touch_volume_video_event;
wire        touch_transition_mode_video_event;
wire        touch_interval_video_event;
wire        touch_subtitle_commit_video_event;
wire        network_subtitle_commit_video_event;
wire        subtitle_commit_video_event;
wire [255:0] subtitle_text_video;
wire [5:0]   subtitle_length_video;
wire [2:0]   subtitle_color_video;
wire         subtitle_bitmap_mode_video;
// These values are produced by the TF reader in sd_card_clk.  Synchronize
// them before the video timing and SDRAM read path consume them so a buffer
// commit cannot be observed halfway through a frame request.
reg [1:0]   disp_buf_idx_video_sync0;
reg [1:0]   disp_buf_idx_video_sync1;
reg [3:0]   frame_image_index_video_sync0;
reg [3:0]   frame_image_index_video_sync1;
reg         frame_auto_play_video_sync0;
reg         frame_auto_play_video_sync1;
reg [3:0]   frame_auto_interval_video_sync0;
reg [3:0]   frame_auto_interval_video_sync1;
reg         display_valid_video_sync0;
reg         display_valid_video_sync1;
reg [3:0]   state_code_video_sync0;
reg [3:0]   state_code_video_sync1;
reg [3:0]   state_code_video_stable;
reg [1:0]   reservoir_level_gray_video_sync0;
reg [1:0]   reservoir_level_gray_video_sync1;
wire [1:0]  reservoir_level_video;
reg         video_read_req_d;
reg [1:0]   front_buf_video;
reg [1:0]   front_buf_pending_video;
reg [2:0]   front_buf_guard_count;
reg [1:0]   front_buf_sd_sync0;
reg [1:0]   front_buf_sd_sync1;
wire        frame_switch_ready;

assign reservoir_level_video = {
    reservoir_level_gray_video_sync1[1],
    reservoir_level_gray_video_sync1[1] ^
        reservoir_level_gray_video_sync1[0]
};

// Streaming frames arrive at 30 fps. Switch at the first safe HDMI frame
// boundary so the TF side can immediately begin refilling the released bank.
localparam [2:0] FRONT_SWITCH_GUARD_FRAMES = 3'd0;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;

// HDMI 1.4b 相关
wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;
wire        audio_valid;
wire        pcm_write_en;
wire [11:0] pcm_write_addr;
wire [15:0] pcm_write_data;
wire        pcm_frame_done_toggle;
wire [2:0]  pcm_fifo_head_gray;
wire [2:0]  pcm_display_sequence_gray;
wire        pcm_fifo_write_ready;
wire        pcm_fifo_frame_ready;
wire        pcm_fifo_clear;
wire        pcm_fifo_commit;
wire        pcm_fifo_abort;
wire        pcm_manual_seek_toggle;
wire [23:0] audio_left_data;
wire [23:0] audio_right_data;
wire [2:0]  audio_active_note_index;
wire        audio_active_note_gate;
wire        acr_valid;
wire [19:0] acr_cts;
wire [19:0] acr_n;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// 统一复位：TF 图像链路 + HDMI 链路
wire sys_pll_lock;
wire video_pll_lock;
wire rst_all;
wire rst_ext_mem;

reg [19:0] rst_cnt = 20'd0;
reg rst_all_reg = 1'b1;
reg [1:0] rst_ext_mem_sync = 2'b11;

always @(posedge clk) begin
    if (!rst_all_reg) begin
        // 一旦复位释放，忽略后续微小的 PLL 抖动，防止系统在使用时随机复位
        rst_all_reg <= 1'b0;
    end else if (sys_pll_lock && video_pll_lock) begin
        // 等待 PLL 连续稳定 20ms @ 50MHz
        if (rst_cnt < 20'd1_000_000) begin
            rst_cnt <= rst_cnt + 1'b1;
            rst_all_reg <= 1'b1;
        end else begin
            rst_all_reg <= 1'b0;
        end
    end else begin
        rst_cnt <= 20'd0;
        rst_all_reg <= 1'b1;
    end
end

assign rst_all = rst_all_reg;
assign seg_scan_rst_n = ~rst_all;

// Local/video image B returns to the primary network image at Flash 0x000000
// when physical K3 and K4 are held together for about two seconds.
multiboot_hold_trigger #(
    .TARGET_ADDR (8'h00),
    .CURRENT_VIDEO (1'b1)
) multiboot_hold_trigger_m0 (
    .clk    (clk),
    .rst    (rst_all),
    .key3_n (key3),
    .key4_n (key4),
    .request_toggle(touch_boot_toggle_clk),
    .request_video(touch_boot_target_video_clk),
    .source_quiet(source_quiesced),
    .quiesce(boot_quiesce)
);

// The TJC screen sends one fixed frame per button click. The receiver runs
// from the board clock; these toggles are synchronized into video_clk before
// entering the existing key-priority logic.
wire showcase_compare_clk;
wire [7:0] showcase_position_clk;
wire [1:0] showcase_style_clk;
reg showcase_compare_sync0, showcase_compare_sync1;
reg [7:0] showcase_position_sync0, showcase_position_sync1;
reg [1:0] showcase_style_sync0, showcase_style_sync1;
// UART settings remain stable for thousands of pixel clocks between commands.
// The rendering module commits the synchronized values only in vertical blank.
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        showcase_compare_sync0 <= 0; showcase_compare_sync1 <= 0;
        showcase_position_sync0 <= 80; showcase_position_sync1 <= 80;
        showcase_style_sync0 <= 0; showcase_style_sync1 <= 0;
    end else begin
        showcase_compare_sync0 <= showcase_compare_clk;
        showcase_compare_sync1 <= showcase_compare_sync0;
        showcase_position_sync0 <= showcase_position_clk;
        showcase_position_sync1 <= showcase_position_sync0;
        showcase_style_sync0 <= showcase_style_clk;
        showcase_style_sync1 <= showcase_style_sync0;
    end
end

tjc_uart_rx #(
    .CLK_FREQ_HZ (50_000_000),
    .BAUD_RATE   (115_200)
) tjc_uart_rx_m0(
    .clk           (clk),
    .rst           (rst_all),
    .uart_rx       (touch_uart_rx),
    .manual_prev_toggle (touch_manual_prev_toggle_clk),
    .manual_next_toggle (touch_manual_next_toggle_clk),
    .auto_start_toggle  (touch_auto_start_toggle_clk),
    .auto_stop_toggle   (touch_auto_stop_toggle_clk),
    .brightness_toggle  (touch_brightness_toggle_clk),
    .contrast_toggle    (touch_contrast_toggle_clk),
    .volume_toggle      (touch_volume_toggle_clk),
    .brightness_value   (touch_brightness_value_clk),
    .contrast_value     (touch_contrast_value_clk),
    .volume_value       (touch_volume_value_clk),
    .manual_note_enable (touch_manual_note_enable_clk),
    .manual_note_gate   (touch_manual_note_gate_clk),
    .manual_note_index  (touch_manual_note_index_clk),
    .compare_enable(showcase_compare_clk),
    .compare_position(showcase_position_clk),
    .spectrum_style(showcase_style_clk),
    .transition_mode_toggle(touch_transition_mode_toggle_clk),
    .transition_mode_value (touch_transition_mode_value_clk),
    .interval_toggle       (touch_interval_toggle_clk),
    .interval_value        (touch_interval_value_clk),
    .subtitle_commit_toggle(touch_subtitle_commit_toggle_clk),
    .subtitle_text         (touch_subtitle_text_clk),
    .subtitle_length       (touch_subtitle_length_clk),
    .subtitle_color        (touch_subtitle_color_clk),
    .debug_toggle       (touch_debug_toggle_clk),
    .boot_request_toggle(touch_boot_toggle_clk),
    .boot_target_video(touch_boot_target_video_clk)
);

// Official HX4S20 RTL8211E/TEMAC/UDP receive chain.  The fixed endpoint is
// 192.168.240.1:5000; each non-empty packet replaces the scrolling subtitle.
generate
    if (ENABLE_NETWORK) begin : gen_network_enabled
        udp_subtitle_network #(
            .LOCAL_IP_ADDRESS  (32'hc0a8f001),
            .LOCAL_UDP_PORT    (16'd5000),
            .LOCAL_MAC_ADDRESS (48'h02123456789a)
        ) udp_subtitle_network_m0 (
            .clk_50                 (clk),
            .reset                  (rst_all),
            .phy_rgmii_rx_clk       (phy1_rgmii_rx_clk),
            .phy_rgmii_rx_ctl       (phy1_rgmii_rx_ctl),
            .phy_rgmii_rx_data      (phy1_rgmii_rx_data),
            .phy_rgmii_tx_clk       (phy1_rgmii_tx_clk),
            .phy_rgmii_tx_ctl       (phy1_rgmii_tx_ctl),
            .phy_rgmii_tx_data      (phy1_rgmii_tx_data),
            .network_ready          (network_ready),
            .subtitle_text          (network_subtitle_text_clk),
            .subtitle_length        (network_subtitle_length_clk),
            .subtitle_color         (network_subtitle_color_clk),
            .subtitle_bitmap_mode   (network_subtitle_bitmap_mode_clk),
            .subtitle_bitmap_bank   (network_subtitle_bitmap_bank_clk),
            .subtitle_commit_toggle (network_subtitle_commit_toggle_clk),
            .packet_count           (network_packet_count_clk),
            .bitmap_read_bank       (network_subtitle_bitmap_bank_sync1),
            .bitmap_read_clk        (video_clk),
            .bitmap_read_address    (network_bitmap_read_address_video),
            .bitmap_read_data       (network_bitmap_read_data_video)
        );
    end else begin : gen_network_disabled
        assign phy1_rgmii_tx_clk                 = 1'b0;
        assign phy1_rgmii_tx_ctl                 = 1'b0;
        assign phy1_rgmii_tx_data                = 4'b0000;
        assign network_ready                     = 1'b0;
        assign network_subtitle_text_clk         = 256'd0;
        assign network_subtitle_length_clk       = 6'd0;
        assign network_subtitle_color_clk        = 3'd0;
        assign network_subtitle_bitmap_mode_clk  = 1'b0;
        assign network_subtitle_bitmap_bank_clk  = 1'b0;
        assign network_subtitle_commit_toggle_clk = 1'b0;
        assign network_packet_count_clk          = 8'd0;
        assign network_bitmap_read_data_video    = 16'd0;
    end
endgenerate

assign touch_manual_prev_video_event = touch_manual_prev_sync[2] ^ touch_manual_prev_sync[1];
assign touch_manual_next_video_event = touch_manual_next_sync[2] ^ touch_manual_next_sync[1];
assign touch_auto_start_video_event  = touch_auto_start_sync[2] ^ touch_auto_start_sync[1];
assign touch_auto_stop_video_event   = touch_auto_stop_sync[2] ^ touch_auto_stop_sync[1];
assign touch_brightness_video_event  = touch_brightness_sync[2] ^ touch_brightness_sync[1];
assign touch_contrast_video_event    = touch_contrast_sync[2] ^ touch_contrast_sync[1];
assign touch_volume_video_event      = touch_volume_sync[2] ^ touch_volume_sync[1];
assign touch_transition_mode_video_event =
    touch_transition_mode_sync[2] ^ touch_transition_mode_sync[1];
assign touch_interval_video_event =
    touch_interval_sync[2] ^ touch_interval_sync[1];
assign touch_subtitle_commit_video_event =
    touch_subtitle_commit_sync[2] ^ touch_subtitle_commit_sync[1];
assign network_subtitle_commit_video_event =
    network_subtitle_commit_sync[2] ^ network_subtitle_commit_sync[1];
assign subtitle_commit_video_event = touch_subtitle_commit_video_event |
                                     network_subtitle_commit_video_event;
assign subtitle_text_video = network_subtitle_commit_video_event ?
                             network_subtitle_text_sync1 :
                             touch_subtitle_text_sync1;
assign subtitle_length_video = network_subtitle_commit_video_event ?
                               network_subtitle_length_sync1 :
                               touch_subtitle_length_sync1;
assign subtitle_color_video = network_subtitle_commit_video_event ?
                              network_subtitle_color_sync1 :
                              touch_subtitle_color_sync1;
assign subtitle_bitmap_mode_video = network_subtitle_commit_video_event ?
                                    network_subtitle_bitmap_mode_sync1 :
                                    1'b0;

always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        touch_manual_prev_sync      <= 3'b000;
        touch_manual_next_sync      <= 3'b000;
        touch_auto_start_sync       <= 3'b000;
        touch_auto_stop_sync        <= 3'b000;
        touch_brightness_sync       <= 3'b000;
        touch_contrast_sync         <= 3'b000;
        touch_volume_sync           <= 3'b000;
        touch_transition_mode_sync  <= 3'b000;
        touch_interval_sync         <= 3'b000;
        touch_subtitle_commit_sync  <= 3'b000;
        network_subtitle_commit_sync <= 3'b000;
        touch_brightness_value_sync0 <= 7'd50;
        touch_brightness_value_sync1 <= 7'd50;
        touch_contrast_value_sync0   <= 7'd50;
        touch_contrast_value_sync1   <= 7'd50;
        touch_volume_value_sync0     <= 7'd50;
        touch_volume_value_sync1     <= 7'd50;
        audio_volume_level           <= 7'd50;
        touch_manual_note_enable_sync0 <= 1'b0;
        touch_manual_note_enable_sync1 <= 1'b0;
        touch_manual_note_gate_sync0   <= 1'b1;
        touch_manual_note_gate_sync1   <= 1'b1;
        touch_manual_note_index_sync0  <= 3'd0;
        touch_manual_note_index_sync1  <= 3'd0;
        touch_transition_mode_value_sync0 <= 3'd0;
        touch_transition_mode_value_sync1 <= 3'd0;
        touch_interval_value_sync0 <= 4'd2;
        touch_interval_value_sync1 <= 4'd2;
        touch_subtitle_text_sync0   <= 256'd0;
        touch_subtitle_text_sync1   <= 256'd0;
        touch_subtitle_length_sync0 <= 6'd0;
        touch_subtitle_length_sync1 <= 6'd0;
        touch_subtitle_color_sync0  <= 3'd1;
        touch_subtitle_color_sync1  <= 3'd1;
        network_subtitle_text_sync0   <= 256'd0;
        network_subtitle_text_sync1   <= 256'd0;
        network_subtitle_length_sync0 <= 6'd0;
        network_subtitle_length_sync1 <= 6'd0;
        network_subtitle_color_sync0   <= 3'd2;
        network_subtitle_color_sync1   <= 3'd2;
        network_subtitle_bitmap_mode_sync0 <= 1'b0;
        network_subtitle_bitmap_mode_sync1 <= 1'b0;
        network_subtitle_bitmap_bank_sync0 <= 1'b0;
        network_subtitle_bitmap_bank_sync1 <= 1'b0;
        network_packet_count_sync0    <= 8'd0;
        network_packet_count_sync1    <= 8'd0;
        transition_mode_level          <= 3'd0;
    end else begin
        touch_manual_prev_sync <= {touch_manual_prev_sync[1:0],
                                   touch_manual_prev_toggle_clk};
        touch_manual_next_sync <= {touch_manual_next_sync[1:0],
                                   touch_manual_next_toggle_clk};
        touch_auto_start_sync  <= {touch_auto_start_sync[1:0],
                                   touch_auto_start_toggle_clk};
        touch_auto_stop_sync   <= {touch_auto_stop_sync[1:0],
                                   touch_auto_stop_toggle_clk};
        touch_brightness_sync  <= {touch_brightness_sync[1:0],
                                   touch_brightness_toggle_clk};
        touch_contrast_sync    <= {touch_contrast_sync[1:0],
                                   touch_contrast_toggle_clk};
        touch_volume_sync      <= {touch_volume_sync[1:0],
                                   touch_volume_toggle_clk};
        touch_transition_mode_sync <= {touch_transition_mode_sync[1:0],
                                       touch_transition_mode_toggle_clk};
        touch_interval_sync <= {touch_interval_sync[1:0],
                                touch_interval_toggle_clk};
        touch_subtitle_commit_sync <= {touch_subtitle_commit_sync[1:0],
                                       touch_subtitle_commit_toggle_clk};
        network_subtitle_commit_sync <= {
            network_subtitle_commit_sync[1:0],
            network_subtitle_commit_toggle_clk
        };
        touch_brightness_value_sync0 <= touch_brightness_value_clk;
        touch_brightness_value_sync1 <= touch_brightness_value_sync0;
        touch_contrast_value_sync0   <= touch_contrast_value_clk;
        touch_contrast_value_sync1   <= touch_contrast_value_sync0;
        touch_volume_value_sync0     <= touch_volume_value_clk;
        touch_volume_value_sync1     <= touch_volume_value_sync0;
        touch_manual_note_enable_sync0 <= touch_manual_note_enable_clk;
        touch_manual_note_enable_sync1 <= touch_manual_note_enable_sync0;
        touch_manual_note_gate_sync0   <= touch_manual_note_gate_clk;
        touch_manual_note_gate_sync1   <= touch_manual_note_gate_sync0;
        touch_manual_note_index_sync0  <= touch_manual_note_index_clk;
        touch_manual_note_index_sync1  <= touch_manual_note_index_sync0;
        touch_transition_mode_value_sync0 <= touch_transition_mode_value_clk;
        touch_transition_mode_value_sync1 <= touch_transition_mode_value_sync0;
        touch_interval_value_sync0 <= touch_interval_value_clk;
        touch_interval_value_sync1 <= touch_interval_value_sync0;
        // The UART-domain payload is held stable between commit toggles. Two
        // video-clock samples settle the bundled data before the toggle event
        // reaches touch_subtitle_commit_video_event.
        touch_subtitle_text_sync0   <= touch_subtitle_text_clk;
        touch_subtitle_text_sync1   <= touch_subtitle_text_sync0;
        touch_subtitle_length_sync0 <= touch_subtitle_length_clk;
        touch_subtitle_length_sync1 <= touch_subtitle_length_sync0;
        touch_subtitle_color_sync0  <= touch_subtitle_color_clk;
        touch_subtitle_color_sync1  <= touch_subtitle_color_sync0;
        // The UDP-domain payload remains stable until the next packet commit.
        // Sample the bundle twice before acting on its synchronized toggle.
        network_subtitle_text_sync0   <= network_subtitle_text_clk;
        network_subtitle_text_sync1   <= network_subtitle_text_sync0;
        network_subtitle_length_sync0 <= network_subtitle_length_clk;
        network_subtitle_length_sync1 <= network_subtitle_length_sync0;
        network_subtitle_color_sync0 <= network_subtitle_color_clk;
        network_subtitle_color_sync1 <= network_subtitle_color_sync0;
        network_subtitle_bitmap_mode_sync0 <=
            network_subtitle_bitmap_mode_clk;
        network_subtitle_bitmap_mode_sync1 <=
            network_subtitle_bitmap_mode_sync0;
        network_subtitle_bitmap_bank_sync0 <=
            network_subtitle_bitmap_bank_clk;
        network_subtitle_bitmap_bank_sync1 <=
            network_subtitle_bitmap_bank_sync0;
        network_packet_count_sync0    <= network_packet_count_clk;
        network_packet_count_sync1    <= network_packet_count_sync0;
        if (touch_volume_video_event)
            audio_volume_level <= (touch_volume_value_sync1 > 7'd100) ?
                                  7'd100 : touch_volume_value_sync1;
        if (touch_transition_mode_video_event)
            transition_mode_level <=
                touch_transition_mode_value_sync1;
    end
end

// 保持你原来的 TF / SDRAM / video 时钟
sys_pll sys_pll_m0(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (sys_pll_lock),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (video_pll_lock),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk)
);

// The SDRAM controller consumes reset as synchronous control data. Assert it
// asynchronously with the system reset, then release it on ext_mem_clk so the
// 50 MHz reset sequencer does not form a timed path into the memory domain.
always @(posedge ext_mem_clk or posedge rst_all) begin
    if (rst_all)
        rst_ext_mem_sync <= 2'b11;
    else
        rst_ext_mem_sync <= {rst_ext_mem_sync[0], 1'b0};
end

assign rst_ext_mem = rst_ext_mem_sync[1];

// write_req_ack is a level handshake generated in ext_mem_clk. Synchronize it
// before the TF/BMP state machine consumes it in sd_card_clk.
always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
        sd_card_write_req_ack_sync0 <= 1'b0;
        sd_card_write_req_ack_sync1 <= 1'b0;
    end else begin
        sd_card_write_req_ack_sync0 <= sd_card_write_req_ack_mem;
        sd_card_write_req_ack_sync1 <= sd_card_write_req_ack_sync0;
    end
end

assign sd_card_write_req_ack = sd_card_write_req_ack_sync1;

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or posedge rst_ext_mem) begin
    if (rst_ext_mem)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

// Convert the already debounced video-domain key events to toggles. The TF
// reader crosses these toggles into sd_card_clk, avoiding a second independent
// debounce decision in the SD path.
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        key_next_toggle_video <= 1'b0;
        key_prev_toggle_video <= 1'b0;
        key_auto_toggle_video <= 1'b0;
        touch_auto_start_toggle_video <= 1'b0;
        touch_auto_stop_toggle_video  <= 1'b0;
    end else begin
        if (key_next_video_event)
            key_next_toggle_video <= ~key_next_toggle_video;
        if (key_prev_video_event)
            key_prev_toggle_video <= ~key_prev_toggle_video;
        if (key_auto_video_event)
            key_auto_toggle_video <= ~key_auto_toggle_video;
        if (touch_auto_start_video_event)
            touch_auto_start_toggle_video <= ~touch_auto_start_toggle_video;
        if (touch_auto_stop_video_event)
            touch_auto_stop_toggle_video <= ~touch_auto_stop_toggle_video;
    end
end

always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        disp_buf_idx_video_sync0      <= 2'd0;
        disp_buf_idx_video_sync1      <= 2'd0;
        frame_image_index_video_sync0 <= 4'd0;
        frame_image_index_video_sync1 <= 4'd0;
        frame_auto_play_video_sync0   <= 1'b0;
        frame_auto_play_video_sync1   <= 1'b0;
        frame_auto_interval_video_sync0 <= 4'd2;
        frame_auto_interval_video_sync1 <= 4'd2;
        display_valid_video_sync0     <= 1'b0;
        display_valid_video_sync1     <= 1'b0;
        state_code_video_sync0         <= 4'd0;
        state_code_video_sync1         <= 4'd0;
        state_code_video_stable        <= 4'd0;
        reservoir_level_gray_video_sync0 <= 2'd0;
        reservoir_level_gray_video_sync1 <= 2'd0;
        video_read_req_d              <= 1'b0;
        front_buf_video               <= 2'd0;
        front_buf_pending_video       <= 2'd0;
        front_buf_guard_count         <= 3'd0;
    end else begin
        disp_buf_idx_video_sync0      <= disp_buf_idx;
        disp_buf_idx_video_sync1      <= disp_buf_idx_video_sync0;
        frame_image_index_video_sync0 <= frame_image_index;
        frame_image_index_video_sync1 <= frame_image_index_video_sync0;
        frame_auto_play_video_sync0   <= frame_auto_play;
        frame_auto_play_video_sync1   <= frame_auto_play_video_sync0;
        frame_auto_interval_video_sync0 <= frame_auto_interval_seconds;
        frame_auto_interval_video_sync1 <= frame_auto_interval_video_sync0;
        display_valid_video_sync0     <= display_valid;
        display_valid_video_sync1     <= display_valid_video_sync0;
        state_code_video_sync0         <= state_code;
        state_code_video_sync1         <= state_code_video_sync0;
        reservoir_level_gray_video_sync0 <= reservoir_level_gray;
        reservoir_level_gray_video_sync1 <=
            reservoir_level_gray_video_sync0;
        if (state_code_video_sync1 == state_code_video_sync0)
            state_code_video_stable <= state_code_video_sync1;
        video_read_req_d              <= video_read_req;

        // Keep the HDMI read address stable for complete frames. After a new
        // buffer commit, wait two vertical periods before switching. The TF
        // side can finish the next image while the current buffer is still
        // being scanned; the guard gives the SDRAM write/read FIFOs time to
        // settle without changing the active picture mid-frame.
        if (video_read_req && !video_read_req_d) begin
            if (!display_valid_video_sync1) begin
                front_buf_video         <= 2'd0;
                front_buf_pending_video <= 2'd0;
                front_buf_guard_count   <= 3'd0;
            end else if (disp_buf_idx_video_sync1 == front_buf_video) begin
                front_buf_pending_video <= disp_buf_idx_video_sync1;
                front_buf_guard_count   <= 3'd0;
            end else if (disp_buf_idx_video_sync1 != front_buf_pending_video) begin
                front_buf_pending_video <= disp_buf_idx_video_sync1;
                front_buf_guard_count   <= 3'd0;
            end else if ((front_buf_guard_count >= FRONT_SWITCH_GUARD_FRAMES) &&
                         frame_switch_ready) begin
                front_buf_video         <= front_buf_pending_video;
                front_buf_guard_count   <= 3'd0;
            end else if (front_buf_guard_count < FRONT_SWITCH_GUARD_FRAMES) begin
                front_buf_guard_count   <= front_buf_guard_count + 1'b1;
            end
        end
    end
end

always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
        front_buf_sd_sync0 <= 2'd0;
        front_buf_sd_sync1 <= 2'd0;
    end else begin
        front_buf_sd_sync0 <= front_buf_video;
        front_buf_sd_sync1 <= front_buf_sd_sync0;
    end
end

// ===================== 图像源与双缓冲 =====================
// Both branches use the same frame_read_write/SDRAM/HDMI path below. The
// switch is intentionally local so the TF branch remains available without
// adding external control pins.
generate
    if (NO_TF_MODE) begin : gen_rom_source
        rom_frame_source #(
            .CLK_FREQ_HZ  (100_000_000),
            .FRAME_WIDTH  (640),
            .FRAME_HEIGHT (480),
            .FRAME_PIXELS (FRAME_PIXELS)
        ) rom_frame_source_m0(
            .clk                 (sd_card_clk),
            .rst                 (rst_all),
            .mem_init_done       (Sdr_init_done),
            .key_next            (key1),
            .key_auto            (key2),
            .key_next_toggle    (key_next_toggle_video),
            .key_auto_toggle    (key_auto_toggle_video),
            .write_finish_toggle(frame_write_toggle_mem),
            .state_code          (state_code),
            .display_valid       (display_valid),
            .write_buf_idx       (write_buf_idx),
            .disp_buf_idx        (disp_buf_idx),
            .image_index_dbg     (frame_image_index),
            .auto_play_dbg       (frame_auto_play),
            .write_req           (sd_card_write_req),
            .write_req_ack       (sd_card_write_req_ack),
            .write_fifo_full     (sd_write_fifo_full),
            .write_en            (sd_card_write_en),
            .write_data          (sd_card_write_data)
        );

        assign frame_auto_interval_seconds = 4'd2;
        assign reservoir_level_gray = 2'd0;

        assign sd_ncs  = 1'b1;
        assign sd_dclk = 1'b0;
        assign sd_mosi = 1'b1;
    end else begin : gen_tf_source
        sd_card_bmp #(
            .CLK_FREQ_HZ       (100_000_000),
            .SCAN_START_SECTOR (32'd0),
            .SCAN_MAX_SECTOR   (32'd131071),
            .SCAN_TARGET_COUNT (5'd16),
            .SOURCE_WIDTH      (320),
            .SOURCE_HEIGHT     (240),
            .AUDIO_SAMPLES_PER_FRAME (1714),
            .AUDIO_FIFO_MODE (1)
        ) sd_card_bmp_m0(
            .clk               (sd_card_clk),
            .rst               (rst_all),
            .key_next          (key1),
            .key_auto          (key2),
            .key_next_toggle   (key_next_toggle_video),
            .key_prev_toggle   (key_prev_toggle_video),
            .key_auto_toggle   (key_auto_toggle_video),
            .touch_auto_start_toggle(touch_auto_start_toggle_video),
            .touch_auto_stop_toggle (touch_auto_stop_toggle_video),
            .quiesce (boot_quiesce),
            .quiesced (source_quiesced),
            .audio_frame_done_toggle(pcm_frame_done_toggle),
            .audio_fifo_head_gray(pcm_fifo_head_gray),
            .audio_fifo_write_ready(pcm_fifo_write_ready),
            .audio_fifo_frame_ready(pcm_fifo_frame_ready),
            .audio_fifo_clear(pcm_fifo_clear),
            .audio_fifo_commit(pcm_fifo_commit),
            .audio_fifo_abort(pcm_fifo_abort),
            .audio_display_sequence_gray(pcm_display_sequence_gray),
            .audio_manual_seek_toggle(pcm_manual_seek_toggle),
            .audio_write_en(pcm_write_en),
            .audio_write_addr(pcm_write_addr),
            .audio_write_data(pcm_write_data),
            .interval_toggle   (touch_interval_toggle_clk),
            .interval_value    (touch_interval_value_clk),
            .state_code        (state_code),
            .image_index_dbg   (frame_image_index),
            .auto_play_dbg     (frame_auto_play),
            .bmp_width         (16'd640),
            .bmp_height        (16'd480),
            .display_valid     (display_valid),

            .write_finish_toggle(frame_write_toggle_mem),
            .front_buf_idx     (front_buf_sd_sync1),
            .write_buf_idx     (write_buf_idx),
            .disp_buf_idx      (disp_buf_idx),
            .interval_seconds_dbg(frame_auto_interval_seconds),
            .reservoir_level_gray_dbg(reservoir_level_gray),

            .write_req         (sd_card_write_req),
            .write_req_ack     (sd_card_write_req_ack),
            .write_fifo_full   (sd_write_fifo_full),
            .write_en          (sd_card_write_en),
            .write_data        (sd_card_write_data),
            .SD_nCS            (sd_ncs),
            .SD_DCLK           (sd_dclk),
            .SD_MOSI           (sd_mosi),
            .SD_MISO           (sd_miso)
        );
    end
endgenerate

seg_decoder seg_decoder_m0(
    .bin_data          (state_code),
    .seg_data          (seg_data_0)
);

// Mapping diagnostic: the physical keys now follow the software key numbers.
seg_decoder seg_decoder_key1(
    .bin_data          (4'd1),
    .seg_data          (seg_data_key1)
);

seg_decoder seg_decoder_key2(
    .bin_data          (4'd2),
    .seg_data          (seg_data_key2)
);

seg_decoder seg_decoder_key3(
    .bin_data          (4'd3),
    .seg_data          (seg_data_key3)
);

seg_decoder seg_decoder_key4(
    .bin_data          (4'd4),
    .seg_data          (seg_data_key4)
);

seg_decoder seg_decoder_last_key(
    .bin_data          (direct_last_key_code),
    .seg_data          (seg_data_last_key)
);

seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (seg_scan_rst_n),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0        ({1'b1,seg_data_key1}),
    .seg_data_1        ({1'b1,seg_data_key2}),
    .seg_data_2        ({1'b1,seg_data_key3}),
    .seg_data_3        ({1'b1,seg_data_key4}),
    .seg_data_4        (direct_last_key_code == 4'd0 ? 8'hff : {1'b1,seg_data_last_key}),
    .seg_data_5        ({1'b1,seg_data_0})
);

// ===================== 原图像时序与帧缓存 =====================
video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

video_delay video_delay_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_en           (video_read_en),
    .read_ready        (video_read_ready),
    .read_data         (video_read_data[31:8]),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .vout_data         (vout_data_raw)
);

// Before the first SDRAM frame commits, keep the HDMI path visibly testable
// with the official color-bar generator instead of outputting black.
color_bar diag_color_bar(
    .clk   (video_clk),
    .rst   (rst_all),
    .hs    (),
    .vs    (),
    .de    (),
    .rgb_r (diag_rgb_r),
    .rgb_g (diag_rgb_g),
    .rgb_b (diag_rgb_b)
);

video_direct_test #(
    .PCM_SPECTRUM (1)
) direct_test_source(
    .clk       (video_clk),
    .rst       (rst_all),
    .hs        (hs),
    .vs        (vs),
    .de        (de),
    .key_next  (key1),
    .key_auto  (key2),
    .key3      (key3),
    .key4      (key4),
    .touch_prev_event       (touch_manual_prev_video_event),
    .touch_next_event       (touch_manual_next_video_event),
    .touch_auto_start_event (touch_auto_start_video_event),
    .touch_auto_stop_event  (touch_auto_stop_video_event),
    .touch_brightness_event (touch_brightness_video_event),
    .touch_contrast_event   (touch_contrast_video_event),
    .touch_interval_event   (touch_interval_video_event),
    .touch_subtitle_commit_event(subtitle_commit_video_event),
    .touch_brightness_value (touch_brightness_value_sync1),
    .touch_contrast_value   (touch_contrast_value_sync1),
    .touch_interval_value   (touch_interval_value_sync1),
    .touch_subtitle_text    (subtitle_text_video),
    .touch_subtitle_length  (subtitle_length_video),
    .touch_subtitle_color   (subtitle_color_video),
    .touch_subtitle_bitmap_mode(subtitle_bitmap_mode_video),
    .touch_subtitle_bitmap_row(network_bitmap_read_data_video),
    .touch_subtitle_bitmap_address(network_bitmap_read_address_video),
    .audio_volume           (audio_volume_level),
    .audio_manual_note_enable(touch_manual_note_enable_sync1),
    .audio_manual_note_gate  (touch_manual_note_gate_sync1),
    .audio_manual_note_index (touch_manual_note_index_sync1),
    // A slideshow transition takes many HDMI frames and cannot follow a
    // 30 fps stream. Direct mode still commits only at the protected frame
    // boundary, but it never fades the continuously changing video to black.
    .compare_enable(showcase_compare_sync1),
    .compare_position(showcase_position_sync1),
    .spectrum_style(showcase_style_sync1),
    .transition_mode        (3'd4),
    .frame_state(state_code_video_stable),
    .frame_mode(frame_image_index_video_sync1),
    .frame_auto(frame_auto_play_video_sync1),
    .frame_display_valid(display_valid_video_sync1),
    .frame_interval_seconds(frame_auto_interval_video_sync1),
    .frame_buffer(front_buf_video),
    .frame_buffer_request(disp_buf_idx_video_sync1),
    .reservoir_level(reservoir_level_video),
    .base_rgb  (overlay_base_rgb),
    .use_base  (NO_TF_MODE ? (NO_TF_SDRAM_OUTPUT && display_valid) : 1'b1),
    .audio_sample_valid (audio_valid),
    .audio_sample       (audio_left_data),
    .audio_note_index   (audio_active_note_index),
    .audio_note_active  (audio_active_note_gate),
    .rgb       (direct_test_rgb),
    .last_key_code (direct_last_key_code),
    .key_next_event (key_next_video_event),
    .key_prev_event (key_prev_video_event),
    .key_auto_event (key_auto_video_event),
    .frame_switch_ready(frame_switch_ready)
);

assign overlay_base_rgb = (!NO_TF_MODE && !display_valid_video_sync1) ?
                          {diag_rgb_r, diag_rgb_g, diag_rgb_b} : vout_data_raw;

wire screen_vs, screen_de;
startup_status_screen #(.CURRENT_VIDEO(1'b1)) startup_status_screen_m0 (
    .clk(video_clk), .rst(rst_all), .vs(vs), .de(de),
    .source_rgb(direct_test_rgb),
    .media_ready(display_valid_video_sync1),
    .switch_pending(boot_quiesce), .source_state(state_code_video_stable),
    .out_vs(screen_vs), .out_de(screen_de), .out_rgb(vout_data)
);

// Before the three-frame prefill completes, the overlay uses the diagnostic
// pattern and no SDRAM picture is consumed. Keep the read request pending at
// the timing generator and release it only after a complete display frame is
// available; this gives initial frame writes uncontended SDRAM bandwidth.
assign video_sdram_read_req = video_read_req && display_valid_video_sync1;

frame_read_write #(
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (480)
) frame_read_write_m0(
    .mem_clk           (ext_mem_clk),
    .rst               (rst_all),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .display_active    (display_valid),

    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (video_sdram_read_req),
    .read_req_ack      (video_read_req_ack),
    .read_finish       (),
    .read_addr_0       (BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       (BUF2_ADDR),
    .read_addr_3       (BUF3_ADDR),
    .read_addr_index   (front_buf_video),
    .read_len          (FRAME_PIXELS),
    .read_en           (video_read_en),
    .read_data         (video_read_data),
    .read_fifo_empty   (video_read_fifo_empty),
    .read_stream_ready (video_read_ready),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack_mem),
    .write_finish      (frame_write_finish),
    .write_fifo_full   (sd_write_fifo_full),
    .write_addr_0      (BUF0_ADDR),
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      (BUF2_ADDR),
    .write_addr_3      (BUF3_ADDR),
    .write_addr_index  (write_buf_idx),
    .write_len         (FRAME_PIXELS),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data)
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_ext_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_all),
    .I_vs          (screen_vs),
    .I_de          (screen_de),
    .I_rgb         (vout_data),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (rst_all),
    .O_pulse (edid_trig)
);

// Official 48 kHz PCM test tone.  It runs in the pixel clock domain and
// feeds the HDMI packetizer directly; the video/SDRAM path is unchanged.
// 24000/1714 = 14.0023337 fps; media uses this exact rational cadence.
// PCM stays 24 kHz mono -> 48 kHz HDMI; no sound speed/pitch change.
pcm_frame_fifo_audio #(.SAMPLES_PER_FRAME(1714)) u_pcm_video_audio (
    .write_clk(sd_card_clk), .write_en(pcm_write_en),
    .write_addr(pcm_write_addr),
    .write_data(pcm_write_data),
    .write_commit(pcm_fifo_commit), .write_abort(pcm_fifo_abort),
    .write_ready(pcm_fifo_write_ready), .frame_ready(pcm_fifo_frame_ready),
    .clk(video_clk), .rst(rst_all | pcm_fifo_clear),
    .display_valid(display_valid_video_sync1),
    .play(frame_auto_play_video_sync1),
    .display_sequence_gray(pcm_display_sequence_gray),
    .manual_seek_toggle(pcm_manual_seek_toggle),
    .read_sequence_gray(pcm_fifo_head_gray),
    .volume(audio_volume_level),
    .frame_done_toggle(pcm_frame_done_toggle),
    .audio_valid(audio_valid),
    .audio_left(audio_left_data), .audio_right(audio_right_data)
);
assign audio_active_note_index = 3'd0;
assign audio_active_note_gate = frame_auto_play_video_sync1;

audio_arc_calculate #(
    .ACR_N             (20'd6144)
) u_audio_arc (
    .I_clk          (video_clk),
    .I_rst          (rst_all),
    .I_audio_valid  (audio_valid),
    .O_acr_valid    (acr_valid),
    .O_acr_cts      (acr_cts),
    .O_acr_n        (acr_n)
);

// ===================== HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_all),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid),
    .I_audio_left_data  (audio_left_data),
    .I_audio_right_data (audio_right_data),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_all),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule

// Four audio banks use the same ownership as the four video banks. Source
// samples are 24 kHz signed mono, each emitted twice at HDMI's 48 kHz rate.
module pcm_video_audio #(
    parameter integer CLOCK_HZ = 25_000_000,
    parameter integer OUTPUT_RATE = 48_000,
    parameter integer SAMPLES_PER_FRAME = 3000
)(
    input write_clk, input write_en,
    input [1:0] write_bank, input [11:0] write_addr,
    input [15:0] write_data,
    input clk, input rst, input display_valid, input play,
    input [1:0] bank, input [6:0] volume,
    output reg frame_done_toggle,
    output reg audio_valid,
    output reg [23:0] audio_left,
    output reg [23:0] audio_right
);
reg [15:0] samples [0:12287];
wire [13:0] wr_address = {write_bank, 11'd0} +
                          {write_bank, 10'd0} + write_addr;
reg [11:0] sample_index;
reg [1:0] current_bank;
wire [13:0] rd_address = {current_bank, 11'd0} +
                          {current_bank, 10'd0} + sample_index;
reg signed [15:0] ram_sample;
always @(posedge write_clk) begin
    if (write_en && write_addr < SAMPLES_PER_FRAME)
        samples[wr_address] <= write_data;
end
always @(posedge clk) ram_sample <= samples[rd_address];

reg [31:0] sample_acc;
wire [32:0] acc_next = {1'b0, sample_acc} + OUTPUT_RATE;
wire sample_tick = acc_next >= CLOCK_HZ;
reg repeated_sample;
reg armed;
reg finished;
reg [2:0] settle;
reg signed [23:0] volume_product;
reg product_valid;
reg signed [31:0] scaled_product;
reg scaled_valid;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        sample_acc <= 32'd0;
        sample_index <= 12'd0;
        current_bank <= 2'd0;
        repeated_sample <= 1'b0;
        armed <= 1'b0;
        finished <= 1'b0;
        settle <= 3'd0;
        frame_done_toggle <= 1'b0;
        volume_product <= 24'sd0;
        product_valid <= 1'b0;
        scaled_product <= 32'sd0;
        scaled_valid <= 1'b0;
        audio_valid <= 1'b0;
        audio_left <= 24'd0;
        audio_right <= 24'd0;
    end else begin
        sample_acc <= sample_tick ? acc_next - CLOCK_HZ : acc_next[31:0];
        product_valid <= sample_tick;
        scaled_valid <= product_valid;
        audio_valid <= scaled_valid;
        if (product_valid)
            // 655/65536 approximates 1/100 from below, avoiding overflow
            // at full-scale PCM and keeping division off the audio path.
            scaled_product <= volume_product * 32'sd655;
        if (scaled_valid) begin
            audio_left <= {scaled_product[31:16], 8'd0};
            audio_right <= {scaled_product[31:16], 8'd0};
        end
        if (!display_valid) begin
            armed <= 1'b0;
            finished <= 1'b0;
            sample_index <= 12'd0;
            repeated_sample <= 1'b0;
            if (sample_tick) volume_product <= 24'sd0;
        end else if (!armed || bank != current_bank) begin
            current_bank <= bank;
            sample_index <= 12'd0;
            repeated_sample <= 1'b0;
            finished <= 1'b0;
            armed <= 1'b1;
            settle <= 3'd4;
            if (sample_tick) volume_product <= 24'sd0;
        end else begin
            if (settle != 0) settle <= settle - 1'b1;
            if (sample_tick) begin
                if (play && !finished && settle == 0) begin
                    volume_product <= ram_sample * $signed({1'b0, volume});
                    if (!repeated_sample) repeated_sample <= 1'b1;
                    else begin
                        repeated_sample <= 1'b0;
                        if (sample_index == SAMPLES_PER_FRAME-1) begin
                            finished <= 1'b1;
                            frame_done_toggle <= ~frame_done_toggle;
                        end else sample_index <= sample_index + 1'b1;
                    end
                end else volume_product <= 24'sd0;
            end
        end
    end
end
endmodule

// Atomic, asynchronous FOUR-FRAME audio FIFO. The 1714 samples in each
// committed frame occupy a 2048-word slot, not a video bank's 3072-word stride.
// Only the registered Gray frame pointers cross domains; sample RAM contents
// remain immutable until the consumer releases the complete slot. An aborted
// or malformed frame is never published. Source is still 24k mono -> HDMI48k.
module pcm_frame_fifo_audio #(
    parameter integer CLOCK_HZ = 25_000_000,
    parameter integer OUTPUT_RATE = 48_000,
    parameter integer SAMPLES_PER_FRAME = 1714,
    parameter integer SLOT_ADDR_BITS = 11
)(
    input write_clk, input write_en,
    input [11:0] write_addr, input [15:0] write_data,
    input write_commit, input write_abort,
    output write_ready, output frame_ready,
    input clk, input rst, input display_valid, input play,
    input [2:0] display_sequence_gray,
    input manual_seek_toggle,
    output reg [2:0] read_sequence_gray,
    input [6:0] volume,
    output reg frame_done_toggle,
    output reg audio_valid,
    output reg [23:0] audio_left, output reg [23:0] audio_right
);
localparam integer MEMORY_WORDS = 1 << (SLOT_ADDR_BITS + 2);
reg [15:0] samples [0:MEMORY_WORDS-1];
reg [1:0] write_reset, read_reset;
always @(posedge write_clk or posedge rst) begin
    if (rst) write_reset <= 2'b11;
    else write_reset <= {write_reset[0], 1'b0};
end
always @(posedge clk or posedge rst) begin
    if (rst) read_reset <= 2'b11;
    else read_reset <= {read_reset[0], 1'b0};
end
reg [2:0] write_sequence;
reg [2:0] write_sequence_gray;
reg [2:0] read_sequence;
reg [2:0] read_gray_w0, read_gray_w1;
reg [2:0] write_gray_r0, write_gray_r1;
reg [2:0] display_gray_r0, display_gray_r1;
reg [2:0] manual_seek_sync;
reg seek_pending;
reg [2:0] seek_target;
reg [11:0] staged_samples;
reg write_fault;
wire [2:0] read_sequence_w = {read_gray_w1[2],
    read_gray_w1[2] ^ read_gray_w1[1],
    read_gray_w1[2] ^ read_gray_w1[1] ^ read_gray_w1[0]};
wire [2:0] frames_used = write_sequence - read_sequence_w;
wire frame_available = write_gray_r1 != read_sequence_gray;
wire [2:0] synchronized_display_sequence = {display_gray_r1[2],
    display_gray_r1[2] ^ display_gray_r1[1],
    display_gray_r1[2] ^ display_gray_r1[1] ^ display_gray_r1[0]};
wire [2:0] seek_distance = seek_target - read_sequence;
wire manual_seek_event = manual_seek_sync[2] ^ manual_seek_sync[1];
// A manual video step can request up to three committed future frames. A
// display request behind the independently playing audio NEVER rewinds it.
wire seek_forward = seek_pending && frame_available && (seek_distance != 3'd0) &&
                    !seek_distance[2];
wire [2:0] next_write_sequence = write_sequence + 3'd1;
wire [2:0] next_read_sequence = read_sequence + 3'd1;
assign write_ready = !write_reset[1] && (frames_used < 3'd4);
assign frame_ready = write_ready && !write_fault &&
                     (staged_samples == SAMPLES_PER_FRAME);

wire [SLOT_ADDR_BITS+1:0] ram_write_address =
    {write_sequence[1:0], write_addr[SLOT_ADDR_BITS-1:0]};
reg [11:0] sample_index;
wire [SLOT_ADDR_BITS+1:0] ram_read_address =
    {read_sequence[1:0], sample_index[SLOT_ADDR_BITS-1:0]};
reg signed [15:0] ram_sample;
always @(posedge write_clk) begin
    if (write_ready && write_en && !write_abort && !write_commit &&
        write_addr < SAMPLES_PER_FRAME && write_addr == staged_samples)
        samples[ram_write_address] <= write_data;
end
always @(posedge clk) ram_sample <= samples[ram_read_address];

always @(posedge write_clk or posedge rst) begin
    if (rst) begin
        write_sequence <= 3'd0;
        write_sequence_gray <= 3'd0;
        read_gray_w0 <= 3'd0; read_gray_w1 <= 3'd0;
        staged_samples <= 12'd0; write_fault <= 1'b0;
    end else if (write_reset[1]) begin
        write_sequence <= 3'd0;
        write_sequence_gray <= 3'd0;
        read_gray_w0 <= 3'd0; read_gray_w1 <= 3'd0;
        staged_samples <= 12'd0; write_fault <= 1'b0;
    end else begin
        read_gray_w0 <= read_sequence_gray;
        read_gray_w1 <= read_gray_w0;
        if (write_abort) begin
            staged_samples <= 12'd0;
            write_fault <= 1'b0;
        end else if (write_commit) begin
            if (frame_ready) begin
                write_sequence <= next_write_sequence;
                write_sequence_gray <= (next_write_sequence >> 1) ^ next_write_sequence;
                staged_samples <= 12'd0;
            end else write_fault <= 1'b1;
        end else if (write_en) begin
            if (!write_ready || write_addr >= SAMPLES_PER_FRAME ||
                write_addr != staged_samples)
                write_fault <= 1'b1;
            else staged_samples <= staged_samples + 12'd1;
        end
    end
end

reg [31:0] sample_acc;
wire [32:0] acc_next = {1'b0, sample_acc} + OUTPUT_RATE;
wire sample_tick = acc_next >= CLOCK_HZ;
reg repeated_sample;
reg [2:0] settle;
reg signed [23:0] volume_product;
reg product_valid;
reg signed [31:0] scaled_product;
reg scaled_valid;
// Simulation-visible diagnostics. Unused hardware counters are optimized out.
reg [31:0] underrun_samples;
reg [15:0] underrun_events;
reg starving;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        read_sequence <= 3'd0; read_sequence_gray <= 3'd0;
        write_gray_r0 <= 3'd0; write_gray_r1 <= 3'd0;
        display_gray_r0 <= 3'd0; display_gray_r1 <= 3'd0;
        manual_seek_sync <= 3'd0; seek_pending <= 1'b0; seek_target <= 3'd0;
        sample_index <= 12'd0; repeated_sample <= 1'b0;
        settle <= 3'd4; sample_acc <= 32'd0;
        volume_product <= 24'sd0; product_valid <= 1'b0;
        scaled_product <= 32'sd0; scaled_valid <= 1'b0;
        audio_valid <= 1'b0; audio_left <= 24'd0; audio_right <= 24'd0;
        frame_done_toggle <= 1'b0;
        underrun_samples <= 32'd0; underrun_events <= 16'd0; starving <= 1'b0;
    end else if (read_reset[1]) begin
        read_sequence <= 3'd0; read_sequence_gray <= 3'd0;
        write_gray_r0 <= 3'd0; write_gray_r1 <= 3'd0;
        display_gray_r0 <= 3'd0; display_gray_r1 <= 3'd0;
        manual_seek_sync <= 3'd0; seek_pending <= 1'b0; seek_target <= 3'd0;
        sample_index <= 12'd0; repeated_sample <= 1'b0;
        settle <= 3'd4; sample_acc <= 32'd0;
        volume_product <= 24'sd0; product_valid <= 1'b0;
        scaled_product <= 32'sd0; scaled_valid <= 1'b0;
        audio_valid <= 1'b0; audio_left <= 24'd0; audio_right <= 24'd0;
        frame_done_toggle <= 1'b0;
        underrun_samples <= 32'd0; underrun_events <= 16'd0; starving <= 1'b0;
    end else begin
        write_gray_r0 <= write_sequence_gray;
        write_gray_r1 <= write_gray_r0;
        display_gray_r0 <= display_sequence_gray;
        display_gray_r1 <= display_gray_r0;
        manual_seek_sync <= {manual_seek_sync[1:0], manual_seek_toggle};
        sample_acc <= sample_tick ? acc_next - CLOCK_HZ : acc_next[31:0];
        product_valid <= sample_tick;
        scaled_valid <= product_valid;
        audio_valid <= scaled_valid;
        if (product_valid) scaled_product <= volume_product * 32'sd655;
        if (scaled_valid) begin
            audio_left <= {scaled_product[31:16], 8'd0};
            audio_right <= {scaled_product[31:16], 8'd0};
        end
        if (settle != 0) settle <= settle - 1'b1;
        if (manual_seek_event) begin
            seek_pending <= 1'b1;
            seek_target <= synchronized_display_sequence;
            if (sample_tick) volume_product <= 24'sd0;
        end else if (seek_pending && ((seek_distance == 3'd0) || seek_distance[2])) begin
            // A finished frame may already have advanced the audio pointer.
            // A manual step to that same frame must not skip twice.
            seek_pending <= 1'b0;
            if (sample_tick) volume_product <= 24'sd0;
        end else if (display_valid && seek_forward) begin
            // Drop only the requested old frame, preserving both timeline
            // alignment and pause/step semantics. No false completion pulse.
            read_sequence <= next_read_sequence;
            read_sequence_gray <= (next_read_sequence >> 1) ^ next_read_sequence;
            sample_index <= 12'd0;
            repeated_sample <= 1'b0;
            settle <= 3'd4;
            if (sample_tick) volume_product <= 24'sd0;
        end else if (sample_tick) begin
            if (display_valid && play && frame_available && settle == 0) begin
                volume_product <= ram_sample * $signed({1'b0, volume});
                starving <= 1'b0;
                if (!repeated_sample) repeated_sample <= 1'b1;
                else begin
                    repeated_sample <= 1'b0;
                    if (sample_index == SAMPLES_PER_FRAME-1) begin
                        read_sequence <= next_read_sequence;
                        read_sequence_gray <= (next_read_sequence >> 1) ^ next_read_sequence;
                        sample_index <= 12'd0;
                        settle <= 3'd4;
                        frame_done_toggle <= ~frame_done_toggle;
                    end else sample_index <= sample_index + 12'd1;
                end
            end else begin
                volume_product <= 24'sd0;
                if (display_valid && play && !frame_available) begin
                    underrun_samples <= underrun_samples + 32'd1;
                    if (!starving) underrun_events <= underrun_events + 16'd1;
                    starving <= 1'b1;
                end else if (!play || !display_valid) starving <= 1'b0;
            end
        end
    end
end
endmodule
