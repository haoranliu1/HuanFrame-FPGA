// Single-sector, read-only arbitration. Never switches a live SPI transaction.
module bgm_sector_arbiter(
    input clk, input rst, input init_done, input bus_idle,
    input image_request, input [31:0] image_address,
    input bgm_request, input [31:0] bgm_address, input bgm_urgent,
    output bgm_ack,
    output reg card_request, output reg [31:0] card_address,
    input [7:0] card_data, input card_valid, input card_end,
    output reg [7:0] image_data, output reg image_valid, output reg image_end,
    output reg [7:0] bgm_data, output reg bgm_valid, output reg bgm_end,
    output idle
);
reg busy, owner_bgm, image_seen, image_pending;
reg [31:0] saved_image_address;
wire choose_bgm = bgm_request && (!image_pending || bgm_urgent);
wire dispatch = !busy && init_done && bus_idle;
assign bgm_ack = dispatch && choose_bgm;
// Return bytes, valid and end move together by exactly one SD clock.
// The client sees a registered owner decision instead of a long mux path.
always @(posedge clk or posedge rst)begin
    if(rst)begin
        image_data<=0;bgm_data<=0;
        image_valid<=0;image_end<=0;bgm_valid<=0;bgm_end<=0;
    end else begin
        image_data<=card_data;bgm_data<=card_data;
        image_valid<=busy && !owner_bgm && card_valid;
        image_end<=busy && !owner_bgm && card_end;
        bgm_valid<=busy && owner_bgm && card_valid;
        bgm_end<=busy && owner_bgm && card_end;
    end
end
assign idle = !busy && !card_request && !image_pending && !bgm_request &&
              !image_valid && !image_end && !bgm_valid && !bgm_end;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        busy<=0; owner_bgm<=0; image_seen<=0; image_pending<=0;
        saved_image_address<=0; card_request<=0; card_address<=0;
    end else begin
        card_request<=0;
        image_seen<=image_request;
        if (image_request && !image_seen) begin
            image_pending<=1;
            saved_image_address<=image_address;
        end
        if (busy) begin
            if (card_end) busy<=0;
        end else if (dispatch) begin
            if (choose_bgm) begin
                busy<=1; owner_bgm<=1;
                card_request<=1; card_address<=bgm_address;
            end else if (image_pending) begin
                busy<=1; owner_bgm<=0; image_pending<=0;
                card_request<=1; card_address<=saved_image_address;
            end
        end
    end
end
endmodule
