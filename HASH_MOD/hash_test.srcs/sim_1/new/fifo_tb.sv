`timescale 1ns/1ps
//============================================================================
// Self-checking testbench for module `fifo`
//
//  * The DUT reset is ACTIVE-LOW (`if (!rst)` resets), so the TB drives rst_n.
//  * `empty`, `full`, `valid_out`, `ready`, `key_out`, hashN_out are internal
//    to the DUT and are observed via hierarchical references (dut.xxx).
//  * hash_mapping is replaced by a small stub whose `ready` is controlled by
//    the testbench (tb_fifo.ready_en) so back-pressure can be created at will.
//    Compile with +define+USE_REAL_HASH_MAPPING to use your real module
//    instead (tests that rely on stalling ready will then not be meaningful).
//  * A reference model (scoreboard) is kept in the TB:
//        write accepted  : valid_in && occupancy < DEPTH   (sampled at posedge)
//        read  consumed  : dut.valid_out && dut.ready       (sampled at posedge)
//    Every consumed word is compared against the oldest expected word.
//
//  Run (Icarus):  iverilog -g2012 -o sim tb_fifo.sv fifo.v [hash_mapping.v] && vvp sim
//============================================================================

`ifndef USE_REAL_HASH_MAPPING
module hash_mapping #(
    parameter bucket_size = 8192,
    parameter ADDR_WIDTH  = 13,
    parameter KEY_BYTES   = 13,
    parameter KEY_BITS    = 104,
    parameter TIMESTAMP   = 64
)(
    input  wire clk,
    input  wire rst,
    input  wire valid,
    input  wire [KEY_BITS+TIMESTAMP-1:0] key,
    input  wire [31:0] hash1,
    input  wire [31:0] hash2,
    input  wire [31:0] hash3,
    output reg         done,
    output wire        ready
);
    assign ready = tb_fifo.ready_en;      // testbench-controlled back-pressure

    always @(posedge clk) begin
        if (!rst) done <= 1'b0;
        else      done <= valid && ready;
    end
endmodule
`endif

module tb_fifo;

    //------------------------------------------------------------------
    // Parameters (same as the DUT)
    //------------------------------------------------------------------
    parameter DEPTH     = 256;
    parameter KEY_BYTES = 13;
    parameter KEY_BITS  = 104;
    parameter TIMESTAMP = 64;

    localparam PTR_WIDTH      = $clog2(DEPTH);
    localparam DW             = KEY_BITS + TIMESTAMP;
    localparam CLK_PERIOD     = 10;
    localparam DRAIN_TIMEOUT  = 8*DEPTH + 1000;       // cycles
    localparam STRESS_CYCLES  = 20000;
    localparam WATCHDOG_CYC   = 2_000_000;            // global timeout, cycles

    //------------------------------------------------------------------
    // DUT signals
    //------------------------------------------------------------------
    reg                clk      = 1'b0;
    reg                rst_n    = 1'b0;
    reg                valid_in = 1'b0;
    reg  [31:0]        hash1    = 32'd0;
    reg  [31:0]        hash2    = 32'd0;
    reg  [31:0]        hash3    = 32'd0;
    reg  [DW-1:0]      flow_in  = '0;
    wire [PTR_WIDTH:0] wr_ptr;
    wire [PTR_WIDTH:0] rd_ptr;

    reg                ready_en = 1'b0;   // drives stub's ready

    fifo #(
        .DEPTH    (DEPTH),
        .KEY_BYTES(KEY_BYTES),
        .KEY_BITS (KEY_BITS),
        .TIMESTAMP(TIMESTAMP)
    ) dut (
        .clk     (clk),
        .rst     (rst_n),
        .valid_in(valid_in),
        .hash1   (hash1),
        .hash2   (hash2),
        .hash3   (hash3),
        .flow_in (flow_in),
        .wr_ptr  (wr_ptr),
        .rd_ptr  (rd_ptr)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

`ifdef DUMP
    initial begin
        $dumpfile("tb_fifo.vcd");
        $dumpvars(0, tb_fifo);
    end
`endif

    //------------------------------------------------------------------
    // Global watchdog
    //------------------------------------------------------------------
    initial begin
        #(WATCHDOG_CYC * CLK_PERIOD);
        $display("[%0t] *** FAIL: GLOBAL WATCHDOG TIMEOUT ***", $time);
        $finish;
    end

    //------------------------------------------------------------------
    // Scoreboard / reference model
    //------------------------------------------------------------------
    reg [DW-1:0] exp_key [0:DEPTH-1];
    reg [31:0]   exp_h1  [0:DEPTH-1];
    reg [31:0]   exp_h2  [0:DEPTH-1];
    reg [31:0]   exp_h3  [0:DEPTH-1];

    integer wr_idx    = 0;     // accepted writes since last reset
    integer rd_idx    = 0;     // consumed reads  since last reset
    integer total_wr  = 0;     // accepted writes (all time)
    integer total_rd  = 0;     // consumed reads  (all time)
    integer dropped   = 0;     // writes attempted while full
    integer flushed   = 0;     // words discarded by a mid-test reset
    integer errors    = 0;
    integer checks    = 0;
    integer seq       = 0;     // running sequence number put in hash1
    integer last_h1   = -1;    // ordering check

    function integer get_occ(input dummy);
        get_occ = wr_idx - rd_idx;
    endfunction

    task chk(input cond, input string msg);
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("[%0t] ERROR: %s", $time, msg);
            end
        end
    endtask

    // ---------------- monitor: samples pre-edge values at posedge ----------
    integer      occ_pre;
    integer      m_idx;
    integer      h1_i;
    reg          m_acc, m_con;
    reg          hold_q = 1'b0;
    reg [DW-1:0] key_q;
    reg [31:0]   h1_q, h2_q, h3_q;

    always @(posedge clk) begin
        if (!rst_n) begin
            wr_idx  = 0;
            rd_idx  = 0;
            hold_q  = 1'b0;
            last_h1 = -1;
        end
        else begin
            occ_pre = wr_idx - rd_idx;

            // Output register must hold its value while stalled
            if (hold_q) begin
                chk(dut.valid_out === 1'b1, "valid_out dropped while ready=0");
                chk((dut.key_out === key_q) && (dut.hash1_out === h1_q) &&
                    (dut.hash2_out === h2_q) && (dut.hash3_out === h3_q),
                    "output data changed while stalled");
            end

            m_con = (dut.valid_out === 1'b1) && (dut.ready === 1'b1);
            m_acc = (valid_in === 1'b1) && (occ_pre < DEPTH);

            if (valid_in && (occ_pre >= DEPTH)) dropped = dropped + 1;

            // ---- consume ----
            if (m_con) begin
                if (occ_pre == 0) begin
                    chk(1'b0, "word consumed while reference FIFO is empty");
                end
                else begin
                    m_idx = rd_idx % DEPTH;
                    if (dut.key_out   !== exp_key[m_idx] ||
                        dut.hash1_out !== exp_h1 [m_idx] ||
                        dut.hash2_out !== exp_h2 [m_idx] ||
                        dut.hash3_out !== exp_h3 [m_idx]) begin
                        chk(1'b0, "DATA MISMATCH on read");
                        $display("         rd#%0d exp h1=%h h2=%h h3=%h key=%h", rd_idx,
                                 exp_h1[m_idx], exp_h2[m_idx], exp_h3[m_idx], exp_key[m_idx]);
                        $display("                  got h1=%h h2=%h h3=%h key=%h",
                                 dut.hash1_out, dut.hash2_out, dut.hash3_out, dut.key_out);
                    end
                    else chk(1'b1, "");

                    // ordering: hash1 carries a strictly increasing sequence number
                    h1_i = dut.hash1_out;
                    chk(h1_i > last_h1, "FIFO ORDER violated");
                    last_h1 = h1_i;
                end
                rd_idx   = rd_idx + 1;
                total_rd = total_rd + 1;
            end

            // ---- accept ----
            if (m_acc) begin
                m_idx = wr_idx % DEPTH;
                exp_key[m_idx] = flow_in;
                exp_h1 [m_idx] = hash1;
                exp_h2 [m_idx] = hash2;
                exp_h3 [m_idx] = hash3;
                wr_idx   = wr_idx + 1;
                total_wr = total_wr + 1;
            end

            // remember stall state for next cycle
            hold_q = (dut.valid_out === 1'b1) && (dut.ready !== 1'b1);
            key_q  = dut.key_out;
            h1_q   = dut.hash1_out;
            h2_q   = dut.hash2_out;
            h3_q   = dut.hash3_out;
        end
    end

    // ---------------- per-cycle flag / pointer checker (negedge) -----------
    integer occ_c;
    always @(negedge clk) begin
        if (rst_n) begin
            occ_c = wr_idx - rd_idx;
            chk(^{dut.full, dut.empty, wr_ptr, rd_ptr, dut.valid_out} !== 1'bx,
                "X/Z on flags, pointers or valid_out");
            chk(dut.full  === (occ_c == DEPTH), "full flag does not match occupancy");
            chk(dut.empty === (occ_c == 0),     "empty flag does not match occupancy");
            chk(!(dut.full && dut.empty),       "full and empty both asserted");
            chk(wr_ptr === (wr_idx % (2*DEPTH)), "wr_ptr does not match accepted-write count");
            chk(rd_ptr === (rd_idx % (2*DEPTH)), "rd_ptr does not match consumed-read count");
            chk(!(dut.valid_out && occ_c == 0), "valid_out high with empty FIFO");
        end
    end

    //------------------------------------------------------------------
    // Stimulus helpers
    //------------------------------------------------------------------
    function [DW-1:0] rand_dw(input dummy);
        integer i;
        reg [DW+31:0] r;
        begin
            r = '0;
            for (i = 0; i < DW; i = i + 32) r = (r << 32) | $urandom;
            rand_dw = r[DW-1:0];
        end
    endfunction

    // new unique word with valid_in=1 (hash1 = sequence number)
    task drive_new;
        begin
            flow_in  = rand_dw(0);
            hash1    = seq;
            hash2    = $urandom;
            hash3    = $urandom;
            valid_in = 1'b1;
            seq      = seq + 1;
        end
    endtask

    // valid_in=0 with garbage on data lines (must never be captured)
    task idle_inputs;
        begin
            valid_in = 1'b0;
            flow_in  = rand_dw(0);
            hash1    = $urandom;
            hash2    = $urandom;
            hash3    = $urandom;
        end
    endtask

    // n back-to-back write attempts (one per clock), then idle
    task write_burst(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(negedge clk);
                drive_new;
            end
            @(negedge clk);
            idle_inputs;
        end
    endtask

    task wait_cycles(input integer n);
        begin
            repeat (n) @(negedge clk);
        end
    endtask

    // enable reads and wait until reference model is empty
    task wait_drain;
        integer t;
        begin
            ready_en = 1'b1;
            t = 0;
            while ((wr_idx != rd_idx) && (t < DRAIN_TIMEOUT)) begin
                @(negedge clk);
                t = t + 1;
            end
            chk(t < DRAIN_TIMEOUT, "TIMEOUT while draining FIFO");
            @(negedge clk);
        end
    endtask

    task do_reset(input integer n);
        begin
            flushed = flushed + (wr_idx - rd_idx);
            @(negedge clk);
            rst_n = 1'b0;
            drive_new;                        // writes during reset must be ignored
            seq = seq;                        // (sequence keeps advancing)
            repeat (n) @(negedge clk);
            chk(wr_ptr === 0 && rd_ptr === 0, "pointers not zero during reset");
            chk(dut.empty === 1'b1,           "empty not asserted during reset");
            chk(dut.full  === 1'b0,           "full asserted during reset");
            chk(dut.valid_out === 1'b0,       "valid_out not cleared by reset");
            rst_n = 1'b1;
            idle_inputs;
            @(negedge clk);
        end
    endtask

    task phase(input string name);
        begin
            $display("[%0t] ---- %s", $time, name);
        end
    endtask

    //------------------------------------------------------------------
    // Main test sequence
    //------------------------------------------------------------------
    integer i, k, cyc;
    integer rd_before, wr_before, drop_before;
    reg [PTR_WIDTH:0] wr_ptr_snap, rd_ptr_snap;
    integer wr_prob, rd_prob;
    integer fill_sizes [0:7];

    initial begin
        ready_en = 1'b0;
        fill_sizes[0] = DEPTH;
        fill_sizes[1] = DEPTH/2;
        fill_sizes[2] = DEPTH - 1;
        fill_sizes[3] = DEPTH + 3;
        fill_sizes[4] = 1;
        fill_sizes[5] = DEPTH;
        fill_sizes[6] = DEPTH/4 + 1;
        fill_sizes[7] = DEPTH + DEPTH/2;

        //==================================================================
        phase("TEST 1: reset and initial empty state");
        //==================================================================
        do_reset(4);
        wait_cycles(3);
        chk(wr_ptr === 0 && rd_ptr === 0, "pointers should be 0 after reset");
        chk(dut.empty === 1'b1,           "FIFO should be empty after reset");
        chk(dut.full  === 1'b0,           "FIFO should not be full after reset");
        chk(dut.valid_out === 1'b0,       "valid_out should be 0 after reset");
        chk(total_wr == 0,                "no write should be accepted during reset");

        // Mid-operation reset: fill a few words, reset, expect clean state
        ready_en = 1'b0;
        write_burst(20);
        wait_cycles(3);
        chk(get_occ(0) == 20 && !dut.empty, "20 words should be stored before mid-test reset");
        do_reset(3);
        wait_cycles(2);
        chk(wr_ptr === 0 && rd_ptr === 0 && dut.empty === 1'b1 && dut.valid_out === 1'b0,
            "FIFO not cleanly empty after mid-operation reset");

        //==================================================================
        phase("TEST 2/3: single write, single read, empty/full flags");
        //==================================================================
        ready_en = 1'b0;
        write_burst(1);
        wait_cycles(3);
        chk(get_occ(0) == 1,   "occupancy should be 1");
        chk(dut.empty === 1'b0, "empty should deassert after 1 write");
        chk(dut.full  === 1'b0, "full should be 0 after 1 write");
        chk(wr_ptr === 1,       "wr_ptr should be 1");
        chk(dut.valid_out === 1'b1, "output stage should present the word");
        wait_cycles(5);                       // stalled: data must stay (monitor checks)
        chk(get_occ(0) == 1 && rd_ptr === 0, "word must remain while ready=0");
        wait_drain;
        wait_cycles(2);
        chk(dut.empty === 1'b1, "empty should reassert after read");
        chk(rd_ptr === 1 && wr_ptr === 1, "pointers should both be 1");
        chk(dut.valid_out === 1'b0, "valid_out should clear after read");

        //==================================================================
        phase("TEST 4/5: multiple writes then reads, FIFO ordering");
        //==================================================================
        ready_en = 1'b0;
        write_burst(10);
        wait_cycles(3);
        chk(get_occ(0) == 10, "occupancy should be 10");
        chk(dut.empty === 1'b0 && dut.full === 1'b0, "flags wrong at 10 entries");
        rd_before = total_rd;
        wait_drain;
        chk(total_rd - rd_before == 10, "exactly 10 words should have been read");
        chk(dut.empty === 1'b1, "FIFO should be empty after reading 10 words");

        // write with gaps between words
        ready_en = 1'b0;
        for (i = 0; i < 8; i = i + 1) begin
            @(negedge clk); drive_new;
            @(negedge clk); idle_inputs;
            wait_cycles(i % 3);
        end
        wait_cycles(2);
        chk(get_occ(0) == 8, "occupancy should be 8 after gapped writes");
        wait_drain;

        //==================================================================
        phase("TEST 6: fill to capacity (full flag)");
        //==================================================================
        ready_en = 1'b0;
        write_burst(DEPTH - 1);
        wait_cycles(2);
        chk(get_occ(0) == DEPTH-1, "occupancy should be DEPTH-1");
        chk(dut.full === 1'b0,     "full must not be set at DEPTH-1");
        write_burst(1);
        wait_cycles(2);
        chk(get_occ(0) == DEPTH,   "occupancy should be DEPTH");
        chk(dut.full  === 1'b1,    "full must be set at DEPTH");
        chk(dut.empty === 1'b0,    "empty must be clear when full");
        chk((wr_ptr[PTR_WIDTH-1:0] == rd_ptr[PTR_WIDTH-1:0]) &&
            (wr_ptr[PTR_WIDTH]     != rd_ptr[PTR_WIDTH]),
            "pointer relationship wrong when full");

        //==================================================================
        phase("TEST 7: write attempts while full");
        //==================================================================
        wr_ptr_snap = wr_ptr;
        rd_ptr_snap = rd_ptr;
        drop_before = dropped;
        wr_before   = total_wr;
        write_burst(7);
        wait_cycles(2);
        chk(wr_ptr === wr_ptr_snap, "wr_ptr must not move when full");
        chk(rd_ptr === rd_ptr_snap, "rd_ptr must not move while stalled");
        chk(dropped - drop_before == 7, "TB should have seen 7 dropped writes");
        chk(total_wr == wr_before,  "no write may be accepted while full");
        chk(dut.full === 1'b1,      "full must stay set");

        //==================================================================
        phase("TEST 8: read until empty (data of full FIFO intact)");
        //==================================================================
        rd_before = total_rd;
        wait_drain;
        wait_cycles(2);
        chk(total_rd - rd_before == DEPTH, "all DEPTH words must be read back");
        chk(dut.empty === 1'b1 && dut.full === 1'b0, "flags wrong after drain");
        chk(wr_ptr === rd_ptr, "pointers must be equal after drain");
        chk(dut.valid_out === 1'b0, "valid_out must be low when empty");

        //==================================================================
        phase("TEST 9: read attempts while empty");
        //==================================================================
        wr_ptr_snap = wr_ptr;
        rd_ptr_snap = rd_ptr;
        rd_before   = total_rd;
        ready_en    = 1'b1;                   // downstream always ready
        wait_cycles(20);
        chk(rd_ptr === rd_ptr_snap, "rd_ptr must not move when empty");
        chk(wr_ptr === wr_ptr_snap, "wr_ptr must not move without writes");
        chk(total_rd == rd_before,  "no word may be read from empty FIFO");
        chk(dut.valid_out === 1'b0, "valid_out must stay low when empty");
        chk(dut.empty === 1'b1,     "empty must stay set");
        // toggle ready too
        for (i = 0; i < 10; i = i + 1) begin ready_en = ~ready_en; wait_cycles(1); end
        chk(rd_ptr === rd_ptr_snap && dut.empty === 1'b1, "toggling ready on empty FIFO broke state");

        //==================================================================
        phase("TEST 10: simultaneous read and write");
        //==================================================================
        // (a) from empty, continuous writes with reads enabled
        ready_en = 1'b1;
        write_burst(100);
        wait_drain;
        // (b) half-full FIFO, continuous writes and reads
        ready_en = 1'b0;
        write_burst(DEPTH/2);
        wait_cycles(2);
        ready_en = 1'b1;
        write_burst(DEPTH);
        wait_drain;
        // (c) at full: reads enabled while writes keep arriving
        ready_en = 1'b0;
        write_burst(DEPTH);
        wait_cycles(2);
        chk(dut.full === 1'b1, "FIFO should be full before simultaneous test (c)");
        ready_en = 1'b1;
        write_burst(60);
        wait_drain;
        chk(dut.empty === 1'b1, "FIFO should be empty after simultaneous tests");

        //==================================================================
        phase("TEST 11: repeated fill / drain cycles (pointer wrap-around)");
        //==================================================================
        for (k = 0; k < 16; k = k + 1) begin
            ready_en = 1'b0;
            write_burst(fill_sizes[k % 8]);
            wait_cycles(3);
            if (fill_sizes[k % 8] >= DEPTH)
                chk(dut.full === 1'b1, "full expected after over-filling");
            else
                chk(dut.full === 1'b0 && dut.empty === 1'b0, "flags wrong after partial fill");
            // alternate between full-speed and random drain
            if (k % 2) begin
                ready_en = 1'b1;
                wait_drain;
            end
            else begin
                cyc = 0;
                while ((wr_idx != rd_idx) && cyc < DRAIN_TIMEOUT) begin
                    ready_en = (($urandom % 100) < 40);
                    @(negedge clk);
                    cyc = cyc + 1;
                end
                chk(cyc < DRAIN_TIMEOUT, "TIMEOUT in random-ready drain");
                wait_drain;
            end
            chk(dut.empty === 1'b1 && wr_ptr === rd_ptr, "FIFO not empty after drain cycle");
        end
        chk(total_wr > 2*DEPTH, "pointers should have wrapped around at least once");

        //==================================================================
        phase("TEST 12: random stress, data integrity");
        //==================================================================
        for (i = 0; i < STRESS_CYCLES; i = i + 1) begin
            @(negedge clk);
            case ((i / 2000) % 6)
                0: begin wr_prob = 90;  rd_prob = 30;  end
                1: begin wr_prob = 30;  rd_prob = 90;  end
                2: begin wr_prob = 50;  rd_prob = 50;  end
                3: begin wr_prob = 100; rd_prob = 100; end
                4: begin wr_prob = 100; rd_prob = 10;  end
                default: begin wr_prob = 10; rd_prob = 100; end
            endcase
            ready_en = (($urandom % 100) < rd_prob);
            if (($urandom % 100) < wr_prob) drive_new;
            else                            idle_inputs;
        end
        @(negedge clk);
        idle_inputs;
        wait_drain;
        wait_cycles(5);

        //==================================================================
        phase("FINAL: data integrity summary");
        //==================================================================
        chk(dut.empty === 1'b1 && dut.full === 1'b0, "FIFO should be empty at end of test");
        chk(total_wr == total_rd + flushed,
            "accepted writes != reads + words flushed by reset");
        chk(wr_idx == rd_idx, "scoreboard not empty at end of test");

        $display("");
        $display("============================================================");
        $display(" accepted writes : %0d", total_wr);
        $display(" words read      : %0d", total_rd);
        $display(" flushed by rst  : %0d", flushed);
        $display(" dropped (full)  : %0d", dropped);
        $display(" checks executed : %0d", checks);
        $display(" errors          : %0d", errors);
        if (errors == 0) $display(" *** TEST PASSED ***");
        else             $display(" *** TEST FAILED ***");
        $display("============================================================");
        $finish;
    end

endmodule