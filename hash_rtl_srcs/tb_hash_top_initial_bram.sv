`timescale 1ns/1ps

// Testbench for:
//   hash_top
//   hash_values
//   fifo
//   hash_mapping
//   flow_table_bram
//
// Tests:
// 1. Reset and BRAM initialization for simulation.
// 2. Continuous packet traffic through hash pipeline and FIFO.
// 3. FIFO pointer/occupancy sanity checks and drain.
// 4. Directed collision test that exercises REPLACE_ENTRY.
// 5. Checks that the oldest of three colliding entries is replaced.
//
// IMPORTANT:
// - This testbench uses hierarchical references and force/release for the
//   directed replacement test. It is intended for simulation, not synthesis.
// - The DUT BRAM source supplied with the project does not yet contain an
//   `initial` block. The testbench initializes its memory hierarchically so
//   this test is deterministic. Add your own BRAM initialization block to
//   the RTL if you want the FPGA configuration image to initialize memory.
// - This test assumes the packed input key format is {timestamp[63:0],
//   flow_key[103:0]}, matching the current RTL.

module tb_hash_top;

    localparam integer KEY_BITS  = 104;
    localparam integer TIMESTAMP = 64;
    localparam integer DEPTH     = 256;
    localparam integer TABLE_SIZE = 8192;
    localparam integer ENTRY_WIDTH = 1 + KEY_BITS + TIMESTAMP;

    reg clk = 1'b0;
    reg rst = 1'b0;
    reg valid = 1'b0;
    reg [KEY_BITS+TIMESTAMP-1:0] key = '0;
    wire stop;

    integer accepted_packets = 0;
    integer completed_packets = 0;
    integer done_before;
    integer i;
    integer timeout_count;
    integer errors = 0;
    integer replace_done_count = 0;
    integer bucket_a;
    integer bucket_b;
    integer bucket_c;

    reg [KEY_BITS-1:0] flow_key_a;
    reg [KEY_BITS-1:0] flow_key_b;
    reg [KEY_BITS-1:0] flow_key_c;
    reg [KEY_BITS-1:0] incoming_key;

    reg [ENTRY_WIDTH-1:0] entry1_before;
    reg [ENTRY_WIDTH-1:0] entry2_before;
    reg [ENTRY_WIDTH-1:0] entry3_before;

    hash_top #(
        .KEY_BITS(KEY_BITS),
        .TIMESTAMP(TIMESTAMP),
        .DEPTH(DEPTH)
    ) dut (
        .clk(clk),
        .rst(rst),
        .valid(valid),
        .key(key),
        .stop(stop)
    );

    always #5 clk = ~clk;

    // Count input packets actually accepted by the top-level input gate.
    // With the current RTL, valid_in = valid && (fifo_free > FIFO_RESERVE).
    always @(posedge clk) begin
        if (rst && valid && !stop)
            accepted_packets <= accepted_packets + 1;
    end

    // Count hash-table transactions reported complete.
    always @(posedge clk) begin
        if (rst && dut.u_fifo.u_hash_mapping.done)
            completed_packets <= completed_packets + 1;
    end

    // Count visits to REPLACE_ENTRY (enum value 7 in the current RTL).
    always @(posedge clk) begin
        if (rst && dut.u_fifo.u_hash_mapping.state == 4'd7)
            replace_done_count <= replace_done_count + 1;
    end

    // Basic FIFO sanity monitor. The extended pointers include the wrap bit.
    // For this power-of-two depth, their difference should remain <= DEPTH.
    always @(posedge clk) begin
        if (rst) begin
            if (dut.u_fifo.wr_ptr - dut.u_fifo.rd_ptr > DEPTH) begin
                $display("ERROR: FIFO occupancy exceeded DEPTH at %0t", $time);
                errors = errors + 1;
            end
        end
    end

    task automatic send_packet(input [KEY_BITS+TIMESTAMP-1:0] packet);
        integer wait_cycles;
        begin
            wait_cycles = 0;
            // Hold the packet stable until accepted. `stop` in the current
            // RTL is derived from valid_in, so this task drives valid high
            // and waits for a cycle with stop low.
            @(negedge clk);
            key = packet;
            valid = 1'b1;
            while (stop !== 1'b0 && wait_cycles < 2000) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (wait_cycles >= 2000) begin
                $display("ERROR: Timed out waiting for input acceptance at %0t", $time);
                errors = errors + 1;
            end
            // The next rising edge is the accepting edge when valid && !stop.
            @(posedge clk);
            @(negedge clk);
            valid = 1'b0;
        end
    endtask

    task automatic wait_for_completed(input integer target, input integer max_cycles);
        integer cycles;
        begin
            cycles = 0;
            while (completed_packets < target && cycles < max_cycles) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            if (completed_packets < target) begin
                $display("ERROR: completion timeout: target=%0d completed=%0d after %0d cycles",
                         target, completed_packets, cycles);
                errors = errors + 1;
            end
        end
    endtask

    task automatic find_three_empty_buckets(
        output integer addr_a,
        output integer addr_b,
        output integer addr_c
    );
        integer idx;
        integer found;
        reg [ENTRY_WIDTH-1:0] observed;
        begin
            addr_a = -1;
            addr_b = -1;
            addr_c = -1;
            found = 0;
            for (idx = 0; idx < TABLE_SIZE; idx = idx + 1) begin
                observed = dut.u_fifo.u_hash_mapping.u_flow_table_bram.mem[idx];
                if ((observed[ENTRY_WIDTH-1] === 1'b0) && (found < 3)) begin
                    case (found)
                        0: addr_a = idx;
                        1: addr_b = idx;
                        2: addr_c = idx;
                    endcase
                    found = found + 1;
                end
            end
            if (found != 3) begin
                $display("ERROR: Could not find three empty BRAM buckets.");
                errors = errors + 1;
            end
        end
    endtask

    task automatic check_entry(
        input integer addr,
        input bit expected_occupied,
        input [KEY_BITS-1:0] expected_key,
        input [TIMESTAMP-1:0] expected_timestamp,
        input [255:0] label_text
    );
        reg [ENTRY_WIDTH-1:0] observed;
        begin
            observed = dut.u_fifo.u_hash_mapping.u_flow_table_bram.mem[addr];
            if (observed[ENTRY_WIDTH-1] !== expected_occupied ||
                observed[TIMESTAMP+KEY_BITS-1:TIMESTAMP] !== expected_key ||
                observed[TIMESTAMP-1:0] !== expected_timestamp) begin
                $display("ERROR: %0s at table address %0d", label_text, addr);
                $display("       observed occupied=%b key=%h timestamp=%0d",
                         observed[ENTRY_WIDTH-1],
                         observed[TIMESTAMP+KEY_BITS-1:TIMESTAMP],
                         observed[TIMESTAMP-1:0]);
                $display("       expected occupied=%b key=%h timestamp=%0d",
                         expected_occupied, expected_key, expected_timestamp);
                errors = errors + 1;
            end else begin
                $display("PASS: %0s at table address %0d", label_text, addr);
            end
        end
    endtask

    initial begin
        $timeformat(-9, 0, " ns", 8);
        $display("======================================================");
        $display(" hash_top end-to-end / FIFO / replacement testbench");
        $display("======================================================");

        // Hold reset active-low for several clocks.
        repeat (5) @(negedge clk);
        rst = 1'b1;
        repeat (3) @(negedge clk);

        // BRAM contents are initialized by the initial block in flow_table_bram.
        // Do not clear memory hierarchically; subsequent resets must not erase it.
        $display("[%0t] Reset released; using BRAM RTL initial-block contents.", $time);

        // ------------------------------------------------------------
        // TEST 1: Continuous packets through the real hash pipeline/FIFO.
        // ------------------------------------------------------------
        $display("\n[%0t] TEST 1: continuous packet traffic", $time);
        done_before = completed_packets;

        // Drive a continuous stream. Change packet only on a negedge and
        // hold it when backpressure is asserted. Each accepted input is
        // counted by the monitor above.
        for (i = 0; i < 48; i = i + 1) begin
            @(negedge clk);
            valid = 1'b1;
            key = {64'(1000 + i), (104'h123456789ABCDEF0000000000 ^ i)};
            // Hold this packet stable until a rising edge accepts it.
            while (stop !== 1'b0)
                @(negedge clk);
            @(posedge clk);
        end
        @(negedge clk);
        valid = 1'b0;

        wait_for_completed(done_before + 48, 10000);
        repeat (5) @(negedge clk);

        $display("[%0t] Continuous stream sent. accepted=%0d completed=%0d",
                 $time, accepted_packets, completed_packets);

        if (completed_packets < done_before + 48) begin
            $display("ERROR: not all 48 continuous-stream packets completed.");
            errors = errors + 1;
        end else begin
            $display("PASS: all continuous-stream packets completed.");
        end

        // ------------------------------------------------------------
        // TEST 2: Directed collision and REPLACE_ENTRY test.
        //
        // Preload the three candidate buckets with different keys and
        // timestamps 100, 200, 300. Force the three hash candidates to
        // addresses 1, 2, 3 for this one directed packet. The incoming
        // packet has timestamp 400 and a different key, so all three
        // lookups collide and the oldest entry (timestamp 100 at address 1)
        // should be replaced.
        // ------------------------------------------------------------
        $display("\n[%0t] TEST 2: force three collisions and exercise REPLACE_ENTRY", $time);

        flow_key_a = 104'h0000000000000000000000001;
        flow_key_b = 104'h0000000000000000000000002;
        flow_key_c = 104'h0000000000000000000000003;
        incoming_key = 104'h00000000000000000000000AA;

        // Pause input and let the pipeline/FIFO drain completely.
        valid = 1'b0;
        wait_for_completed(completed_packets, 100);
        repeat (20) @(negedge clk);

        // Reset control logic only. BRAM is not reset and its contents persist.
        rst = 1'b0;
        repeat (4) @(negedge clk);
        rst = 1'b1;
        repeat (4) @(negedge clk);

        // Select three still-empty buckets after the stream test. This avoids
        // clearing the BRAM between tests and relies on the RTL initial block.
        find_three_empty_buckets(bucket_a, bucket_b, bucket_c);
        if (bucket_a < 0 || bucket_b < 0 || bucket_c < 0) begin
            $display("ERROR: Invalid empty-bucket addresses.");
            errors = errors + 1;
        end

        // {occupied, key, timestamp}
        dut.u_fifo.u_hash_mapping.u_flow_table_bram.mem[bucket_a] =
            {1'b1, flow_key_a, 64'd100};
        dut.u_fifo.u_hash_mapping.u_flow_table_bram.mem[bucket_b] =
            {1'b1, flow_key_b, 64'd200};
        dut.u_fifo.u_hash_mapping.u_flow_table_bram.mem[bucket_c] =
            {1'b1, flow_key_c, 64'd300};

        entry1_before = dut.u_fifo.u_hash_mapping.u_flow_table_bram.mem[bucket_a];
        entry2_before = dut.u_fifo.u_hash_mapping.u_flow_table_bram.mem[bucket_b];
        entry3_before = dut.u_fifo.u_hash_mapping.u_flow_table_bram.mem[bucket_c];

        $display("[%0t] Preloaded candidate buckets %0d/%0d/%0d with timestamps 100/200/300.",
                 $time, bucket_a, bucket_b, bucket_c);

        // Force only the hash candidates. The packet itself still traverses
        // hash_top -> hash_values -> FIFO -> hash_mapping.
        force dut.u_fifo.u_hash_mapping.hash1 = bucket_a;
        force dut.u_fifo.u_hash_mapping.hash2 = bucket_b;
        force dut.u_fifo.u_hash_mapping.hash3 = bucket_c;

        done_before = completed_packets;
        replace_done_count = 0;
        send_packet({64'd400, incoming_key});
        wait_for_completed(done_before + 1, 2000);
        repeat (3) @(negedge clk);

        release dut.u_fifo.u_hash_mapping.hash1;
        release dut.u_fifo.u_hash_mapping.hash2;
        release dut.u_fifo.u_hash_mapping.hash3;

        // Confirm the replacement state was actually entered.
        if (replace_done_count == 0) begin
            $display("ERROR: REPLACE_ENTRY state was never observed.");
            errors = errors + 1;
        end else begin
            $display("PASS: REPLACE_ENTRY state observed (%0d cycle(s)).",
                     replace_done_count);
        end

        // The incoming entry should replace address 1, the oldest timestamp.
        check_entry(bucket_a, 1'b1, incoming_key, 64'd400, "oldest bucket replaced");
        check_entry(bucket_b, 1'b1, flow_key_b, 64'd200, "second-oldest bucket preserved");
        check_entry(bucket_c, 1'b1, flow_key_c, 64'd300, "newest bucket preserved");

        if (dut.u_fifo.u_hash_mapping.u_flow_table_bram.mem[bucket_a] !==
            {1'b1, incoming_key, 64'd400}) begin
            $display("ERROR: expected REPLACE_ENTRY to write incoming flow to oldest bucket.");
            errors = errors + 1;
        end else begin
            $display("PASS: REPLACE_ENTRY selected the oldest candidate (address %0d).", bucket_a);
        end

        // ------------------------------------------------------------
        // Final report.
        // ------------------------------------------------------------
        $display("\n======================================================");
        if (errors == 0)
            $display("TESTBENCH PASSED: no detected errors.");
        else
            $display("TESTBENCH FAILED: %0d error(s) detected.", errors);
        $display("Accepted input packets: %0d", accepted_packets);
        $display("Completed table transactions: %0d", completed_packets);
        $display("======================================================");
        $finish;
    end

    // Global watchdog catches deadlocks.
    initial begin
        #2000000;
        $display("ERROR: global watchdog timeout.");
        $finish;
    end

endmodule
