
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
// Packed RGB888: 960*720 pixels occupy518400 32-bit words per frame.
parameter FRAME_PIXELS  = 24'd518400;
parameter BUF0_ADDR     = 24'd0;
parameter BUF1_ADDR     = FRAME_PIXELS;
// Development build switch. Set to 1 until a valid TF card is available;
// set to 0 for the competition TF/BMP path.
// TF/BMP debug build. The verified ROM/SDRAM baseline remains available as a
// separately archived bitstream while the real card path is being repaired.
localparam NO_TF_MODE   = 1'b0;
// Keep a direct-pattern fallback until the first internally generated frame
// has completed its SDRAM write. The HDMI path then uses SDRAM readback.
localparam NO_TF_SDRAM_OUTPUT = 1'b1;

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
reg [7:0]   seg_status_m0,seg_status_m1,seg_status_m2;
wire        seg_scan_rst_n;

wire [3:0]  state_code;
wire [63:0] diagnostic_sd_data;
wire [6:0]  seg_data_0;
wire [6:0]  seg_data_key1;
wire [6:0]  seg_data_key2;
wire [6:0]  seg_data_key3;
wire [6:0]  seg_data_key4;
wire [6:0]  seg_data_last_key;

wire        video_read_req;
wire        video_read_req_ack;
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
wire [2:0]  frame_image_index;
wire        frame_auto_play;
wire [3:0]  frame_auto_interval_seconds;
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
reg [2:0]   frame_image_index_video_sync0;
reg [2:0]   frame_image_index_video_sync1;
reg         frame_auto_play_video_sync0;
reg         frame_auto_play_video_sync1;
reg [3:0]   frame_auto_interval_video_sync0;
reg [3:0]   frame_auto_interval_video_sync1;
reg         display_valid_video_sync0;
reg         display_valid_video_sync1;
reg [3:0]   state_code_video_sync0;
reg [3:0]   state_code_video_sync1;
reg [3:0]   state_code_video_stable;
reg         video_read_req_d;
reg [1:0]   front_buf_video;
reg [1:0]   front_buf_pending_video;
reg [2:0]   front_buf_guard_count;
wire        frame_switch_ready;

// Hold the old front buffer for two complete vertical periods after a new
// commit is observed. This deliberately trades switch latency for a larger
// SDRAM/FIFO settling margin at the frame boundary.
localparam [2:0] FRONT_SWITCH_GUARD_FRAMES = 3'd2;

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
wire [23:0] audio_left_data;
wire [23:0] audio_right_data;
wire [2:0]  audio_active_note_index;
wire        audio_active_note_gate;
wire [1:0] bgm_mode_clk;
wire [3:0] bgm_track_clk;
wire bgm_play_clk,bgm_restart_clk;
wire [6:0] bgm_volume_clk;
wire [31:0] bgm_library_sector_clk,bgm_library_bytes_clk,bgm_catalog_id_clk;
wire bgm_config_valid_clk;
wire tone_valid,bgm_audio_valid;
wire [23:0] tone_left,tone_right,bgm_audio_sample;
wire [2:0] tone_note;
wire tone_gate,bgm_flush_toggle,bgm_flush_busy,bgm_fifo_full;
wire bgm_fifo_play,bgm_sample_write;
wire [15:0] bgm_sample_data;
wire [10:0] bgm_fifo_level;
wire [4:0] bgm_track_count;
wire [3:0] bgm_fault;
wire [31:0] bgm_underruns;
reg [1:0] bgm_mode_video0,bgm_mode_video1;
always @(posedge video_clk or posedge rst_all) begin
    if(rst_all) begin bgm_mode_video0<=1;bgm_mode_video1<=1;end
    else begin bgm_mode_video0<=bgm_mode_clk;bgm_mode_video1<=bgm_mode_video0;end
end
assign audio_valid=(bgm_mode_video1==2)?bgm_audio_valid:tone_valid;
assign audio_left_data=(bgm_mode_video1==2)?bgm_audio_sample:
                       ((bgm_mode_video1==1)?tone_left:24'd0);
assign audio_right_data=(bgm_mode_video1==2)?bgm_audio_sample:
                        ((bgm_mode_video1==1)?tone_right:24'd0);
assign audio_active_note_index=tone_note;
assign audio_active_note_gate=(bgm_mode_video1==1)&&tone_gate;
bgm_pcm_fifo bgm_fifo(
    .write_clk(sd_card_clk),.read_clk(video_clk),.rst(rst_all),
    .flush_toggle(bgm_flush_toggle),.flush_busy(bgm_flush_busy),
    .write_en(bgm_sample_write),.write_data(bgm_sample_data),
    .write_level(bgm_fifo_level),.write_full(bgm_fifo_full),
    .sample_tick(tone_valid),.play(bgm_fifo_play),.volume(bgm_volume_clk),
    .audio_valid(bgm_audio_valid),.audio_sample(bgm_audio_sample),.underruns(bgm_underruns)
);
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

// Network image A boots the local/video image stored at Flash 0x200000 when
// physical K3 and K4 are held together for about two seconds.
multiboot_hold_trigger #(
    .TARGET_ADDR (8'h10),
    .CURRENT_VIDEO (1'b0)
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
wire zoom_commit_clk,image_select_clk;
wire [7:0] zoom_setting_clk,zoom_x_clk,zoom_y_clk;
wire [2:0] image_select_index_clk;
reg [2:0] zoom_commit_sync;
reg [7:0] zoom_setting_video,zoom_x_video,zoom_y_video;
always @(posedge video_clk or posedge rst_all) begin
    if(rst_all) begin
        zoom_commit_sync<=0;
        zoom_setting_video<=25;zoom_x_video<=128;zoom_y_video<=128;
    end else begin
        zoom_commit_sync<={zoom_commit_sync[1:0],zoom_commit_clk};
        // Bundled command payload has settled for two video clocks.
        if(zoom_commit_sync[2]!=zoom_commit_sync[1]) begin
            zoom_setting_video<=zoom_setting_clk;
            zoom_x_video<=zoom_x_clk;zoom_y_video<=zoom_y_clk;
        end
    end
end
// Assert asynchronously; release on the opposite clock edge so the UART's
// rising-edge registers have half a cycle of reset recovery/removal margin.
reg [1:0] touch_reset_sync;
always @(negedge clk or posedge rst_all) begin
    if (rst_all)
        touch_reset_sync <= 2'b11;
    else
        touch_reset_sync <= {touch_reset_sync[0],1'b0};
end
wire touch_local_rst = touch_reset_sync[1];
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

reg [6:0] bgm_visual_volume0,bgm_visual_volume1;
always @(posedge video_clk or posedge rst_all) begin
    if(rst_all) begin bgm_visual_volume0<=20;bgm_visual_volume1<=20;end
    else begin bgm_visual_volume0<=bgm_volume_clk;bgm_visual_volume1<=bgm_visual_volume0;end
end
wire [6:0] visual_volume=(bgm_mode_video1==2)?bgm_visual_volume1:audio_volume_level;

tjc_uart_rx #(
    .CLK_FREQ_HZ (50_000_000),
    .BAUD_RATE   (115_200)
) tjc_uart_rx_m0(
    .clk           (clk),
    .rst           (touch_local_rst),
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
    .boot_target_video(touch_boot_target_video_clk),
    .zoom_commit_toggle(zoom_commit_clk),.zoom_setting(zoom_setting_clk),
    .zoom_pan_x(zoom_x_clk),.zoom_pan_y(zoom_y_clk),
    .image_select_toggle(image_select_clk),.image_select_index(image_select_index_clk),
    .bgm_mode(bgm_mode_clk),.bgm_track(bgm_track_clk),.bgm_play(bgm_play_clk),
    .bgm_restart_toggle(bgm_restart_clk),.bgm_volume(bgm_volume_clk),
    .bgm_library_sector(bgm_library_sector_clk),.bgm_library_bytes(bgm_library_bytes_clk),
    .bgm_catalog_id(bgm_catalog_id_clk),.bgm_config_valid(bgm_config_valid_clk)
);

// Official HX4S20 RTL8211E/TEMAC/UDP receive chain.  The fixed endpoint is
// 192.168.240.1:5000; each non-empty packet replaces the scrolling subtitle.
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
        frame_image_index_video_sync0 <= 3'd0;
        frame_image_index_video_sync1 <= 3'd0;
        frame_auto_play_video_sync0   <= 1'b0;
        frame_auto_play_video_sync1   <= 1'b0;
        frame_auto_interval_video_sync0 <= 4'd2;
        frame_auto_interval_video_sync1 <= 4'd2;
        display_valid_video_sync0     <= 1'b0;
        display_valid_video_sync1     <= 1'b0;
        state_code_video_sync0         <= 4'd0;
        state_code_video_sync1         <= 4'd0;
        state_code_video_stable        <= 4'd0;
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

        assign sd_ncs  = 1'b1;
        assign sd_dclk = 1'b0;
        assign sd_mosi = 1'b1;
    end else begin : gen_tf_source
        sd_card_bmp #(
            .CLK_FREQ_HZ       (100_000_000),
            .SCAN_START_SECTOR (32'd0),
            .SCAN_MAX_SECTOR   (32'd131071),
            .SCAN_TARGET_COUNT (3'd6)
        ) sd_card_bmp_m0(
            .diagnostic_sd_data(diagnostic_sd_data),
            .image_select_toggle(image_select_clk),
            .image_select_index(image_select_index_clk),
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
            .interval_toggle   (touch_interval_toggle_clk),
            .interval_value    (touch_interval_value_clk),
            .state_code        (state_code),
            .image_index_dbg   (frame_image_index),
            .auto_play_dbg     (frame_auto_play),
            .bmp_width         (16'd640),
            .bmp_height        (16'd480),
            .display_valid     (display_valid),

            .write_finish_toggle(frame_write_toggle_mem),
            .write_buf_idx     (write_buf_idx),
            .disp_buf_idx      (disp_buf_idx),
            .interval_seconds_dbg(frame_auto_interval_seconds),

            .write_req         (sd_card_write_req),
            .write_req_ack     (sd_card_write_req_ack),
            .write_fifo_full   (sd_write_fifo_full),
            .write_en          (sd_card_write_en),
            .write_data        (sd_card_write_data),
            .SD_nCS            (sd_ncs),
            .SD_DCLK           (sd_dclk),
            .SD_MOSI           (sd_mosi),
            .SD_MISO           (sd_miso)
            ,.bgm_mode(bgm_mode_clk),.bgm_track(bgm_track_clk),.bgm_play(bgm_play_clk)
            ,.bgm_restart_toggle(bgm_restart_clk),.bgm_fifo_level(bgm_fifo_level)
            ,.bgm_fifo_full(bgm_fifo_full),.bgm_flush_busy(bgm_flush_busy)
            ,.bgm_flush_toggle(bgm_flush_toggle),.bgm_fifo_play(bgm_fifo_play)
            ,.bgm_sample_write(bgm_sample_write),.bgm_sample_data(bgm_sample_data)
            ,.bgm_track_count(bgm_track_count),.bgm_fault(bgm_fault)
            ,.bgm_library_sector(bgm_library_sector_clk),.bgm_library_bytes(bgm_library_bytes_clk)
            ,.bgm_catalog_id(bgm_catalog_id_clk),.bgm_config_valid(bgm_config_valid_clk)
        );
    end
endgenerate

// Diagnostic-only levels: sample on the opposite system-clock edge, then
// settle twice before the decoder. No video-domain signal drives a segment.
always @(negedge clk or posedge rst_all) begin
    if(rst_all) seg_status_m0<=0;
    else seg_status_m0<={state_code,direct_last_key_code};
end
always @(posedge clk or posedge rst_all) begin
    if(rst_all) begin seg_status_m1<=0;seg_status_m2<=0;end
    else begin seg_status_m1<=seg_status_m0;seg_status_m2<=seg_status_m1;end
end

seg_decoder seg_decoder_m0(
    .bin_data          (seg_status_m2[7:4]),
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
    .bin_data          (seg_status_m2[3:0]),
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
    .seg_data_4        (seg_status_m2[3:0] == 4'd0 ? 8'hff : {1'b1,seg_data_last_key}),
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

wire [9:0] showcase_tile_address,showcase_glyph_address;
wire [31:0] showcase_tile_word,showcase_glyph_word;
showcase_shared_font_rom shared_showcase_font(
    .clk(video_clk),.tile_address(showcase_tile_address),.glyph_address(showcase_glyph_address),
    .tile_word(showcase_tile_word),.glyph_word(showcase_glyph_word)
);
video_direct_test #(.BASE_ONLY(1),.SHARED_FONT(1)) direct_test_source(
    .shared_glyph_address(showcase_glyph_address),.shared_glyph_word(showcase_glyph_word),
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
    .audio_volume           (visual_volume),
    .audio_manual_note_enable(touch_manual_note_enable_sync1),
    .audio_manual_note_gate  (touch_manual_note_gate_sync1),
    .audio_manual_note_index (touch_manual_note_index_sync1),
    .compare_enable(showcase_compare_sync1),
    .compare_position(showcase_position_sync1),
    .spectrum_style(showcase_style_sync1),
    .audio_pcm_mode(bgm_mode_video1==2),
    .transition_mode        (transition_mode_level),
    .frame_state(state_code_video_stable),
    .frame_mode(frame_image_index_video_sync1),
    .frame_auto(frame_auto_play_video_sync1),
    .frame_interval_seconds(frame_auto_interval_video_sync1),
    .frame_buffer(front_buf_video),
    .frame_buffer_request(disp_buf_idx_video_sync1),
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
wire [127:0] hires_diagnostic_data;
wire [23:0] hires_diagnostic_rgb;
hires_diagnostic_overlay hires_diagnostic_overlay_m0(
    .clk(video_clk),.rst(rst_all),.vs(vs),.de(de),
    .data(hires_diagnostic_data),.source_rgb(direct_test_rgb),
    .rgb(hires_diagnostic_rgb)
);
startup_status_screen #(.CURRENT_VIDEO(1'b0),.SOURCE_PIPELINED(1'b1),.SHARED_FONT(1)) startup_status_screen_m0 (
    .shared_tile_address(showcase_tile_address),.shared_tile_word(showcase_tile_word),
    .clk(video_clk), .rst(rst_all), .vs(vs), .de(de),
    .source_rgb(direct_test_rgb),
    .media_ready(display_valid_video_sync1),
    .switch_pending(boot_quiesce), .source_state(state_code_video_stable),
    .out_vs(screen_vs), .out_de(screen_de), .out_rgb(vout_data)
);

frame_read_write #(
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (720), // words per packed960-pixel row
    .FRAME_HEIGHT     (720)
) frame_read_write_m0(
    .mem_clk           (ext_mem_clk),
    .rst               (rst_all),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .display_active    (display_valid),
    .zoom_setting(zoom_setting_video),
    .zoom_pan_x(zoom_x_video),.zoom_pan_y(zoom_y_video),

    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .read_finish       (),
    .read_addr_0       (BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       (24'd0),
    .read_addr_3       (24'd0),
    .read_addr_index   (front_buf_video),
    .read_len          (FRAME_PIXELS),
    .read_en           (video_read_en),
    .read_data         (video_read_data),
    .read_fifo_empty   (video_read_fifo_empty),
    .read_stream_ready (video_read_ready),
    .diagnostic_data   (hires_diagnostic_data),
    .monitor_rgb       (vout_data_raw),

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
    .write_addr_2      (24'd0),
    .write_addr_3      (24'd0),
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
hdmi_audio_tone_pcm_scale #(
    .CLK_FREQ_HZ       (25_000_000),
    .SAMPLE_RATE_HZ    (48_000),
    .AMP               (24'sd2000000),
    .NOTE_HOLD_SAMPLES (24_000)
) u_hdmi_audio_tone (
    .I_clk             (video_clk),
    .I_rst             (rst_all),
    .I_volume          (audio_volume_level),
    .I_manual_note_enable(touch_manual_note_enable_sync1),
    .I_manual_note_gate  (touch_manual_note_gate_sync1),
    .I_manual_note_index (touch_manual_note_index_sync1),
    .O_active_note_index(tone_note),
    .O_active_note_gate (tone_gate),
    .O_audio_valid     (tone_valid),
    .O_audio_left_data (tone_left),
    .O_audio_right_data(tone_right)
);

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
