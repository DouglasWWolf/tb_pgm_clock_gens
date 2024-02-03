module fpu
(
    input                   clk, resetn,
    
    output                  idle,

    input      [ 2:0]       OP,
    input      [63:0]       A, B,
    output reg [63:0]       RESULT,

    output     [63:0]       tofloat_A_tdata,
    output                  tofloat_A_tvalid,
    input                   tofloat_A_tready,

    output     [63:0]       toint_A_tdata,
    output                  toint_A_tvalid,
    input                   toint_A_tready,

    output     [63:0]       multiply_A_tdata,
    output                  multiply_A_tvalid,
    input                   multiply_A_tready,
     
    output     [63:0]       multiply_B_tdata,
    output                  multiply_B_tvalid,
    input                   multiply_B_tready,

    output     [63:0]       divide_A_tdata,
    output                  divide_A_tvalid,
    input                   divide_A_tready,
    
    output     [63:0]       divide_B_tdata,
    output                  divide_B_tvalid,
    input                   divide_B_tready,

    input      [63:0]       tofloat_RESULT_tdata,
    input                   tofloat_RESULT_tvalid,
    output                  tofloat_RESULT_tready,

    input      [63:0]       toint_RESULT_tdata,
    input                   toint_RESULT_tvalid,
    output                  toint_RESULT_tready,

    input      [63:0]       multiply_RESULT_tdata,
    input                   multiply_RESULT_tvalid,
    output                  multiply_RESULT_tready,

    input      [63:0]       divide_RESULT_tdata,
    input                   divide_RESULT_tvalid,
    output                  divide_RESULT_tready

);

reg[1:0] fsm_state;

// We're idle when the state-machine is idle, and we haven't received a command
assign idle = (fsm_state == 0 && OP == 0);


localparam OP_TO_FLOAT   = 1;
localparam OP_TO_INT     = 2;
localparam OP_MULTIPLY   = 3;
localparam OP_DIVIDE     = 4;

reg  [63:0] A_tdata,  B_tdata;
reg         A_tvalid, B_tvalid;
wire        A_tready, B_tready;

wire [63:0] RESULT_tdata;
wire        RESULT_tvalid;
reg         RESULT_tready;

assign    tofloat_A_tdata = (opcode == OP_TO_FLOAT) ? A_tdata  : 0;
assign      toint_A_tdata = (opcode == OP_TO_INT  ) ? A_tdata  : 0;
assign   multiply_A_tdata = (opcode == OP_MULTIPLY) ? A_tdata  : 0;
assign     divide_A_tdata = (opcode == OP_DIVIDE  ) ? A_tdata  : 0;

assign    tofloat_A_tvalid = (opcode == OP_TO_FLOAT) ? A_tvalid : 0;
assign      toint_A_tvalid = (opcode == OP_TO_INT  ) ? A_tvalid : 0;
assign   multiply_A_tvalid = (opcode == OP_MULTIPLY) ? A_tvalid : 0;
assign     divide_A_tvalid = (opcode == OP_DIVIDE  ) ? A_tvalid : 0;

assign    multiply_B_tdata = (opcode == OP_MULTIPLY) ? B_tdata  : 0;
assign      divide_B_tdata = (opcode == OP_DIVIDE  ) ? B_tdata  : 0;

assign   multiply_B_tvalid = (opcode == OP_MULTIPLY) ? B_tvalid : 0;
assign     divide_B_tvalid = (opcode == OP_DIVIDE  ) ? B_tvalid : 0;

assign A_tready      = (opcode == OP_TO_FLOAT) ?    tofloat_A_tready :
                       (opcode == OP_TO_INT  ) ?      toint_A_tready :
                       (opcode == OP_MULTIPLY) ?   multiply_A_tready : 
                       (opcode == OP_DIVIDE  ) ?     divide_A_tready : 0;

assign B_tready      = (opcode == OP_TO_FLOAT) ? 0                   :
                       (opcode == OP_TO_INT  ) ? 0                   :
                       (opcode == OP_MULTIPLY) ? multiply_B_tready   :
                       (opcode == OP_DIVIDE  ) ?   divide_B_tready   : 0;

assign RESULT_tdata  = (opcode == OP_TO_FLOAT) ?    tofloat_RESULT_tdata :
                       (opcode == OP_TO_INT  ) ?      toint_RESULT_tdata :
                       (opcode == OP_MULTIPLY) ?   multiply_RESULT_tdata : 
                       (opcode == OP_DIVIDE  ) ?     divide_RESULT_tdata : 0;

assign RESULT_tvalid = (opcode == OP_TO_FLOAT) ?    tofloat_RESULT_tvalid :
                       (opcode == OP_TO_INT  ) ?      toint_RESULT_tvalid :
                       (opcode == OP_MULTIPLY) ?   multiply_RESULT_tvalid :
                       (opcode == OP_DIVIDE  ) ?     divide_RESULT_tvalid : 0;

assign    tofloat_RESULT_tready = (opcode == OP_TO_FLOAT) ? RESULT_tready : 0;
assign      toint_RESULT_tready = (opcode == OP_TO_INT  ) ? RESULT_tready : 0;
assign   multiply_RESULT_tready = (opcode == OP_MULTIPLY) ? RESULT_tready : 0;
assign     divide_RESULT_tready = (opcode == OP_DIVIDE  ) ? RESULT_tready : 0;


wire[3:0] unary;
assign unary[OP_TO_FLOAT] = 1;
assign unary[OP_TO_INT  ] = 1;

reg [2:0] opcode;

always @(posedge clk) begin

    if (resetn == 0) begin
        A_tvalid      <= 0;
        B_tvalid      <= 0;
        RESULT_tready <= 0;
        fsm_state     <= 0;
    end else case(fsm_state)

    0:  if (OP) begin
            opcode    <= OP;
            fsm_state <= fsm_state + 1;
        end

    1:  begin
            A_tdata   <= A;
            A_tvalid  <= 1;
            if (A_tvalid & A_tready) begin
                A_tvalid  <= 0;    
                fsm_state <= fsm_state + 1;
            end
        end

    2:  if (unary[opcode] == 0) begin
            B_tdata   <= B;
            B_tvalid  <= 1;
            if (B_tvalid & B_tready) begin
                B_tvalid  <= 0;
                fsm_state <= fsm_state + 1;
            end
        end else begin
            fsm_state     <= fsm_state + 1;
        end


    3:  begin
            RESULT_tready <= 1;
            if (RESULT_tvalid & RESULT_tready) begin
                RESULT_tready <= 0;
                RESULT        <= RESULT_tdata;
                fsm_state     <= 0;
            end
        end

    endcase

end


endmodule
