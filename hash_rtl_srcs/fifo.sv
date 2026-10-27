`timescale 1ns/1ps

module fifo #(
    parameter DEPTH     = 256,
    parameter KEY_BYTES = 13,
    parameter KEY_BITS  = 104,
    parameter TIMESTAMP = 64
)(
    input  wire clk,
    input  wire rst,          
    input  wire valid_in,

    input  wire [31:0] hash1,
    input  wire [31:0] hash2,
    input  wire [31:0] hash3,

    input  wire [KEY_BITS+TIMESTAMP-1:0] flow_in,

    output reg [$clog2(DEPTH):0] wr_ptr,
    output reg [$clog2(DEPTH):0] rd_ptr
 
);

    localparam PTR_WIDTH = $clog2(DEPTH);

    wire empty;
    wire full;
    wire done;
    wire ready;

    reg [31:0] hash1_mem [0:DEPTH-1];
    reg [31:0] hash2_mem [0:DEPTH-1];
    reg [31:0] hash3_mem [0:DEPTH-1];

    reg [KEY_BITS+TIMESTAMP-1:0] key_mem [0:DEPTH-1];
    reg valid_out;

    reg [31:0] hash1_out;
    reg [31:0] hash2_out;
    reg [31:0] hash3_out;

    reg [KEY_BITS+TIMESTAMP-1:0] key_out;

    assign full =
        (wr_ptr[PTR_WIDTH-1:0] == rd_ptr[PTR_WIDTH-1:0]) &&
        (wr_ptr[PTR_WIDTH] != rd_ptr[PTR_WIDTH]);

    assign empty = (wr_ptr == rd_ptr);


   hash_mapping #(
    .bucket_size (8192),
    .ADDR_WIDTH  (13),
    .KEY_BYTES   (KEY_BYTES),
    .KEY_BITS    (KEY_BITS),
    .TIMESTAMP   (TIMESTAMP)
) u_hash_mapping (
    .clk   (clk),
    .rst   (rst),
    .valid (valid_out),
    .key   (key_out),
    .hash1 (hash1_out),
    .hash2 (hash2_out),
    .hash3 (hash3_out),
    .done  (done),
    .ready (ready)
);
    always @(posedge clk) begin

        if (!rst) begin
            wr_ptr    <= '0;
            rd_ptr    <= '0;
            valid_out <= 1'b0;
            hash1_out <= '0;
            hash2_out <= '0;
            hash3_out <= '0;
            key_out   <= '0;
        end
        else begin
            if (valid_in && !full) begin

                hash1_mem[wr_ptr[PTR_WIDTH-1:0]] <= hash1;
                hash2_mem[wr_ptr[PTR_WIDTH-1:0]] <= hash2;
                hash3_mem[wr_ptr[PTR_WIDTH-1:0]] <= hash3;
                key_mem[wr_ptr[PTR_WIDTH-1:0]]   <= flow_in;
                wr_ptr <= wr_ptr + 1'b1;
            end

            if (valid_out && ready) begin
                rd_ptr    <= rd_ptr + 1'b1;
                valid_out <= 1'b0;
            end

            if (!valid_out && !empty) begin
                hash1_out <= hash1_mem[rd_ptr[PTR_WIDTH-1:0]];
                hash2_out <= hash2_mem[rd_ptr[PTR_WIDTH-1:0]];
                hash3_out <= hash3_mem[rd_ptr[PTR_WIDTH-1:0]];
                key_out   <= key_mem[rd_ptr[PTR_WIDTH-1:0]];
                valid_out <= 1'b1;
            end

        end
    end

endmodule
