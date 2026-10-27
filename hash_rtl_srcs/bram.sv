`timescale 1ns / 1ps


module flow_table_bram #(
    parameter integer TABLE_SIZE = 8192,
    parameter integer ADDR_WIDTH = 13,
    parameter integer KEY_WIDTH  = 104,
    parameter integer TIME_WIDTH = 64,
    parameter integer ENTRY_WIDTH = 1 + KEY_WIDTH + TIME_WIDTH
)(
    input wire clk,
    // -------------------------------
    // BRAM read interface
    // -------------------------------
    input wire                  rd_en,
    input wire [ADDR_WIDTH-1:0] rd_addr,

    output reg                  rd_valid,
    output reg                  rd_occupied,
    output reg [KEY_WIDTH-1:0]  rd_key,
    output reg [TIME_WIDTH-1:0] rd_timestamp,

    // -------------------------------
    // BRAM write interface
    // -------------------------------
    input wire                  wr_en,
    input wire [ADDR_WIDTH-1:0] wr_addr,
    input wire                  wr_occupied,
    input wire [KEY_WIDTH-1:0]  wr_key,
    input wire [TIME_WIDTH-1:0] wr_timestamp
);

    // One entry per address:
    // [168]     = occupied/valid bit
    // [167:64]  = 104-bit flow key
    // [63:0]    = 64-bit timestamp

    reg [ENTRY_WIDTH-1:0] mem [0:TABLE_SIZE-1];

    // Initialize all BRAM entries to zero at FPGA configuration
    integer i;

    initial begin
        for (i = 0; i < TABLE_SIZE; i = i + 1) begin
            mem[i] = {ENTRY_WIDTH{1'b0}};
        end
    end

    // Synchronous read port
    always @(posedge clk) begin
      
        if (rd_en) begin
            rd_occupied  <= mem[rd_addr][ENTRY_WIDTH-1];
            rd_key       <= mem[rd_addr][TIME_WIDTH + KEY_WIDTH - 1 : TIME_WIDTH];
            rd_timestamp <= mem[rd_addr][TIME_WIDTH-1:0];
            rd_valid     <= 1'b1;
        end
        else begin
            rd_valid <= 1'b0;
        end
    end

    // Synchronous write port
    always @(posedge clk) begin
        if (wr_en) begin
            mem[wr_addr] <= {
                wr_occupied,
                wr_key,
                wr_timestamp
            };
        end
    end

endmodule