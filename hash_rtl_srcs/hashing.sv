`timescale 1ns/1ps

module  hash_values #(
 parameter bucket_size = 8192,
 parameter KEY_BYTES = 13,
 parameter KEY_BITS = 104,
 parameter TIMESTAMP = 64

)(
    input clk,
    input rst,
    input [(KEY_BITS+TIMESTAMP-1):0] key,
    input valid_in,
    output reg [31:0] hash1,
    output reg [31:0] hash2,
    output reg [31:0] hash3,
    output reg [(KEY_BITS+TIMESTAMP-1):0] flow_out, 
    output reg valid_out
);

    function automatic [31:0] toeplitz_hash(
        input [KEY_BITS-1:0] data
    );
        reg [134:0] toeplitz_key;          // Assuming length of keybits=104
        reg [31:0] result;
        integer i;

        begin
            toeplitz_key =
                135'h0d7405c8958894c916f9edb67f5a6bd59e;

            result = 32'b0;
            for (i = 0; i < 104; i = i + 1) begin
                if (data[103-i])
                    result = result ^
                        ((toeplitz_key >> (103-i)) & 32'hFFFFFFFF);
            end
            toeplitz_hash = result;
        end
    endfunction


    reg start;
    reg [(KEY_BITS+TIMESTAMP-1):0] key_in;
    wire [0:KEY_BYTES] valid_in_pip;
    wire [(KEY_BITS+TIMESTAMP-1):0] key_in_pip [0:KEY_BYTES];
    wire [31:0] fnv_hash_in_pip [0:KEY_BYTES];
    wire [31:0] xor_shift_hash_in_pip [0:KEY_BYTES];


    assign valid_in_pip[0] = start;
    assign key_in_pip[0] = key_in;

    assign fnv_hash_in_pip[0] = 32'h811C9DC5;
    assign xor_shift_hash_in_pip[0] = 32'h00000000;


    genvar i;
    generate 
        for (i=0; i<=KEY_BYTES-1; i=i+1) begin : HASH_PIP

            fnv1a_stage #(
                .BYTE_INDEX            (i)
            ) u_fnv1a_stage (
                .clk                   (clk),
                .rst                   (rst),
                .valid_in              (valid_in_pip[i]),
                .key_in                (key_in_pip[i]),
                //HASH_IN
                .fnv_hash_in           (fnv_hash_in_pip[i]),
                .xor_shift_hash_in     (xor_shift_hash_in_pip[i]),
                .valid_out             (valid_in_pip[i+1]),
                .key_out               (key_in_pip[i+1]),
                // HASH_OUT
                .fnv_hash_out          (fnv_hash_in_pip[i+1]),
                .xor_shift_hash_out    (xor_shift_hash_in_pip[i+1])
            );


        end
              
    endgenerate

    always @(posedge clk) begin
        if (!rst) begin
            start <= 1'b0;
            valid_out <= 1'b0;
            key_in <= 168'b0;
            hash1 <= 32'b0;
            hash2 <= 32'b0;
            hash3 <= 32'b0;
            flow_out <= 168'b0;
        end
        else begin
            start <= valid_in;
            key_in <= key; 
            valid_out <= valid_in_pip[KEY_BYTES];
            if (valid_in_pip[KEY_BYTES]) begin
                hash1 <= fnv_hash_in_pip[KEY_BYTES];
                hash2 <= xor_shift_hash_in_pip[KEY_BYTES];
                hash3 <= toeplitz_hash (key_in_pip[KEY_BYTES][103:0]);    
                flow_out <= key_in_pip[KEY_BYTES];
            end
        end
    end

endmodule