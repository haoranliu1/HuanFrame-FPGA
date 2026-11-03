// Find BGM.LIB in an MBR/FAT32 root directory, then verify its COMPLETE FAT
// chain is contiguous before permitting raw audio reads. No card writes.
module bgm_fat_locator #(
    parameter integer TIMEOUT_CYCLES=100_000_000
)(
    input clk,input rst,input enable,input quiesce,
    output request,output [31:0] address,input ack,
    input [7:0] data,input valid,input sector_end,
    output reg ready,output reg [3:0] fault,
    output reg [31:0] library_sector,output reg [31:0] library_bytes
);
localparam BOOT=0,BPB=1,ROOT=2,ROOT_FAT=3,VERIFY=4;
localparam IDLE=0,REQUEST=1,READ=2,CHECK=3,DONE=4,ERROR=5,GEOMETRY=6,BOUNDS=7,
           GEO_SHIFT=8,GEO_ADDR=9,FILE_SIZE=10,FILE_CLUSTER=11,FILE_ADDR=12,FILE_LAST=13;
reg [3:0] state;
reg [2:0] kind;
reg [31:0] sector,partition_lba,partition_sectors;
reg [31:0] fat_size,total_sectors,root_cluster,fat_base,data_base,max_cluster;
reg [27:0] first_cluster,last_cluster;
reg [20:0] verify_fat_sector;
reg [31:0] entry_cluster,entry_bytes,fat_word,root_next;
reg [15:0] signature,bytes_per_sector,reserved,fat16,root_entries,flags;
reg [7:0] partition_type,spc,fats;
reg [3:0] cluster_shift;
reg [7:0] root_sector_in_cluster,root_hops;
reg [9:0] byte_count;
reg [31:0] timer;
reg [31:0] volume_end,data_sectors,cluster_offset;
reg [27:0] volume_clusters;
reg [20:0] file_last_sector,file_last_cluster;
reg name_match,entry_ok,found,root_end,chain_bad;
wire [27:0] current_fat_index={verify_fat_sector,byte_count[8:2]};
wire [31:0] decoded_fat={4'd0,data[3:0],fat_word[23:0]};
assign request=(state==REQUEST) && !quiesce;
assign address=sector;
function [7:0] name_byte;
    input [3:0] n;
    begin case(n)
        0:name_byte="B";1:name_byte="G";2:name_byte="M";
        8:name_byte="L";9:name_byte="I";10:name_byte="B";
        default:name_byte=" ";
    endcase end
endfunction
always @(posedge clk or posedge rst) begin
    if(rst) begin
        state<=IDLE;kind<=BOOT;sector<=0;partition_lba<=0;partition_sectors<=0;
        fat_size<=0;total_sectors<=0;root_cluster<=0;fat_base<=0;data_base<=0;
        max_cluster<=0;first_cluster<=0;last_cluster<=0;verify_fat_sector<=0;
        entry_cluster<=0;entry_bytes<=0;fat_word<=0;root_next<=0;
        signature<=0;bytes_per_sector<=0;reserved<=0;fat16<=0;root_entries<=0;flags<=0;
        partition_type<=0;spc<=0;fats<=0;cluster_shift<=0;
        root_sector_in_cluster<=0;root_hops<=0;byte_count<=0;timer<=0;
        name_match<=0;entry_ok<=0;found<=0;root_end<=0;chain_bad<=0;
        volume_end<=0;data_sectors<=0;cluster_offset<=0;volume_clusters<=0;
        file_last_sector<=0;file_last_cluster<=0;
        ready<=0;fault<=0;library_sector<=0;library_bytes<=0;
    end else begin
        case(state)
        IDLE: if(enable && !quiesce) begin
            kind<=BOOT;sector<=0;state<=REQUEST;
        end
        REQUEST: if(ack) begin
            state<=READ;byte_count<=0;timer<=0;signature<=0;
            name_match<=0;entry_ok<=0;found<=0;root_end<=0;chain_bad<=0;
        end
        READ: begin
            if(valid) begin
                timer<=0;byte_count<=byte_count+1'b1;
                if(byte_count==510) signature[7:0]<=data;
                if(byte_count==511) signature[15:8]<=data;
                case(kind)
                BOOT: case(byte_count)
                    450:partition_type<=data;
                    454:partition_lba[0+:8]<=data;
                    455:partition_lba[8+:8]<=data;
                    456:partition_lba[16+:8]<=data;
                    457:partition_lba[24+:8]<=data;
                    458:partition_sectors[0+:8]<=data;
                    459:partition_sectors[8+:8]<=data;
                    460:partition_sectors[16+:8]<=data;
                    461:partition_sectors[24+:8]<=data;
                    default:;
                endcase
                BPB: case(byte_count)
                    11:bytes_per_sector[0+:8]<=data;
                    12:bytes_per_sector[8+:8]<=data;
                    13:spc<=data;
                    14:reserved[0+:8]<=data;
                    15:reserved[8+:8]<=data;
                    16:fats<=data;
                    17:root_entries[0+:8]<=data;
                    18:root_entries[8+:8]<=data;
                    22:fat16[0+:8]<=data;
                    23:fat16[8+:8]<=data;
                    32:total_sectors[0+:8]<=data;
                    33:total_sectors[8+:8]<=data;
                    34:total_sectors[16+:8]<=data;
                    35:total_sectors[24+:8]<=data;
                    36:fat_size[0+:8]<=data;
                    37:fat_size[8+:8]<=data;
                    38:fat_size[16+:8]<=data;
                    39:fat_size[24+:8]<=data;
                    40:flags[0+:8]<=data;
                    41:flags[8+:8]<=data;
                    44:root_cluster[0+:8]<=data;
                    45:root_cluster[8+:8]<=data;
                    46:root_cluster[16+:8]<=data;
                    47:root_cluster[24+:8]<=data;
                    default:;
                endcase
                ROOT: begin
                    if(byte_count[4:0]==0) begin
                        name_match<=(data=="B");entry_ok<=0;
                        entry_cluster<=0;entry_bytes<=0;
                        if(data==0) root_end<=1;
                    end else if(byte_count[4:0]<=10) begin
                        if(data!=name_byte(byte_count[3:0])) name_match<=0;
                    end
                    case(byte_count[4:0])
                        11:entry_ok<=!(data[4] || data[3]) && (data!=8'h0f);
                        20:entry_cluster[23:16]<=data;
                        21:entry_cluster[31:24]<=data;
                        26:entry_cluster[7:0]<=data;
                        27:entry_cluster[15:8]<=data;
                        28:entry_bytes[7:0]<=data;
                        29:entry_bytes[15:8]<=data;
                        30:entry_bytes[23:16]<=data;
                        31:entry_bytes[31:24]<=data;
                        default:;
                    endcase
                    if(byte_count[4:0]==31 && name_match && entry_ok && !root_end && !found) begin
                        found<=1;first_cluster<=entry_cluster[27:0];
                        library_bytes<={data,entry_bytes[23:0]};
                    end
                end
                ROOT_FAT,VERIFY: begin
                    case(byte_count[1:0])
                        0:fat_word[7:0]<=data;
                        1:fat_word[15:8]<=data;
                        2:fat_word[23:16]<=data;
                        3:begin
                            if(kind==ROOT_FAT && byte_count[8:2]==root_cluster[6:0])
                                root_next<=decoded_fat;
                            if(kind==VERIFY && current_fat_index>=first_cluster && current_fat_index<=last_cluster) begin
                                if(current_fat_index==last_cluster) begin
                                    if(decoded_fat<32'h0ffffff8) chain_bad<=1;
                                end else if(decoded_fat!=current_fat_index+1'b1) chain_bad<=1;
                            end
                        end
                    endcase
                end
                endcase
            end else if(timer<TIMEOUT_CYCLES) timer<=timer+1'b1;
            if(sector_end) begin
                if(byte_count!=512) begin fault<=1;state<=ERROR;end
                else state<=CHECK;
            end else if(timer==TIMEOUT_CYCLES) begin fault<=1;state<=ERROR;end
        end
        CHECK: case(kind)
            BOOT: begin
                if(signature!=16'haa55 ||
                   (partition_type!=8'h0b && partition_type!=8'h0c) ||
                   partition_lba==0 || partition_sectors==0 ||
                   partition_lba+partition_sectors<partition_lba) begin
                    fault<=2;state<=ERROR;
                end else begin kind<=BPB;sector<=partition_lba;state<=REQUEST;end
            end
            BPB: begin
                case(spc)
                    1:cluster_shift<=0;2:cluster_shift<=1;4:cluster_shift<=2;
                    8:cluster_shift<=3;16:cluster_shift<=4;32:cluster_shift<=5;
                    64:cluster_shift<=6;128:cluster_shift<=7;
                    default:cluster_shift<=15;
                endcase
                if(signature!=16'haa55 || bytes_per_sector!=512 || reserved==0 ||
                   (fats!=1 && fats!=2) || fat16!=0 || root_entries!=0 ||
                   spc==0 || (spc&(spc-1'b1))!=0 || fat_size==0 ||
                   fat_size>32'h00100000 || total_sectors>partition_sectors ||
                   total_sectors<=(reserved+(fat_size<<1)) ||
                   (flags[7] && flags[3:0]>=fats)) begin fault<=2;state<=ERROR;end
                else begin
                    fat_base<=partition_lba+reserved+
                              ((flags[7] && flags[3:0]==1)?fat_size:32'd0);
                    data_base<=partition_lba+reserved+((fats==2)?(fat_size<<1):fat_size);
                    volume_end<=partition_lba+total_sectors;
                    kind<=ROOT;state<=GEOMETRY;
                end
            end
            ROOT: begin
                if(found) begin
                    if(first_cluster<2 || first_cluster>max_cluster || library_bytes<1024 ||
                       library_bytes>32'h20000000) begin fault<=4;state<=ERROR;end
                    else begin
                        file_last_sector<=(library_bytes-1'b1)>>9;
                        cluster_offset<=first_cluster-2;
                        state<=FILE_SIZE;
                    end
                end else if(root_end) begin fault<=3;state<=ERROR;end
                else if(root_sector_in_cluster+1<spc) begin
                    root_sector_in_cluster<=root_sector_in_cluster+1'b1;
                    sector<=sector+1'b1;state<=REQUEST;
                end else begin
                    sector<=fat_base+(root_cluster>>7);kind<=ROOT_FAT;state<=REQUEST;
                end
            end
            ROOT_FAT: begin
                if(root_next<2 || root_next>max_cluster || root_hops==31) begin fault<=3;state<=ERROR;end
                else begin
                    root_cluster<=root_next;root_hops<=root_hops+1'b1;
                    root_sector_in_cluster<=0;
                    sector<=data_base+((root_next-2)<<cluster_shift);
                    kind<=ROOT;state<=REQUEST;
                end
            end
            VERIFY: begin
                if(chain_bad) begin fault<=5;state<=ERROR;end
                else if(verify_fat_sector==(last_cluster>>7)) begin ready<=1;state<=DONE;end
                else begin
                    verify_fat_sector<=verify_fat_sector+1'b1;
                    sector<=sector+1'b1;state<=REQUEST;
                end
            end
            default:state<=ERROR;
        endcase
        GEOMETRY:begin
            data_sectors<=volume_end-data_base;
            cluster_offset<=root_cluster-2;
            state<=GEO_SHIFT;
        end
        GEO_SHIFT:begin
            volume_clusters<=data_sectors>>cluster_shift;
            cluster_offset<=cluster_offset<<cluster_shift;
            state<=GEO_ADDR;
        end
        GEO_ADDR:begin
            max_cluster<=volume_clusters+1'b1;
            sector<=data_base+cluster_offset;
            root_sector_in_cluster<=0;
            if(root_cluster<2 || cluster_shift==15 ||
               root_cluster>volume_clusters+1'b1 || volume_clusters+2>(fat_size<<7))
                begin fault<=2;state<=ERROR;end
            else state<=REQUEST;
        end
        FILE_SIZE:begin
            file_last_cluster<=file_last_sector>>cluster_shift;
            cluster_offset<=cluster_offset<<cluster_shift;
            state<=FILE_CLUSTER;
        end
        FILE_CLUSTER:begin
            last_cluster<=first_cluster+file_last_cluster;
            library_sector<=data_base+cluster_offset;
            verify_fat_sector<=first_cluster>>7;
            sector<=fat_base+(first_cluster>>7);kind<=VERIFY;state<=FILE_ADDR;
        end
        FILE_ADDR:begin
            cluster_offset<=library_sector+file_last_sector;
            state<=BOUNDS;
        end
        BOUNDS:begin
            if(last_cluster<first_cluster || last_cluster>max_cluster ||
               cluster_offset<library_sector || cluster_offset>=volume_end)
                begin fault<=4;state<=ERROR;end
            else state<=REQUEST;
        end
        DONE:;
        ERROR:ready<=0;
        default:state<=ERROR;
        endcase
    end
end
endmodule
