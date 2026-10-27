`timescale 1ns/1ps

//Replace logic check

module hash_mapping #(
    parameter bucket_size = 8192,
    parameter integer ADDR_WIDTH = $clog2(8192),
    parameter KEY_BYTES = 13,
    parameter KEY_BITS = 104,
    parameter TIMESTAMP = 64
)(
    input clk,
    input rst,

    input valid,
    input [(KEY_BITS+TIMESTAMP-1):0] key,
    input [31:0] hash1,
    input [31:0] hash2,
    input [31:0] hash3,

    output reg done,
    output reg ready
 
);


    reg                  rd_en;
    reg [ADDR_WIDTH-1:0] rd_addr;

    wire                  rd_valid;
    wire                  rd_occupied;
    wire [KEY_BITS-1:0]  rd_key;
    wire [TIMESTAMP-1:0] rd_timestamp;

    reg                  wr_en;
    reg [ADDR_WIDTH-1:0] wr_addr;
    reg                  wr_occupied;
    reg [KEY_BITS-1:0]  wr_key;
    reg [TIMESTAMP-1:0] wr_timestamp;
    reg [ADDR_WIDTH-1:0] selected_addr;

    reg [TIMESTAMP-1:0] timestamp_1;
    reg [TIMESTAMP-1:0] timestamp_2;
    reg [TIMESTAMP-1:0] timestamp_3;

    reg [KEY_BITS+TIMESTAMP-1:0] key_reg;
    reg [31:0] hash1_reg, hash2_reg, hash3_reg;

    flow_table_bram #(
            .TABLE_SIZE      (8192),
            .ADDR_WIDTH      (13),
            .KEY_WIDTH       (104),
            .TIME_WIDTH      (64),
            .ENTRY_WIDTH     (1+KEY_BITS+TIMESTAMP)
        ) u_flow_table_bram (
            .clk             (clk),
            // -------------------------------
            // BRAM read interface
            // -------------------------------
            .rd_en           (rd_en),
            .rd_addr         (rd_addr),
            .rd_valid        (rd_valid),
            .rd_occupied     (rd_occupied),
            .rd_key          (rd_key),
            .rd_timestamp    (rd_timestamp),
            // -------------------------------
            // BRAM write interface
            // -------------------------------
            .wr_en           (wr_en),
            .wr_addr         (wr_addr),
            .wr_occupied     (wr_occupied),
            .wr_key          (wr_key),
            .wr_timestamp    (wr_timestamp)
        );
    

    typedef enum logic [3:0] {
    IDLE,
    READ_1,
    CHECK_1,
    READ_2,
    CHECK_2,
    READ_3,
    CHECK_3,
    REPLACE_ENTRY,
    WRITE_ENTRY,
    COMPLETE
    } state_t;

    state_t state;

    always @(posedge clk) begin
        if (!rst) begin
            state <= IDLE;
            rd_en   <= 1'b0;
            rd_addr <= 13'b0;
            wr_en <= 1'b0;
            wr_addr <= 13'b0;
            wr_occupied <= 1'b0;
            wr_key <=  104'b0;
            wr_timestamp <= 64'b0;
            done <= 1'b0;
            ready <=1'b0;

            key_reg   <= 168'b0;
            hash1_reg <= 32'b0;
            hash2_reg <= 32'b0;
            hash3_reg <= 32'b0;

            selected_addr <= {ADDR_WIDTH{1'b0}};
            timestamp_1   <= {TIMESTAMP{1'b0}};
            timestamp_2   <= {TIMESTAMP{1'b0}};
            timestamp_3   <= {TIMESTAMP{1'b0}};
            
        end
        else begin
            case (state) 
                IDLE: begin
                    wr_en <= 1'b0;
                    done <= 1'b0;
                    ready <= 1'b1;
                    if (valid) begin
                         state <= READ_1;
                         key_reg   <= key;
                         hash1_reg <= hash1;
                         hash2_reg <= hash2;
                         hash3_reg <= hash3;
                    end
                end

                READ_1: begin
                    ready <= 1'b0;
                    rd_en <= 1'b1;
                    rd_addr <= hash1_reg[12:0];
                    state <= CHECK_1;
                end

                CHECK_1: begin
                    if (rd_valid) begin
                        rd_en <= 1'b0;
                        if (!rd_occupied) begin
                             selected_addr <= hash1_reg[12:0];
                             state <= WRITE_ENTRY;
                        end
                        else if (rd_key == key_reg[103:0]) begin
                            selected_addr <= hash1_reg[12:0];
                            state <= WRITE_ENTRY;
                        end
                        else begin                       //Collision
                            state <= READ_2;
                            timestamp_1 <= rd_timestamp;
                        end
                    end
                end

                READ_2: begin
                    rd_en <= 1'b1;
                    rd_addr <= hash2_reg[12:0];
                    state <= CHECK_2;
                end

                CHECK_2: begin
                    if (rd_valid) begin
                        rd_en <= 1'b0;
                        if (!rd_occupied) begin
                             selected_addr <= hash2_reg[12:0];
                             state <= WRITE_ENTRY;
                        end
                        else if (rd_key == key_reg[103:0]) begin
                            selected_addr <= hash2_reg[12:0];
                            state <= WRITE_ENTRY;
                        end
                        else begin                     //Collision
                            state <= READ_3;
                            timestamp_2 <= rd_timestamp;
                        end
                    end
                end

                READ_3: begin
                    rd_en <= 1'b1;
                    rd_addr <= hash3_reg[12:0];
                    state <= CHECK_3;
                end

                CHECK_3: begin
                    if (rd_valid) begin
                        rd_en <= 1'b0;
                        if (!rd_occupied) begin
                             selected_addr <= hash3_reg[12:0];
                             state <= WRITE_ENTRY;
                        end
                        else if (rd_key == key_reg[103:0]) begin
                            selected_addr <= hash3_reg[12:0];
                            state <= WRITE_ENTRY;
                        end
                        else begin                  //Collision
                            state <= REPLACE_ENTRY;
                            timestamp_3 <= rd_timestamp;
                        end
                    end
                end

                WRITE_ENTRY : begin
                    wr_en <= 1'b1;
                    wr_addr <= selected_addr;
                    wr_occupied <= 1'b1;
                    wr_key <=  key_reg[KEY_BITS-1:0];
                    wr_timestamp <= key_reg[KEY_BITS+TIMESTAMP-1:KEY_BITS];
                    state <= COMPLETE;
                    
                end

                REPLACE_ENTRY : begin
                    wr_en <= 1'b1;
                    wr_addr <= (timestamp_1<timestamp_2)&&(timestamp_1<timestamp_3)? hash1_reg[12:0]:
                               (timestamp_2<timestamp_1)&&(timestamp_2<timestamp_3)? hash2_reg[12:0]:hash3_reg[12:0];
                    wr_occupied <= 1'b1;
                    wr_key <=  key_reg[KEY_BITS-1:0];
                    wr_timestamp <= key_reg[KEY_BITS+TIMESTAMP-1:KEY_BITS];
                    state <= COMPLETE; 
                end 

                COMPLETE: begin
                    wr_en <= 1'b0;
                    done  <= 1'b1;
                    state <= IDLE;
                end

                default: begin
                        state <= IDLE;
                end
            endcase
        end
    end

endmodule