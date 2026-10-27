`timescale 1ns/1ps

module hash_top #(
    parameter KEY_BITS  = 104,
    parameter TIMESTAMP = 64,
    parameter DEPTH     = 256
)(
    input  wire clk,
    input  wire rst,
    input  wire valid,
    input  wire [KEY_BITS+TIMESTAMP-1:0] key,

    output wire stop
);

    localparam integer PTR_WIDTH       = $clog2(DEPTH);
    localparam integer PIPELINE_STAGES = 13;
    localparam integer FIFO_RESERVE    = PIPELINE_STAGES + 1;

    logic [31:0] hash1;
    logic [31:0] hash2;
    logic [31:0] hash3;

    logic [KEY_BITS+TIMESTAMP-1:0] flow_out;
    logic valid_out;
    logic valid_in;

    wire [PTR_WIDTH:0] wr_ptr;
    wire [PTR_WIDTH:0] rd_ptr;

    wire [PTR_WIDTH:0] fifo_count;
    wire [PTR_WIDTH:0] fifo_free;
    wire full;

    // Calculate FIFO occupancy and remaining capacity.
    // Extended pointers include the wrap bit.
    assign fifo_count = wr_ptr - rd_ptr;
    assign fifo_free  = DEPTH - fifo_count;

    // Stop accepting new inputs when 14 or fewer slots remain.
    assign valid_in = valid && (fifo_free > FIFO_RESERVE);
    assign stop = (fifo_free <= FIFO_RESERVE);

    hash_values #(
        .bucket_size (8192),
        .KEY_BYTES   (13),
        .KEY_BITS    (KEY_BITS),
        .TIMESTAMP   (TIMESTAMP)
    ) u_hash_values (
        .clk       (clk),
        .rst       (rst),
        .key       (key),
        .valid_in  (valid_in),
        .hash1     (hash1),
        .hash2     (hash2),
        .hash3     (hash3),
        .flow_out  (flow_out),
        .valid_out (valid_out)
    );

    fifo #(
        .DEPTH     (DEPTH),
        .KEY_BYTES (13),
        .KEY_BITS  (KEY_BITS),
        .TIMESTAMP (TIMESTAMP)
    ) u_fifo (
        .clk      (clk),
        .rst      (rst),
        .valid_in (valid_out),
        .hash1    (hash1),
        .hash2    (hash2),
        .hash3    (hash3),
        .flow_in  (flow_out),
        .wr_ptr   (wr_ptr),
        .rd_ptr   (rd_ptr)
   
    );

endmodule