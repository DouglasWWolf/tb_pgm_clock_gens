//=============================================================================
// uint_div: long division in Verilog
//=============================================================================
module uint_div #(parameter WIDTH=32)
( 
    input                  clk, resetn,
    input                  start,     
    output                 idle,       
    output reg             dbz,  
    input      [WIDTH-1:0] A,    
    input      [WIDTH-1:0] B,    
    output reg [WIDTH-1:0] RESULT,  
    output reg [WIDTH-1:0] remainder
);

// The state of the state machine
reg fsm_state;

// We're idle when we're in state 0 and haven't been started yet
assign idle = (fsm_state == 0 && start == 0);

reg [WIDTH-1:0]         b1;             
reg [WIDTH-1:0]         quo, quo_next;  
reg [WIDTH:0]           acc, acc_next;    
reg [$clog2(WIDTH)-1:0] i;      

// A single pass through the loop
always @* begin
    if (acc >= {1'b0, b1}) begin
        acc_next = acc - b1;
        {acc_next, quo_next} = {acc_next[WIDTH-1:0], quo, 1'b1};
    end else begin
        {acc_next, quo_next} = {acc, quo} << 1;
    end
end


// One pass through the loop for each bit in the input
always @(posedge clk) begin

    if (resetn == 0) begin
        fsm_state <= 0;
    end else case(fsm_state)

    0:  if (start) begin
            if (B == 0)
                dbz <= 1;
            else begin
                i          <= 0;
                dbz        <= 0;
                b1         <= B;
                {acc, quo} <= {{WIDTH{1'b0}}, A, 1'b0};  
                fsm_state  <= 1;
            end
        end

    1: if (i < WIDTH-1) begin
            i         <= i + 1;
            acc       <= acc_next;
            quo       <= quo_next;
        end else begin
            RESULT    <= quo_next;
            remainder <= acc_next[WIDTH:1];  // undo final shift
            fsm_state <= 0;
        end 
    
    endcase
end

endmodule
