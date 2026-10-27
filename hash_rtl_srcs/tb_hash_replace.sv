`timescale 1ns/1ps

// Tests the REPLACE_ENTRY path in hash_mapping.
//
// Scenario:
//   - Hash1 address occupied by Flow A, timestamp 100
//   - Hash2 address occupied by Flow B, timestamp 200
//   - Hash3 address occupied by Flow C, timestamp 300
//   - Send one new flow with timestamp 4660
//
// Expected:
//   - Hash1 entry is replaced (smallest timestamp)
//   - Hash2 and Hash3 entries remain unchanged
//
// Compile in Vivado by adding this file as the simulation top.
// Icarus example:
// iverilog -g2012 -s tb_hash_replace -o simv \
//   tb_hash_replace.sv hash_top.sv hashing.sv fnv_xor_pip.sv \
//   hash_mapping.sv bram.sv
// vvp simv

module tb_hash_replace;

    localparam integer KEY_BITS   = 104;
    localparam integer TIME_BITS  = 64;
    localparam integer TABLE_SIZE = 8192;
    localparam integer ENTRY_WIDTH = 1 + KEY_BITS + TIME_BITS;

    reg clk = 1'b0;
    reg rst = 1'b0;
    reg valid = 1'b0;
    reg [KEY_BITS+TIME_BITS-1:0] key = '0;

    hash_top #(
        .KEY_BITS(KEY_BITS),
        .TIMESTAMP(TIME_BITS)
    ) dut (
        .clk   (clk),
        .rst   (rst),
        .valid (valid),
        .key   (key)
    );

    always #5 clk = ~clk;

    reg [KEY_BITS-1:0] new_flow;
    reg [TIME_BITS-1:0] new_timestamp;

    reg [KEY_BITS-1:0] old_flow_1;
    reg [KEY_BITS-1:0] old_flow_2;
    reg [KEY_BITS-1:0] old_flow_3;

    localparam [TIME_BITS-1:0] TS_1 = 64'd100;
    localparam [TIME_BITS-1:0] TS_2 = 64'd200;
    localparam [TIME_BITS-1:0] TS_3 = 64'd300;

    integer i;
    integer addr1, addr2, addr3;
    integer cycles;

    initial begin
        // Incoming flow and timestamp.
        new_flow      = 104'h0123456789ABCDEFFEDCBA9876;
        new_timestamp = 64'd4660;

        // Distinct pre-existing flow keys.
        old_flow_1 = 104'h11111111111111111111111111;
        old_flow_2 = 104'h22222222222222222222222222;
        old_flow_3 = 104'h33333333333333333333333333;

        // Initialize simulation BRAM. This is a testbench-only action.
        for (i = 0; i < TABLE_SIZE; i = i + 1)
            dut.u_hash_mapping.u_flow_table_bram.mem[i] = '0;

        // Active-low reset.
        repeat (4) @(negedge clk);
        rst = 1'b1;
        repeat (2) @(negedge clk);

        // Send exactly one packet.
        $display("\n[TB] Sending one packet for replacement test...");
        key   = {new_timestamp, new_flow};
        valid = 1'b1;
        @(negedge clk);
        valid = 1'b0;
        key   = '0;

        // Wait until hash_values produces the three hashes.
        cycles = 0;
        while (dut.u_hash_values.valid_out !== 1'b1 && cycles < 100) begin
            @(posedge clk);
            #1;
            cycles = cycles + 1;
        end

        if (dut.u_hash_values.valid_out !== 1'b1)
            $fatal(1, "[FAIL] Hash pipeline timed out.");

        // Candidate addresses are the low 13 bits of each hash.
        addr1 = dut.u_hash_values.hash1[12:0];
        addr2 = dut.u_hash_values.hash2[12:0];
        addr3 = dut.u_hash_values.hash3[12:0];

        $display("[TB] Hash1 = 0x%08h -> address %0d",
                 dut.u_hash_values.hash1, addr1);
        $display("[TB] Hash2 = 0x%08h -> address %0d",
                 dut.u_hash_values.hash2, addr2);
        $display("[TB] Hash3 = 0x%08h -> address %0d",
                 dut.u_hash_values.hash3, addr3);

        if ((addr1 == addr2) || (addr1 == addr3) || (addr2 == addr3))
            $fatal(1, "[FAIL] Hash addresses are not distinct.");

        // Pre-fill all three candidate entries with different flows.
        // Entry format: {occupied, 104-bit flow key, 64-bit timestamp}.
        dut.u_hash_mapping.u_flow_table_bram.mem[addr1] =
            {1'b1, old_flow_1, TS_1};

        dut.u_hash_mapping.u_flow_table_bram.mem[addr2] =
            {1'b1, old_flow_2, TS_2};

        dut.u_hash_mapping.u_flow_table_bram.mem[addr3] =
            {1'b1, old_flow_3, TS_3};

        $display("[TB] Pre-filled all candidates:");
        $display("     Hash1: address=%0d timestamp=%0d", addr1, TS_1);
        $display("     Hash2: address=%0d timestamp=%0d", addr2, TS_2);
        $display("     Hash3: address=%0d timestamp=%0d", addr3, TS_3);
        $display("[TB] All three entries are occupied; replacement is required.");

        // Wait for the mapping operation to complete.
        cycles = 0;
        while (dut.done !== 1'b1 && cycles < 100) begin
            @(posedge clk);
            #1;
            cycles = cycles + 1;
        end

        if (dut.done !== 1'b1)
            $fatal(1, "[FAIL] Mapping FSM did not assert done.");

        $display("[TB] Mapping asserted done.");

        // Hash1 must be replaced because timestamp 100 is the minimum.
        if (dut.u_hash_mapping.u_flow_table_bram.mem[addr1][ENTRY_WIDTH-1] !== 1'b1)
            $fatal(1, "[FAIL] Hash1 entry is not marked occupied after replacement.");

        if (dut.u_hash_mapping.u_flow_table_bram.mem[addr1][TIME_BITS+KEY_BITS-1:TIME_BITS]
            !== new_flow)
            $fatal(1, "[FAIL] Hash1 did not receive the incoming flow key.");

        if (dut.u_hash_mapping.u_flow_table_bram.mem[addr1][TIME_BITS-1:0]
            !== new_timestamp)
            $fatal(1, "[FAIL] Hash1 did not receive the incoming timestamp.");

        // Hash2 must remain unchanged.
        if (dut.u_hash_mapping.u_flow_table_bram.mem[addr2][TIME_BITS+KEY_BITS-1:TIME_BITS]
            !== old_flow_2)
            $fatal(1, "[FAIL] Hash2 flow key was unexpectedly changed.");

        if (dut.u_hash_mapping.u_flow_table_bram.mem[addr2][TIME_BITS-1:0]
            !== TS_2)
            $fatal(1, "[FAIL] Hash2 timestamp was unexpectedly changed.");

        // Hash3 must remain unchanged.
        if (dut.u_hash_mapping.u_flow_table_bram.mem[addr3][TIME_BITS+KEY_BITS-1:TIME_BITS]
            !== old_flow_3)
            $fatal(1, "[FAIL] Hash3 flow key was unexpectedly changed.");

        if (dut.u_hash_mapping.u_flow_table_bram.mem[addr3][TIME_BITS-1:0]
            !== TS_3)
            $fatal(1, "[FAIL] Hash3 timestamp was unexpectedly changed.");

        $display("\n[PASS] Replacement test passed.");
        $display("[PASS] All three candidate addresses were occupied.");
        $display("[PASS] Minimum timestamp was at hash1 (timestamp 100).");
        $display("[PASS] Hash1 was replaced with the incoming flow.");
        $display("[PASS] Hash2 and Hash3 remained unchanged.");
        $finish;
    end

    initial begin
        #5000;
        $fatal(1, "[FAIL] Global simulation timeout.");
    end

endmodule
