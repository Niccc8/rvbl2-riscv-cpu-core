// ============================================================================
// lsu.v - Load/Store Unit. Converts between the core's byte/half/word
// transaction view and the flat word-addressed, byte-writable memory
// interface (§9.11/§11). Purely combinational.
//
// op_size is funct3 directly (§11.1): op_size[1:0] = width (00/01/10 =
// byte/half/word), op_size[2] = unsigned-load flag.
//
// Misaligned half/word accesses are deliberately made a clean, deterministic
// no-op rather than left undefined (§11.2/§11.3, §24 item 7): misaligned
// stores assert byte_write_o=0000 (no write), misaligned loads return 0.
// ============================================================================
module lsu (
    input  wire [31:0] alu_result,     // effective address
    input  wire [31:0] rs2_data,       // register value to store
    input  wire [2:0]  op_size,        // = funct3
    input  wire        is_valid_store, // gates byte_write_o (§9.1 full-tuple decode)
    input  wire [31:0] mem_data_o,     // raw word read back from memory
    output reg  [31:0] core_data_i,    // extended load data -> WBSrc mux
    output reg  [3:0]  byte_write_o,   // bw_o
    output reg  [31:0] store_data_o    // positioned store data -> mem
);
    wire [1:0] addr_lsb        = alu_result[1:0];
    wire [1:0] size            = op_size[1:0];
    wire       load_unsigned   = op_size[2];

    // ---------------- Store path: byte-write mask + data positioning -----
    always @(*) begin
        byte_write_o = 4'b0000;
        store_data_o = 32'b0;
        if (is_valid_store) begin
            case (size)
                2'b00: begin // byte
                    case (addr_lsb)
                        2'b00: begin byte_write_o = 4'b0001; store_data_o = {24'b0, rs2_data[7:0]}; end
                        2'b01: begin byte_write_o = 4'b0010; store_data_o = {16'b0, rs2_data[7:0], 8'b0}; end
                        2'b10: begin byte_write_o = 4'b0100; store_data_o = {8'b0, rs2_data[7:0], 16'b0}; end
                        2'b11: begin byte_write_o = 4'b1000; store_data_o = {rs2_data[7:0], 24'b0}; end
                    endcase
                end
                2'b01: begin // half
                    case (addr_lsb)
                        2'b00: begin byte_write_o = 4'b0011; store_data_o = {16'b0, rs2_data[15:0]}; end
                        2'b10: begin byte_write_o = 4'b1100; store_data_o = {rs2_data[15:0], 16'b0}; end
                        default: begin byte_write_o = 4'b0000; store_data_o = 32'b0; end // misaligned
                    endcase
                end
                2'b10: begin // word
                    if (addr_lsb == 2'b00) begin byte_write_o = 4'b1111; store_data_o = rs2_data; end
                    else begin byte_write_o = 4'b0000; store_data_o = 32'b0; end // misaligned
                end
                default: begin byte_write_o = 4'b0000; store_data_o = 32'b0; end
            endcase
        end
    end

    // ---------------- Load path: extraction + sign/zero extension --------
    always @(*) begin
        case (size)
            2'b00: begin // byte
                case (addr_lsb)
                    2'b00: core_data_i = load_unsigned ? {24'b0, mem_data_o[7:0]}   : {{24{mem_data_o[7]}},  mem_data_o[7:0]};
                    2'b01: core_data_i = load_unsigned ? {24'b0, mem_data_o[15:8]}  : {{24{mem_data_o[15]}}, mem_data_o[15:8]};
                    2'b10: core_data_i = load_unsigned ? {24'b0, mem_data_o[23:16]} : {{24{mem_data_o[23]}}, mem_data_o[23:16]};
                    2'b11: core_data_i = load_unsigned ? {24'b0, mem_data_o[31:24]} : {{24{mem_data_o[31]}}, mem_data_o[31:24]};
                endcase
            end
            2'b01: begin // half
                case (addr_lsb)
                    2'b00: core_data_i = load_unsigned ? {16'b0, mem_data_o[15:0]}  : {{16{mem_data_o[15]}}, mem_data_o[15:0]};
                    2'b10: core_data_i = load_unsigned ? {16'b0, mem_data_o[31:16]} : {{16{mem_data_o[31]}}, mem_data_o[31:16]};
                    default: core_data_i = 32'b0; // misaligned
                endcase
            end
            2'b10: core_data_i = (addr_lsb == 2'b00) ? mem_data_o : 32'b0; // word / misaligned
            default: core_data_i = 32'b0;
        endcase
    end
endmodule
