module multiboot_hold_trigger #(
    parameter [7:0] TARGET_ADDR = 8'h00,
    parameter CURRENT_VIDEO = 1'b0,
    parameter integer HOLD_CYCLES = 100_000_000,
    parameter integer QUIET_CYCLES = 250_000,
    parameter integer NOTICE_CYCLES = 25_000_000, // 0.5s at 50MHz; no forced boot delay
    parameter integer TIMEOUT_CYCLES = 500_000_000
)(
    input clk,
    input rst,
    input key3_n,
    input key4_n,
    input request_toggle,
    input request_video,
    input source_quiet,
    output reg quiesce
);

// K3 and K4 are active-low.  Synchronize both raw key inputs before the
// two-second hold detector uses them in the 50 MHz board-clock domain.
reg [1:0] key3_sync;
reg [1:0] key4_sync;
reg [26:0] hold_count;
reg reboot_n;
reg [2:0] request_sync;
reg [1:0] target_sync;
reg [1:0] quiet_sync;
reg key_fired;
reg [28:0] wait_count;
reg [18:0] quiet_count;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        key3_sync <= 2'b11;
        key4_sync <= 2'b11;
    end else begin
        key3_sync <= {key3_sync[0], key3_n};
        key4_sync <= {key4_sync[0], key4_n};
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        hold_count <= 27'd0;
        reboot_n <= 1'b1;
        request_sync <= 3'd0;
        target_sync <= 2'd0;
        quiet_sync <= 2'd0;
        key_fired <= 1'b0;
        wait_count <= 29'd0;
        quiet_count <= 19'd0;
        quiesce <= 1'b0;
    end else begin
        request_sync <= {request_sync[1:0], request_toggle};
        target_sync <= {target_sync[0], request_video};
        quiet_sync <= {quiet_sync[0], source_quiet};
        if (key3_sync[1] || key4_sync[1]) begin
            hold_count <= 27'd0;
            key_fired <= 1'b0;
        end else if (!key_fired) begin
            if (hold_count == HOLD_CYCLES-1) begin
                key_fired <= 1'b1;
                quiesce <= 1'b1;
            end else hold_count <= hold_count + 1'b1;
        end
        // Explicit target commands are idempotent: asking for the running
        // image does not reboot it. Never jump until the source has drained.
        if ((request_sync[2] ^ request_sync[1]) &&
            (target_sync[1] != CURRENT_VIDEO))
            quiesce <= 1'b1;
        if (quiesce && reboot_n) begin
            if (wait_count == TIMEOUT_CYCLES-1) begin
                quiesce <= 1'b0;
                wait_count <= 29'd0;
                quiet_count <= 19'd0;
            end else begin
                wait_count <= wait_count + 1'b1;
                if (!quiet_sync[1]) quiet_count <= 19'd0;
                else if ((quiet_count == QUIET_CYCLES-1) &&
                         (wait_count >= NOTICE_CYCLES-1))
                    reboot_n <= 1'b0;
                else if (quiet_count != QUIET_CYCLES-1)
                    quiet_count <= quiet_count + 1'b1;
            end
        end else begin
            wait_count <= 29'd0;
            quiet_count <= 19'd0;
        end
    end
end

EG_LOGIC_MBOOT #(
    .ADDR_SOURCE_SEL("DYNAMIC"),
    .STATIC_ADDR(8'b00000000)
) multiboot_primitive (
    .rebootn      (reboot_n),
    .dynamic_addr (TARGET_ADDR)
);

endmodule
