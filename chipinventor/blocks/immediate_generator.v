// ============================================================================
// immediate_generator.v - extracts & sign-extends I/S/B/U/J immediates.
// Purely combinational.
// ============================================================================
module immediate_generator (
    input  wire [31:0] ir,
    output reg  [31:0] imm
);
    wire [6:0] opcode = ir[6:0];

    localparam [6:0]
        OPC_LOAD   = 7'b0000011,
        OPC_ALUIMM = 7'b0010011,
        OPC_JALR   = 7'b1100111,
        OPC_STORE  = 7'b0100011,
        OPC_BRANCH = 7'b1100011,
        OPC_LUI    = 7'b0110111,
        OPC_AUIPC  = 7'b0010111,
        OPC_JAL    = 7'b1101111;

    always @(*) begin
        case (opcode)
            OPC_LOAD, OPC_ALUIMM, OPC_JALR: // I-type
                imm = {{20{ir[31]}}, ir[31:20]};
            OPC_STORE: // S-type
                imm = {{20{ir[31]}}, ir[31:25], ir[11:7]};
            OPC_BRANCH: // B-type, imm[0] architecturally 0
                imm = {{19{ir[31]}}, ir[31], ir[7], ir[30:25], ir[11:8], 1'b0};
            OPC_LUI, OPC_AUIPC: // U-type
                imm = {ir[31:12], 12'b0};
            OPC_JAL: // J-type, imm[0] architecturally 0
                imm = {{11{ir[31]}}, ir[31], ir[19:12], ir[20], ir[30:21], 1'b0};
            default:
                imm = 32'b0; // R-type / SYSTEM / FENCE: don't-care, datapath won't select it
        endcase
    end
endmodule
