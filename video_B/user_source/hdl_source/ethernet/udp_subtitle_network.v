`timescale 1ns/1ps

// Receive-only UDP front end for the on-board RTL8211E.  The MAC and UDP
// protocol stack are the verified blocks from the official HX4S20 example.
module udp_subtitle_network #(
    parameter [31:0] LOCAL_IP_ADDRESS  = 32'hc0a8f001,
    parameter [15:0] LOCAL_UDP_PORT    = 16'd5000,
    parameter [47:0] LOCAL_MAC_ADDRESS = 48'h02123456789a
)(
    input  wire       clk_50,
    input  wire       reset,

    input  wire       phy_rgmii_rx_clk,
    input  wire       phy_rgmii_rx_ctl,
    input  wire [3:0] phy_rgmii_rx_data,
    output wire       phy_rgmii_tx_clk,
    output wire       phy_rgmii_tx_ctl,
    output wire [3:0] phy_rgmii_tx_data,

    output wire         network_ready,
    output wire [255:0] subtitle_text,
    output wire [5:0]   subtitle_length,
    output wire [2:0]   subtitle_color,
    output wire         subtitle_bitmap_mode,
    output wire         subtitle_bitmap_bank,
    output wire         subtitle_commit_toggle,
    output wire [7:0]   packet_count,

    input  wire         bitmap_read_bank,
    input  wire         bitmap_read_clk,
    input  wire [8:0]   bitmap_read_address,
    output wire [15:0]  bitmap_read_data
);
    localparam [1:0] TRI_SPEED = 2'b10;

    wire        temac_clk;
    wire        temac_clk90;
    wire        clk_125_out;
    wire        clk_12_5_out;
    wire        clk_1_25_out;
    wire        clk_25_out;
    wire        ethernet_pll_reset;
    wire        network_reset;
    wire        udp_clk;

    wire        rx_clk_int;
    wire        rx_clk_en_int;
    wire        tx_clk_int;
    wire        tx_clk_en_int;
    wire [7:0]  rx_data;
    wire        rx_valid;
    wire [7:0]  tx_data;
    wire        tx_valid;
    wire        tx_rdy;
    wire        tx_collision;
    wire        tx_retransmit;
    wire        rx_correct_frame;
    wire        rx_error_frame;

    wire        temac_tx_ready;
    wire        temac_tx_valid;
    wire [7:0]  temac_tx_data;
    wire        temac_tx_sof;
    wire        temac_tx_eof;
    wire        temac_rx_ready;
    wire        temac_rx_valid_n;
    wire [7:0]  temac_rx_data;
    wire        temac_rx_sof;
    wire        temac_rx_eof;

    wire        app_rx_data_valid;
    wire [7:0]  app_rx_data;
    wire [15:0] app_rx_data_length;
    wire [15:0] app_rx_port_num;
    wire        udp_tx_ready;
    wire        app_tx_ack;

    wire        rx_clk_unused;
    wire        rx_clk_shifted;
    wire        rx_clk_double_unused;

    wire [19:0] mac_cfg_vector;
    wire [47:0] unicast_address;

    assign network_reset = reset | ethernet_pll_reset;
    assign network_ready = ~network_reset;

    assign unicast_address = {
        LOCAL_MAC_ADDRESS[7:0],
        LOCAL_MAC_ADDRESS[15:8],
        LOCAL_MAC_ADDRESS[23:16],
        LOCAL_MAC_ADDRESS[31:24],
        LOCAL_MAC_ADDRESS[39:32],
        LOCAL_MAC_ADDRESS[47:40]
    };
    assign mac_cfg_vector = {1'b0, 2'b00, TRI_SPEED,
                             8'b00000010, 7'b0000010};

    clk_gen_rst_gen #(
        .DEVICE("EG4")
    ) u_clk_gen (
        .reset        (reset),
        .clk_in       (clk_50),
        .rst_out      (ethernet_pll_reset),
        .clk_125_out0 (temac_clk),
        .clk_125_out1 (clk_125_out),
        .clk_125_out2 (temac_clk90),
        .clk_12_5_out (clk_12_5_out),
        .clk_1_25_out (clk_1_25_out),
        .clk_25_out   (clk_25_out)
    );

    rx_pll u_rx_pll (
        .refclk   (phy_rgmii_rx_clk),
        .reset    (reset),
        .clk0_out (rx_clk_unused),
        .clk1_out (rx_clk_shifted),
        .clk2_out (rx_clk_double_unused)
    );

    udp_clk_gen #(
        .DEVICE("EG4")
    ) u_udp_clk_gen (
        .reset       (network_reset),
        .tri_speed   (TRI_SPEED),
        .clk_125_in  (clk_125_out),
        .clk_12_5_in (clk_12_5_out),
        .clk_1_25_in (clk_1_25_out),
        .udp_clk_out (udp_clk)
    );

    udp_ip_protocol_stack #(
        .DEVICE             ("EG4"),
        .LOCAL_UDP_PORT_NUM  (LOCAL_UDP_PORT),
        .LOCAL_IP_ADDRESS    (LOCAL_IP_ADDRESS),
        .LOCAL_MAC_ADDRESS   (LOCAL_MAC_ADDRESS)
    ) u_udp_stack (
        .udp_rx_clk                    (udp_clk),
        .udp_tx_clk                    (udp_clk),
        .reset                         (network_reset),
        .udp2app_tx_ready              (udp_tx_ready),
        .udp2app_tx_ack                (app_tx_ack),
        .app_tx_request                (1'b0),
        .app_tx_data_valid             (1'b0),
        .app_tx_data                   (8'h00),
        .app_tx_data_length            (16'd0),
        .app_tx_dst_port               (16'd0),
        .ip_tx_dst_address             (32'd0),
        .input_local_udp_port_num      (LOCAL_UDP_PORT),
        .input_local_udp_port_num_valid(1'b0),
        .input_local_ip_address        (LOCAL_IP_ADDRESS),
        .input_local_ip_address_valid  (1'b0),
        .app_rx_data_valid             (app_rx_data_valid),
        .app_rx_data                   (app_rx_data),
        .app_rx_data_length            (app_rx_data_length),
        .app_rx_port_num               (app_rx_port_num),
        .temac_rx_ready                (temac_rx_ready),
        .temac_rx_valid                (!temac_rx_valid_n),
        .temac_rx_data                 (temac_rx_data),
        .temac_rx_sof                  (temac_rx_sof),
        .temac_rx_eof                  (temac_rx_eof),
        .temac_tx_ready                (temac_tx_ready),
        .temac_tx_valid                (temac_tx_valid),
        .temac_tx_data                 (temac_tx_data),
        .temac_tx_sof                  (temac_tx_sof),
        .temac_tx_eof                  (temac_tx_eof),
        .ip_rx_error                   (),
        .arp_request_no_reply_error    ()
    );

    temac_block #(
        .DEVICE("EG4")
    ) u_temac (
        .reset                (network_reset),
        .gtx_clk              (clk_125_out),
        .gtx_clk_90           (temac_clk90),
        .rx_clk               (rx_clk_int),
        .rx_clk_en            (rx_clk_en_int),
        .rx_data              (rx_data),
        .rx_data_valid        (rx_valid),
        .rx_correct_frame     (rx_correct_frame),
        .rx_error_frame       (rx_error_frame),
        .rx_status_vector     (),
        .rx_status_vld        (),
        .tx_clk               (tx_clk_int),
        .tx_clk_en            (tx_clk_en_int),
        .tx_data              (tx_data),
        .tx_data_en           (tx_valid),
        .tx_rdy               (tx_rdy),
        .tx_stop              (1'b0),
        .tx_collision         (tx_collision),
        .tx_retransmit        (tx_retransmit),
        .tx_ifg_val           (8'h00),
        .tx_status_vector     (),
        .tx_status_vld        (),
        .pause_req            (1'b0),
        .pause_val            (16'h0000),
        .pause_source_addr    (48'h5af1f2f3f4f5),
        .unicast_address      (unicast_address),
        .mac_cfg_vector       (mac_cfg_vector),
        .rgmii_txd            (phy_rgmii_tx_data),
        .rgmii_tx_ctl         (phy_rgmii_tx_ctl),
        .rgmii_txc            (phy_rgmii_tx_clk),
        .rgmii_rxd            (phy_rgmii_rx_data),
        .rgmii_rx_ctl         (phy_rgmii_rx_ctl),
        .rgmii_rxc            (rx_clk_shifted),
        .inband_link_status   (),
        .inband_clock_speed   (),
        .inband_duplex_status ()
    );

    tx_client_fifo #(
        .DEVICE("EG4")
    ) u_tx_fifo (
        .rd_clk         (tx_clk_int),
        .rd_sreset      (network_reset),
        .rd_enable      (tx_clk_en_int),
        .tx_data        (tx_data),
        .tx_data_valid  (tx_valid),
        .tx_ack         (tx_rdy),
        .tx_collision   (tx_collision),
        .tx_retransmit  (tx_retransmit),
        .overflow       (),
        .wr_clk         (udp_clk),
        .wr_sreset      (network_reset),
        .wr_data        (temac_tx_data),
        .wr_sof_n       (temac_tx_sof),
        .wr_eof_n       (temac_tx_eof),
        .wr_src_rdy_n   (temac_tx_valid),
        .wr_dst_rdy_n   (temac_tx_ready),
        .wr_fifo_status ()
    );

    rx_client_fifo #(
        .DEVICE("EG4")
    ) u_rx_fifo (
        .wr_clk         (rx_clk_int),
        .wr_enable      (rx_clk_en_int),
        .wr_sreset      (network_reset),
        .rx_data        (rx_data),
        .rx_data_valid  (rx_valid),
        .rx_good_frame  (rx_correct_frame),
        .rx_bad_frame   (rx_error_frame),
        .overflow       (),
        .rd_clk         (udp_clk),
        .rd_sreset      (network_reset),
        .rd_data_out    (temac_rx_data),
        .rd_sof_n       (temac_rx_sof),
        .rd_eof_n       (temac_rx_eof),
        .rd_src_rdy_n   (temac_rx_valid_n),
        .rd_dst_rdy_n   (temac_rx_ready),
        .rx_fifo_status ()
    );

    udp_subtitle_capture u_subtitle_capture (
        .clk              (udp_clk),
        .reset            (network_reset),
        .data_valid       (app_rx_data_valid),
        .data             (app_rx_data),
        .data_length      (app_rx_data_length),
        .destination_port (app_rx_port_num),
        .subtitle_text    (subtitle_text),
        .subtitle_length  (subtitle_length),
        .subtitle_color   (subtitle_color),
        .subtitle_bitmap_mode(subtitle_bitmap_mode),
        .subtitle_bitmap_bank(subtitle_bitmap_bank),
        .commit_toggle    (subtitle_commit_toggle),
        .packet_count     (packet_count),
        .bitmap_read_bank (bitmap_read_bank),
        .bitmap_read_clk  (bitmap_read_clk),
        .bitmap_read_address(bitmap_read_address),
        .bitmap_read_data (bitmap_read_data)
    );

    // Keep otherwise-unused official interface signals visible to synthesis.
    wire unused_ok = temac_clk ^ clk_25_out ^ udp_tx_ready ^ app_tx_ack ^
                     app_rx_data_length[15] ^ app_rx_port_num[15];
endmodule

module udp_subtitle_capture (
    input  wire         clk,
    input  wire         reset,
    input  wire         data_valid,
    input  wire [7:0]   data,
    input  wire [15:0]  data_length,
    input  wire [15:0]  destination_port,
    output reg  [255:0] subtitle_text,
    output reg  [5:0]   subtitle_length,
    output reg  [2:0]   subtitle_color,
    output reg          subtitle_bitmap_mode,
    output reg          subtitle_bitmap_bank,
    output reg          commit_toggle,
    output reg  [7:0]   packet_count,
    input  wire         bitmap_read_bank,
    input  wire         bitmap_read_clk,
    input  wire [8:0]   bitmap_read_address,
    output wire [15:0]  bitmap_read_data
);
    reg          data_valid_d;
    reg [255:0]  working_text;
    reg [5:0]    working_length;
    reg          legacy_valid;
    // CNB1 tops out at 1032 bytes, so 11 bits cover every valid packet.
    // Keeping these counters at protocol width shortens the compare/add paths.
    reg [10:0]   byte_index;
    reg [10:0]   packet_length;
    reg          packet_length_fits;
    reg          bitmap_magic_match;
    reg [5:0]    bitmap_glyph_count;
    reg [2:0]    bitmap_color_work;
    reg [7:0]    bitmap_high_byte;
    wire         printable;
    wire [10:0]  bitmap_payload_index;
    wire [10:0]  expected_bitmap_length;
    wire         bitmap_write_enable;
    wire [9:0]   bitmap_write_address;
    wire [15:0]  bitmap_write_data;

    assign printable = (data >= 8'h20) && (data <= 8'h7e);
    assign bitmap_payload_index = byte_index - 11'd8;
    assign expected_bitmap_length = 11'd8 +
                                    ({5'd0, bitmap_glyph_count} << 5);
    assign bitmap_write_enable = data_valid && data_valid_d &&
                                 (byte_index >= 11'd8) &&
                                 (byte_index < 11'd1032) &&
                                 bitmap_magic_match &&
                                 bitmap_payload_index[0];
    assign bitmap_write_address = {
        ~subtitle_bitmap_bank,
        bitmap_payload_index[9:1]
    };
    assign bitmap_write_data = {bitmap_high_byte, data};

    subtitle_bitmap_dual_port_ram u_bitmap_ram (
        .write_clock   (clk),
        .write_enable  (bitmap_write_enable),
        .write_address (bitmap_write_address),
        .write_data    (bitmap_write_data),
        .read_clock    (bitmap_read_clk),
        .read_address  ({bitmap_read_bank, bitmap_read_address}),
        .read_data     (bitmap_read_data)
    );

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            data_valid_d   <= 1'b0;
            working_text   <= 256'd0;
            working_length <= 6'd0;
            legacy_valid   <= 1'b0;
            byte_index     <= 11'd0;
            packet_length  <= 11'd0;
            packet_length_fits <= 1'b0;
            bitmap_magic_match <= 1'b0;
            bitmap_glyph_count <= 6'd0;
            bitmap_color_work <= 3'd2;
            bitmap_high_byte <= 8'd0;
            subtitle_text  <= 256'd0;
            subtitle_length <= 6'd0;
            subtitle_color <= 3'd2;
            subtitle_bitmap_mode <= 1'b0;
            subtitle_bitmap_bank <= 1'b0;
            commit_toggle  <= 1'b0;
            packet_count   <= 8'd0;
        end else begin
            data_valid_d <= data_valid;

            if (data_valid) begin
                if (!data_valid_d) begin
                    byte_index     <= 11'd1;
                    packet_length  <= data_length[10:0];
                    packet_length_fits <= (data_length[15:11] == 5'd0);
                    working_text   <= 256'd0;
                    working_length <= 6'd0;
                    legacy_valid   <= printable;
                    bitmap_magic_match <= (data == 8'h43); // C
                    bitmap_glyph_count <= 6'd0;
                    bitmap_color_work <= 3'd2;
                    bitmap_high_byte <= 8'd0;
                    if (printable) begin
                        working_text[7:0] <= data;
                        working_length <= 6'd1;
                    end
                end else begin
                    byte_index <= byte_index + 1'b1;

                    if (printable && (working_length < 6'd32)) begin
                        working_text[working_length * 8 +: 8] <= data;
                        working_length <= working_length + 1'b1;
                    end else begin
                        legacy_valid <= 1'b0;
                    end

                    case (byte_index)
                        16'd1: bitmap_magic_match <= bitmap_magic_match &&
                                                            (data == 8'h4e); // N
                        16'd2: bitmap_magic_match <= bitmap_magic_match &&
                                                            (data == 8'h42); // B
                        16'd3: bitmap_magic_match <= bitmap_magic_match &&
                                                            (data == 8'h31); // 1
                        16'd4: bitmap_glyph_count <= data[5:0];
                        16'd5: bitmap_color_work <= data[2:0];
                        default: begin
                            if ((byte_index >= 11'd8) &&
                                bitmap_magic_match &&
                                (bitmap_payload_index < 11'd1024)) begin
                                if (!bitmap_payload_index[0]) begin
                                    bitmap_high_byte <= data;
                                end
                            end
                        end
                    endcase
                end
            end else if (data_valid_d) begin
                if (bitmap_magic_match &&
                    packet_length_fits &&
                    (bitmap_glyph_count >= 6'd1) &&
                    (bitmap_glyph_count <= 6'd32) &&
                    (bitmap_color_work <= 3'd6) &&
                    (packet_length == expected_bitmap_length)) begin
                    subtitle_text        <= 256'd0;
                    subtitle_length      <= bitmap_glyph_count;
                    subtitle_color       <= bitmap_color_work;
                    subtitle_bitmap_mode <= 1'b1;
                    subtitle_bitmap_bank <= ~subtitle_bitmap_bank;
                    commit_toggle        <= ~commit_toggle;
                    packet_count         <= packet_count + 1'b1;
                end else if (legacy_valid &&
                             packet_length_fits &&
                             (working_length != 0) &&
                             (packet_length <= 11'd32)) begin
                    subtitle_text        <= working_text;
                    subtitle_length      <= working_length;
                    subtitle_color       <= 3'd2;
                    subtitle_bitmap_mode <= 1'b0;
                    commit_toggle        <= ~commit_toggle;
                    packet_count         <= packet_count + 1'b1;
                end
            end
        end
    end

    wire unused_metadata = data_length[0] ^ destination_port[0];
endmodule

// One 1024x16 true dual-port memory provides two complete 32-character
// banks. The UDP clock only writes the inactive bank; the video clock reads
// the active bank synchronously. This removes the asynchronous Logic-DRAM
// path and gives a complete-packet commit boundary.
module subtitle_bitmap_dual_port_ram (
    input  wire        write_clock,
    input  wire        write_enable,
    input  wire [9:0]  write_address,
    input  wire [15:0] write_data,
    input  wire        read_clock,
    input  wire [9:0]  read_address,
    output reg  [15:0] read_data
);
    reg [15:0] memory [0:1023];

    always @(posedge write_clock) begin
        if (write_enable)
            memory[write_address] <= write_data;
    end

    always @(posedge read_clock) begin
        read_data <= memory[read_address];
    end
endmodule
