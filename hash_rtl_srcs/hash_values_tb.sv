`timescale 1ns/1ps

module tb_hash_values;

    parameter KEY_BITS = 104;
    parameter TIMESTAMP = 64;
    parameter KEY_BYTES = 13;

    reg clk;
    reg rst;
    reg valid_in;
    reg [KEY_BITS+TIMESTAMP-1:0] key;

    wire [31:0] hash1;
    wire [31:0] hash2;
    wire [31:0] hash3;

    wire [KEY_BITS+TIMESTAMP-1:0] flow_out;
    wire valid_out;

    // DUT: Device Under Test
    hash_values #(
        .bucket_size (8192),
        .KEY_BYTES   (KEY_BYTES),
        .KEY_BITS    (KEY_BITS),
        .TIMESTAMP   (TIMESTAMP)
    ) dut (
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

    // 100 MHz clock: 10 ns period
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // Test stimulus
    initial begin

        // Initial values
        rst     = 1'b0;
        valid_in = 1'b0;
        key      = '0;

        // Keep reset active for two rising edges
        repeat (2) @(negedge clk);

        // Release reset
        rst = 1'b1;

        // -----------------------------------------
        // Packet 1
        // -----------------------------------------
        @(negedge clk);
        valid_in = 1'b1;
        key = {64'd1000, 32'hC0A80101, 32'hC0A80102,
               16'd5000, 16'd80, 8'd6};

        // -----------------------------------------
        // Packet 2: immediately next cycle
        // -----------------------------------------
        @(negedge clk);
        valid_in = 1'b1;
        key = {64'd1010, 32'hC0A80103, 32'hC0A80104,
               16'd5001, 16'd443, 8'd6};

        // -----------------------------------------
        // Packet 3: immediately next cycle
        // -----------------------------------------
        @(negedge clk);
        valid_in = 1'b1;
        key = {64'd1020, 32'h0A000001, 32'h0A000002,
               16'd6000, 16'd53, 8'd17};

        // -----------------------------------------
        // Stop input traffic
        // -----------------------------------------
        @(negedge clk);
        valid_in = 1'b0;
        key = '0;

        $display("[%0t ns] Input stopped: valid_in=0, key=0", $time);

        // Wait for all three packets to leave the pipeline
        repeat (20) @(negedge clk);

        $display("[%0t ns] Test completed.", $time);
        $finish;
    end

    // Monitor output transactions
    always @(negedge clk) begin
        if (valid_out) begin
            $display(
                "[%0t ns] OUTPUT VALID", $time
            );

            $display("  flow_out = %h", flow_out);
            $display("  timestamp = %0d", flow_out[167:104]);
            $display("  flow_key  = %h", flow_out[103:0]);
            $display("  hash1 (FNV-1a) = %h", hash1);
            $display("  hash2 (XOR-shift) = %h", hash2);
            $display("  hash3 (Toeplitz) = %h", hash3);

            $display("--------------------------------------");
        end
    end

endmodule