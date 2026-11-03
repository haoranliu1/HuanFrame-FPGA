`timescale 1ns/1ps

// Receives the fixed 7-byte command frames emitted by the TJC touch screen.
// Frame format: 55 01 command value FF FF FF.
// Commands use the value byte so the screen can request an explicit action:
// 01/00 = previous, 01/01 = next, 02/00 = auto stop,
// 02/01 = auto start, 10/value = brightness, 11/value = contrast,
// 12/value = HDMI PCM volume. Parameter values use the range 0..100.
// 13/00..07 = manual note on, 13/FE = manual mute, 13/FF = resume scale.
// 14/00..04 selects fade, wipe-left, wipe-right, center-expand or direct.
// 15/01..0F sets the automatic slideshow interval in whole seconds.
// 20/ASCII appends one printable subtitle character (maximum 32 bytes).
// 21/00 backspaces, 21/01 clears the edit buffer, 21/02 commits it,
// 21/03 restores the built-in subtitle messages. 22/00..06 selects a
// subtitle colour template; the selected colour is applied on commit.
module tjc_uart_rx #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer BAUD_RATE   = 115_200
)(
    input  wire clk,
    input  wire rst,
    input  wire uart_rx,
    output reg  manual_prev_toggle,
    output reg  manual_next_toggle,
    output reg  auto_start_toggle,
    output reg  auto_stop_toggle,
    output reg  brightness_toggle,
    output reg  contrast_toggle,
    output reg  volume_toggle,
    output reg  [6:0] brightness_value,
    output reg  [6:0] contrast_value,
    output reg  [6:0] volume_value,
    output reg         manual_note_enable,
    output reg         manual_note_gate,
    output reg  [2:0]  manual_note_index,
    // Showcase settings are stable registers, synchronized and frame-latched downstream.
    output reg         compare_enable,
    output reg [7:0]   compare_position,
    output reg [1:0]   spectrum_style,
    output reg         transition_mode_toggle,
    output reg  [2:0]  transition_mode_value,
    output reg         interval_toggle,
    output reg  [3:0]  interval_value,
    output reg         subtitle_commit_toggle,
    output reg  [255:0] subtitle_text,
    output reg  [5:0]  subtitle_length,
    output reg  [2:0]  subtitle_color,
    output reg  debug_toggle,
    output reg  boot_request_toggle,
    output reg  boot_target_video
);
    localparam integer CLKS_PER_BIT = (CLK_FREQ_HZ + (BAUD_RATE / 2)) / BAUD_RATE;
    localparam integer HALF_BIT     = CLKS_PER_BIT / 2;

    localparam [2:0] RX_IDLE  = 3'd0;
    localparam [2:0] RX_START = 3'd1;
    localparam [2:0] RX_DATA  = 3'd2;
    localparam [2:0] RX_STOP  = 3'd3;

    reg [2:0]  rx_state;
    reg [15:0] baud_count;
    reg [2:0]  bit_index;
    reg [7:0]  rx_shift;
    reg [2:0]  frame_pos;
    reg [7:0]  frame_command;
    reg [7:0]  frame_value;
    reg        frame_header_ok;
    reg [255:0] subtitle_edit_text;
    reg [5:0]   subtitle_edit_length;
    reg [2:0]   subtitle_edit_color;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rx_state       <= RX_IDLE;
            baud_count     <= 16'd0;
            bit_index      <= 3'd0;
            rx_shift       <= 8'd0;
            frame_pos      <= 3'd0;
            frame_command  <= 8'd0;
            frame_value    <= 8'd0;
            frame_header_ok<= 1'b0;
            manual_prev_toggle <= 1'b0;
            manual_next_toggle <= 1'b0;
            auto_start_toggle  <= 1'b0;
            auto_stop_toggle   <= 1'b0;
            brightness_toggle  <= 1'b0;
            contrast_toggle    <= 1'b0;
            volume_toggle      <= 1'b0;
            brightness_value   <= 7'd50;
            contrast_value     <= 7'd50;
            volume_value       <= 7'd50;
            manual_note_enable <= 1'b0;
            manual_note_gate   <= 1'b1;
            manual_note_index  <= 3'd0;
            compare_enable <= 1'b0;
            compare_position <= 8'd80;
            spectrum_style <= 2'd0;
            transition_mode_toggle <= 1'b0;
            transition_mode_value  <= 3'd0;
            interval_toggle        <= 1'b0;
            interval_value         <= 4'd2;
            subtitle_commit_toggle <= 1'b0;
            subtitle_text          <= 256'd0;
            subtitle_length        <= 6'd0;
            subtitle_color         <= 3'd1;
            subtitle_edit_text     <= 256'd0;
            subtitle_edit_length   <= 6'd0;
            subtitle_edit_color    <= 3'd1;
            debug_toggle   <= 1'b0;
            boot_request_toggle <= 1'b0;
            boot_target_video <= 1'b0;
        end else begin
            case (rx_state)
                RX_IDLE: begin
                    baud_count <= 16'd0;
                    if (!uart_rx)
                        rx_state <= RX_START;
                end

                RX_START: begin
                    if (baud_count == HALF_BIT - 1) begin
                        baud_count <= 16'd0;
                        if (!uart_rx) begin
                            bit_index <= 3'd0;
                            rx_state  <= RX_DATA;
                        end else begin
                            rx_state  <= RX_IDLE;
                        end
                    end else begin
                        baud_count <= baud_count + 1'b1;
                    end
                end

                RX_DATA: begin
                    if (baud_count == CLKS_PER_BIT - 1) begin
                        baud_count <= 16'd0;
                        rx_shift[bit_index] <= uart_rx;
                        if (bit_index == 3'd7) begin
                            rx_state <= RX_STOP;
                        end else begin
                            bit_index <= bit_index + 1'b1;
                        end
                    end else begin
                        baud_count <= baud_count + 1'b1;
                    end
                end

                RX_STOP: begin
                    if (baud_count == CLKS_PER_BIT - 1) begin
                        baud_count <= 16'd0;
                        rx_state   <= RX_IDLE;
                        if (uart_rx) begin
                            // Parse one byte. Bad bytes reset the parser and
                            // leave it ready to find the next 0x55 header.
                            case (frame_pos)
                                3'd0: begin
                                    if (rx_shift == 8'h55) begin
                                        frame_pos       <= 3'd1;
                                        frame_header_ok <= 1'b1;
                                    end else begin
                                        frame_pos       <= 3'd0;
                                        frame_header_ok <= 1'b0;
                                    end
                                end
                                3'd1: begin
                                    if (frame_header_ok && rx_shift == 8'h01) begin
                                        frame_pos <= 3'd2;
                                    end else if (rx_shift == 8'h55) begin
                                        frame_pos       <= 3'd1;
                                        frame_header_ok <= 1'b1;
                                    end else begin
                                        frame_pos       <= 3'd0;
                                        frame_header_ok <= 1'b0;
                                    end
                                end
                                3'd2: begin
                                    if (frame_header_ok) begin
                                        frame_command <= rx_shift;
                                        frame_pos     <= 3'd3;
                                    end else begin
                                        frame_pos <= 3'd0;
                                    end
                                end
                                3'd3: begin
                                    frame_value <= rx_shift;
                                    frame_pos <= frame_header_ok ? 3'd4 : 3'd0;
                                end
                                3'd4,
                                3'd5: begin
                                    if (frame_header_ok && rx_shift == 8'hff) begin
                                        frame_pos <= frame_pos + 1'b1;
                                    end else begin
                                        frame_pos       <= (rx_shift == 8'h55) ? 3'd1 : 3'd0;
                                        frame_header_ok <= (rx_shift == 8'h55);
                                    end
                                end
                                3'd6: begin
                                    if (frame_header_ok && rx_shift == 8'hff) begin
                                        case (frame_command)
                                            8'h01: begin
                                                if (frame_value == 8'h00)
                                                    manual_prev_toggle <= ~manual_prev_toggle;
                                                else if (frame_value == 8'h01)
                                                    manual_next_toggle <= ~manual_next_toggle;
                                            end
                                            8'h02: begin
                                                if (frame_value == 8'h00)
                                                    auto_stop_toggle <= ~auto_stop_toggle;
                                                else if (frame_value == 8'h01)
                                                    auto_start_toggle <= ~auto_start_toggle;
                                            end
                                            8'h10: begin
                                                if (frame_value <= 8'd100) begin
                                                    brightness_value  <= frame_value[6:0];
                                                    brightness_toggle <= ~brightness_toggle;
                                                end
                                            end
                                            8'h11: begin
                                                if (frame_value <= 8'd100) begin
                                                    contrast_value  <= frame_value[6:0];
                                                    contrast_toggle <= ~contrast_toggle;
                                                end
                                            end
                                            8'h12: begin
                                                if (frame_value <= 8'd100) begin
                                                    volume_value  <= frame_value[6:0];
                                                    volume_toggle <= ~volume_toggle;
                                                end
                                            end
                                            8'h13: begin
                                                if (frame_value <= 8'd7) begin
                                                    manual_note_enable <= 1'b1;
                                                    manual_note_gate   <= 1'b1;
                                                    manual_note_index  <= frame_value[2:0];
                                                end else if (frame_value == 8'hfe) begin
                                                    manual_note_enable <= 1'b1;
                                                    manual_note_gate   <= 1'b0;
                                                end else if (frame_value == 8'hff) begin
                                                    manual_note_enable <= 1'b0;
                                                    manual_note_gate   <= 1'b1;
                                                end
                                            end
                                            8'h14: begin
                                                if (frame_value <= 8'd7) begin
                                                    transition_mode_value  <= frame_value[2:0];
                                                    transition_mode_toggle <= ~transition_mode_toggle;
                                                end
                                            end
                                            8'h15: begin
                                                if ((frame_value >= 8'd1) &&
                                                    (frame_value <= 8'd15)) begin
                                                    interval_value  <= frame_value[3:0];
                                                    interval_toggle <= ~interval_toggle;
                                                end
                                            end
                                            8'h16: if (frame_value <= 8'd1)
                                                compare_enable <= frame_value[0];
                                            8'h17: if (frame_value <= 8'd160)
                                                compare_position <= frame_value;
                                            8'h18: if (frame_value <= 8'd2)
                                                spectrum_style <= frame_value[1:0];
                                            8'h20: begin
                                                if ((frame_value >= 8'h20) &&
                                                    (frame_value <= 8'h7e) &&
                                                    (subtitle_edit_length < 6'd32)) begin
                                                    subtitle_edit_text[
                                                        subtitle_edit_length * 8 +: 8
                                                    ] <= frame_value;
                                                    subtitle_edit_length <=
                                                        subtitle_edit_length + 1'b1;
                                                end
                                            end
                                            8'h21: begin
                                                case (frame_value)
                                                    8'h00: begin
                                                        if (subtitle_edit_length != 0)
                                                            subtitle_edit_length <=
                                                                subtitle_edit_length - 1'b1;
                                                    end
                                                    8'h01: begin
                                                        subtitle_edit_text   <= 256'd0;
                                                        subtitle_edit_length <= 6'd0;
                                                    end
                                                    8'h02: begin
                                                        subtitle_text   <= subtitle_edit_text;
                                                        subtitle_length <= subtitle_edit_length;
                                                        subtitle_color  <= subtitle_edit_color;
                                                        subtitle_commit_toggle <=
                                                            ~subtitle_commit_toggle;
                                                    end
                                                    8'h03: begin
                                                        subtitle_edit_text   <= 256'd0;
                                                        subtitle_edit_length <= 6'd0;
                                                        subtitle_edit_color  <= 3'd1;
                                                        subtitle_text        <= 256'd0;
                                                        subtitle_length      <= 6'd0;
                                                        subtitle_color       <= 3'd1;
                                                        subtitle_commit_toggle <=
                                                            ~subtitle_commit_toggle;
                                                    end
                                                    default: begin end
                                                endcase
                                            end
                                            8'h22: begin
                                                if (frame_value <= 8'd6)
                                                    subtitle_edit_color <=
                                                        frame_value[2:0];
                                            end
                                            8'h30: begin
                                                if (frame_value <= 8'd1) begin
                                                    boot_target_video <= frame_value[0];
                                                    boot_request_toggle <= ~boot_request_toggle;
                                                end
                                            end
                                            8'd3: debug_toggle  <= ~debug_toggle;
                                            default: begin end
                                        endcase
                                    end
                                    frame_pos       <= (rx_shift == 8'h55) ? 3'd1 : 3'd0;
                                    frame_header_ok <= (rx_shift == 8'h55);
                                end
                                default: begin
                                    frame_pos       <= 3'd0;
                                    frame_header_ok <= 1'b0;
                                end
                            endcase
                        end else begin
                            frame_pos       <= 3'd0;
                            frame_header_ok <= 1'b0;
                        end
                    end else begin
                        baud_count <= baud_count + 1'b1;
                    end
                end

                default: rx_state <= RX_IDLE;
            endcase
        end
    end
endmodule
