module hdmi_audio_tone_pcm_scale #(
    parameter integer CLK_FREQ_HZ       = 25_000_000,
    parameter integer SAMPLE_RATE_HZ    = 48_000,
    parameter signed [23:0] AMP         = 24'sd2000000,
    parameter integer NOTE_HOLD_SAMPLES = 24_000
)(
    input  wire        I_clk,
    input  wire        I_rst,
    input  wire [6:0]  I_volume,
    input  wire        I_manual_note_enable,
    input  wire        I_manual_note_gate,
    input  wire [2:0]  I_manual_note_index,
    output wire [2:0]  O_active_note_index,
    output wire        O_active_note_gate,
    output reg         O_audio_valid,
    output reg  [23:0] O_audio_left_data,
    output reg  [23:0] O_audio_right_data
);

function [31:0] note_inc_lut;
    input [2:0] idx;
    begin
        case (idx)
            3'd0: note_inc_lut = 32'd23409862;
            3'd1: note_inc_lut = 32'd26276681;
            3'd2: note_inc_lut = 32'd29494578;
            3'd3: note_inc_lut = 32'd31248410;
            3'd4: note_inc_lut = 32'd35075155;
            3'd5: note_inc_lut = 32'd39370534;
            3'd6: note_inc_lut = 32'd44191930;
            default: note_inc_lut = 32'd46819716;
        endcase
    end
endfunction

// 64-step signed sine table.  The scale factors are elaboration-time
// constants (sin(angle) * 2^20), so TD folds them into constants and does not
// infer a run-time multiplier in the 25 MHz audio/video clock domain.
localparam signed [23:0] SINE_01 = (AMP * 24'sd102778)  >>> 20;
localparam signed [23:0] SINE_02 = (AMP * 24'sd204567)  >>> 20;
localparam signed [23:0] SINE_03 = (AMP * 24'sd304386)  >>> 20;
localparam signed [23:0] SINE_04 = (AMP * 24'sd401273)  >>> 20;
localparam signed [23:0] SINE_05 = (AMP * 24'sd494295)  >>> 20;
localparam signed [23:0] SINE_06 = (AMP * 24'sd582558)  >>> 20;
localparam signed [23:0] SINE_07 = (AMP * 24'sd665210)  >>> 20;
localparam signed [23:0] SINE_08 = (AMP * 24'sd741455)  >>> 20;
localparam signed [23:0] SINE_09 = (AMP * 24'sd810560)  >>> 20;
localparam signed [23:0] SINE_10 = (AMP * 24'sd871859)  >>> 20;
localparam signed [23:0] SINE_11 = (AMP * 24'sd924761)  >>> 20;
localparam signed [23:0] SINE_12 = (AMP * 24'sd968758)  >>> 20;
localparam signed [23:0] SINE_13 = (AMP * 24'sd1003425) >>> 20;
localparam signed [23:0] SINE_14 = (AMP * 24'sd1028428) >>> 20;
localparam signed [23:0] SINE_15 = (AMP * 24'sd1043527) >>> 20;

function signed [23:0] sine_pcm_lut;
    input [5:0] idx;
    begin
        case (idx)
            6'd0:  sine_pcm_lut =  24'sd0;
            6'd1:  sine_pcm_lut =  SINE_01;
            6'd2:  sine_pcm_lut =  SINE_02;
            6'd3:  sine_pcm_lut =  SINE_03;
            6'd4:  sine_pcm_lut =  SINE_04;
            6'd5:  sine_pcm_lut =  SINE_05;
            6'd6:  sine_pcm_lut =  SINE_06;
            6'd7:  sine_pcm_lut =  SINE_07;
            6'd8:  sine_pcm_lut =  SINE_08;
            6'd9:  sine_pcm_lut =  SINE_09;
            6'd10: sine_pcm_lut =  SINE_10;
            6'd11: sine_pcm_lut =  SINE_11;
            6'd12: sine_pcm_lut =  SINE_12;
            6'd13: sine_pcm_lut =  SINE_13;
            6'd14: sine_pcm_lut =  SINE_14;
            6'd15: sine_pcm_lut =  SINE_15;
            6'd16: sine_pcm_lut =  AMP;
            6'd17: sine_pcm_lut =  SINE_15;
            6'd18: sine_pcm_lut =  SINE_14;
            6'd19: sine_pcm_lut =  SINE_13;
            6'd20: sine_pcm_lut =  SINE_12;
            6'd21: sine_pcm_lut =  SINE_11;
            6'd22: sine_pcm_lut =  SINE_10;
            6'd23: sine_pcm_lut =  SINE_09;
            6'd24: sine_pcm_lut =  SINE_08;
            6'd25: sine_pcm_lut =  SINE_07;
            6'd26: sine_pcm_lut =  SINE_06;
            6'd27: sine_pcm_lut =  SINE_05;
            6'd28: sine_pcm_lut =  SINE_04;
            6'd29: sine_pcm_lut =  SINE_03;
            6'd30: sine_pcm_lut =  SINE_02;
            6'd31: sine_pcm_lut =  SINE_01;
            6'd32: sine_pcm_lut =  24'sd0;
            6'd33: sine_pcm_lut = -SINE_01;
            6'd34: sine_pcm_lut = -SINE_02;
            6'd35: sine_pcm_lut = -SINE_03;
            6'd36: sine_pcm_lut = -SINE_04;
            6'd37: sine_pcm_lut = -SINE_05;
            6'd38: sine_pcm_lut = -SINE_06;
            6'd39: sine_pcm_lut = -SINE_07;
            6'd40: sine_pcm_lut = -SINE_08;
            6'd41: sine_pcm_lut = -SINE_09;
            6'd42: sine_pcm_lut = -SINE_10;
            6'd43: sine_pcm_lut = -SINE_11;
            6'd44: sine_pcm_lut = -SINE_12;
            6'd45: sine_pcm_lut = -SINE_13;
            6'd46: sine_pcm_lut = -SINE_14;
            6'd47: sine_pcm_lut = -SINE_15;
            6'd48: sine_pcm_lut = -AMP;
            6'd49: sine_pcm_lut = -SINE_15;
            6'd50: sine_pcm_lut = -SINE_14;
            6'd51: sine_pcm_lut = -SINE_13;
            6'd52: sine_pcm_lut = -SINE_12;
            6'd53: sine_pcm_lut = -SINE_11;
            6'd54: sine_pcm_lut = -SINE_10;
            6'd55: sine_pcm_lut = -SINE_09;
            6'd56: sine_pcm_lut = -SINE_08;
            6'd57: sine_pcm_lut = -SINE_07;
            6'd58: sine_pcm_lut = -SINE_06;
            6'd59: sine_pcm_lut = -SINE_05;
            6'd60: sine_pcm_lut = -SINE_04;
            6'd61: sine_pcm_lut = -SINE_03;
            6'd62: sine_pcm_lut = -SINE_02;
            default: sine_pcm_lut = -SINE_01;
        endcase
    end
endfunction

reg [31:0] sample_acc;
reg [31:0] phase_acc;
reg [2:0]  note_idx;
reg [31:0] note_sample_cnt;
reg [31:0] acc_add;
reg signed [31:0] volume_product;
reg               volume_product_valid;
reg signed [38:0] volume_scale_sum;
reg               volume_scale_valid;
reg               manual_note_enable_d;
reg               manual_note_gate_d;
reg [2:0]         manual_note_index_d;
wire [2:0] active_note_index = I_manual_note_enable ? I_manual_note_index : note_idx;
wire [31:0] note_inc = note_inc_lut(active_note_index);
assign O_active_note_index = active_note_index;
assign O_active_note_gate = I_manual_note_enable ? I_manual_note_gate : 1'b1;
wire signed [7:0] volume_signed = {1'b0, I_volume};
wire signed [38:0] volume_product_ext =
    {{7{volume_product[31]}}, volume_product};
wire signed [38:0] volume_scale_sum_next =
    volume_product_ext + (volume_product_ext <<< 3) +
    (volume_product_ext <<< 5);

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        O_audio_valid      <= 1'b0;
        O_audio_left_data  <= 24'd0;
        O_audio_right_data <= 24'd0;
        sample_acc         <= 32'd0;
        phase_acc          <= 32'd0;
        note_idx           <= 3'd0;
        note_sample_cnt    <= 32'd0;
        acc_add            <= 32'd0;
        volume_product     <= 32'sd0;
        volume_product_valid <= 1'b0;
        volume_scale_sum     <= 39'sd0;
        volume_scale_valid   <= 1'b0;
        manual_note_enable_d <= 1'b0;
        manual_note_gate_d   <= 1'b1;
        manual_note_index_d  <= 3'd0;
    end else begin
        manual_note_enable_d <= I_manual_note_enable;
        manual_note_gate_d   <= I_manual_note_gate;
        manual_note_index_d  <= I_manual_note_index;
        O_audio_valid <= 1'b0;
        if (volume_scale_valid) begin
            // 41/4096 approximates 1/100 within 0.1 percent, while avoiding
            // the long combinational divider that violated the 25 MHz path.
            O_audio_left_data  <= volume_scale_sum >>> 12;
            O_audio_right_data <= volume_scale_sum >>> 12;
            O_audio_valid      <= 1'b1;
            volume_scale_valid <= 1'b0;
        end
        if (volume_product_valid) begin
            volume_scale_sum     <= volume_scale_sum_next;
            volume_scale_valid   <= 1'b1;
            volume_product_valid <= 1'b0;
        end
        acc_add = sample_acc + SAMPLE_RATE_HZ;
        if (acc_add >= CLK_FREQ_HZ) begin
            sample_acc   <= acc_add - CLK_FREQ_HZ;
            phase_acc    <= phase_acc + note_inc;
            volume_product <= (I_manual_note_enable && !I_manual_note_gate) ?
                              32'sd0 :
                              sine_pcm_lut(phase_acc[31:26]) * volume_signed;
            volume_product_valid <= 1'b1;
            if (note_sample_cnt == NOTE_HOLD_SAMPLES - 1) begin
                note_sample_cnt <= 32'd0;
                note_idx <= (note_idx == 3'd7) ? 3'd0 : note_idx + 3'd1;
            end else begin
                note_sample_cnt <= note_sample_cnt + 32'd1;
            end
        end else begin
            sample_acc <= acc_add;
        end
        // Start every manually selected key at a repeatable zero crossing.
        if ((I_manual_note_enable != manual_note_enable_d) ||
            (I_manual_note_gate != manual_note_gate_d) ||
            (I_manual_note_index != manual_note_index_d))
            phase_acc <= 32'd0;
    end
end

endmodule
