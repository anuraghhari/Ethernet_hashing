`timescale 1ns/1ps

module fnv1a_stage #(
    parameter integer BYTE_INDEX = 0,
    parameter KEY_BITS = 104,
    parameter TIMESTAMP = 64
)(
    input  wire         clk,
    input  wire         rst,

    input  wire         valid_in,
    input  wire [(KEY_BITS+TIMESTAMP-1):0] key_in,

    //HASH_IN
    input  wire [31:0]  fnv_hash_in,
    input  wire [31:0]  xor_shift_hash_in,

    output reg          valid_out,
    output reg  [(KEY_BITS+TIMESTAMP-1):0] key_out,

    // HASH_OUT
    output reg  [31:0]  fnv_hash_out,
    output reg  [31:0]  xor_shift_hash_out
);

    // =========================================================
    // FNV-1a CONSTANT
    // =========================================================

    localparam [31:0] FNV_PRIME = 32'h01000193;

    // =========================================================
    // EXTRACT CURRENT BYTE
    // =========================================================

    wire [7:0] current_byte;
    assign current_byte = key_in[103 - (BYTE_INDEX * 8) -: 8];

    // =========================================================
    // FNV-1a HASH CALCULATION
    // =========================================================

    // Step 1: XOR the current byte with the FNV state.
    wire [31:0] fnv_xor_result;
    assign fnv_xor_result = fnv_hash_in ^ {24'b0, current_byte};

    // Step 2: Multiply by the FNV prime.
    wire [63:0] fnv_product;
    assign fnv_product = fnv_xor_result * FNV_PRIME;

    // =========================================================
    // XOR-SHIFT HASH CALCULATION
    // =========================================================

    // Step 1: XOR the current byte into the hash state.
    wire [31:0] xs_step1;
    assign xs_step1 = xor_shift_hash_in ^ {24'b0, current_byte};

    // Step 2: Left shift by 13 and XOR.
    wire [31:0] xs_step2;
    assign xs_step2 = xs_step1 ^ (xs_step1 << 13);

    // Step 3: Right shift by 17 and XOR.
    wire [31:0] xs_step3;
    assign xs_step3 = xs_step2 ^ (xs_step2 >> 17);

    // Step 4: Left shift by 5 and XOR.
    wire [31:0] xs_next_hash;
    assign xs_next_hash = xs_step3 ^ (xs_step3 << 5);

    // =========================================================
    // REGISTER OUTPUTS
    // =========================================================

    always @(posedge clk) begin
        if (!rst) begin
            valid_out         <= 1'b0;
            key_out            <= 168'b0;
            fnv_hash_out       <= 32'b0;
            xor_shift_hash_out <= 32'b0;
        end
        else begin
            valid_out <= valid_in;
            key_out <= key_in;
            fnv_hash_out <= fnv_product[31:0];
            xor_shift_hash_out <= xs_next_hash;
        end
    end
endmodule