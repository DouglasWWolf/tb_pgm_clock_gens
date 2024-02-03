module si570_math
(
    input clk, resetn,

    // Fill this in with the Si-570 registers prior to strobing "start"
    input[47:0] si570_regs_in,
    
    // Computation begins when this is strobed high
    input start,
    
    // The engine is idle when this is high
    output idle,

    // Output is available here wheen "done" strobes high
    output reg[47:0] si570_regs_out,

    // Interface to the FPU
    output reg [63:0] A, B,
    output reg [ 2:0] OP,
    input      [63:0] RESULT,
    input             fpu_done

);

reg[4:0] fsm_state;

// We're idle when the state machine is doing nothing
// and no one has told us to start
assign idle = (start == 0 && fsm_state == 0);

// The opcodes that our FPU (Floating Point Unit) supports
localparam OP_NONE     = 0;
localparam OP_TO_FLOAT = 1;
localparam OP_TO_INT   = 2;
localparam OP_MULTIPLY = 3;
localparam OP_DIVIDE   = 4;

// Extract the 3 fields from the input Si-570 registers
wire[ 2:0] old_HS_DIV_REG = si570_regs_in[47:45];
wire[ 6:0] old_N1_REG     = si570_regs_in[44:38];
wire[37:0] old_RFREQ_REG  = si570_regs_in[37: 0];

// Convert the bit patterns to values usable in calculations
wire[7:0] old_N1     = old_N1_REG  + 1;
wire[7:0] old_HS_DIV = old_HS_DIV_REG + 4;

// These are the clock dividers for the new output frequency
localparam[7:0] new_N1 = 4;
localparam[7:0] new_HS_DIV = 4;    

// The 3 fields we're going to output when we're all done
localparam[ 2:0] new_HS_DIV_REG = new_HS_DIV - 4;
localparam[ 6:0] new_N1_REG     = new_N1 - 1;
reg       [37:0] new_RFREQ_REG;

// The originial frequency, and the frequency we want to output
localparam[63:0] C_OLD_NOMINAL_HZ = 156250000;
localparam[63:0] C_NEW_NOMINAL_HZ = 322265625;



// Floating point values that we're going to calculate
reg[63:0]   fp_2_power_28, 
            fp_old_nominal_hz,
            fp_old_N1xHS_DIV,
            fp_old_RFREQ_REG,
            fp_old_RFREQ,
            fp_old_fdco,
            fp_xtal,
            fp_new_fdco,
            fp_new_nominal_hz,
            fp_new_N1xHS_DIV,
            fp_new_RFREQ,
            fp_new_RFREQ_shifted,
            fp_new_RFREQ_REG;


always @(posedge clk) begin

    // This will strobe high for exactly 1 clock cycle
    OP <= OP_NONE;


    if (resetn == 0) begin
        fsm_state <= 0;

    end else case (fsm_state) 
   
        // Convert 2^28 to floating point
        0:  if (start) begin
                A                   <= (1 << 28);
                OP                  <= OP_TO_FLOAT;
                fsm_state           <= fsm_state + 1;
            end

        // Convert our nominal startup frequency to floating point
        1:  if (fpu_done) begin 
                fp_2_power_28       <= RESULT;
                A                   <= C_OLD_NOMINAL_HZ;
                OP                  <= OP_TO_FLOAT;
                fsm_state           <= fsm_state + 1;
            end

        // Convert our target frequency to floating point
        2:  if (fpu_done) begin
                fp_old_nominal_hz   <= RESULT;
                A                   <= C_NEW_NOMINAL_HZ;
                OP                  <= OP_TO_FLOAT;
                fsm_state           <= fsm_state + 1;
            end

        // Compute product of the original N1 * HS_DIV
        3:  if (fpu_done) begin
                fp_new_nominal_hz   <= RESULT;
                A                   <= old_N1 * old_HS_DIV;
                OP                  <= OP_TO_FLOAT;
                fsm_state           <= fsm_state + 1;
            end

        // Compute the product of the new N1 * HS_DIV
        4:  if (fpu_done) begin
                fp_old_N1xHS_DIV    <= RESULT;
                A                   <= new_N1 * new_HS_DIV;
                OP                  <= OP_TO_FLOAT;
                fsm_state           <= fsm_state + 1;
            end
 
        // Convert oldRFREQ_REG to floating point
        5:  if (fpu_done) begin
                fp_new_N1xHS_DIV    <= RESULT;
                A                   <= old_RFREQ_REG;
                OP                  <= OP_TO_FLOAT;
                fsm_state           <= fsm_state + 1;
            end

        // Compute the old RFREQ value (old_RFREQ / 2^28)
        6:  if (fpu_done) begin
                fp_old_RFREQ_REG    <= RESULT;
                A                   <= RESULT;
                OP                  <= OP_DIVIDE;
                B                   <= fp_2_power_28;
                fsm_state           <= fsm_state + 1;
            end

        // Compute the old FDCO (nominal_frequency * N1 * HS_DIV)
        7:  if (fpu_done) begin
                fp_old_RFREQ        <= RESULT;
                A                   <= fp_old_nominal_hz;
                OP                  <= OP_MULTIPLY;
                B                   <= fp_old_N1xHS_DIV;
                fsm_state           <= fsm_state + 1;
            end

        // Compute the new FDCO (nominal_frequency * N1 * HS_DIV)
        8:  if (fpu_done) begin
                fp_old_fdco         <= RESULT;
                A                   <= fp_new_nominal_hz;
                OP                  <= OP_MULTIPLY;
                B                   <= fp_new_N1xHS_DIV;
                fsm_state           <= fsm_state + 1;
            end

        // Use the original settings to compute the frequency of the crystal
        9:  if (fpu_done) begin
                fp_new_fdco         <= RESULT;
                A                   <= fp_old_fdco;
                OP                  <= OP_DIVIDE;
                B                   <= fp_old_RFREQ;
                fsm_state           <= fsm_state + 1;
            end

        // Compute the new RFREQ
        10: if (fpu_done) begin
                fp_xtal             <= RESULT;
                A                   <= fp_new_fdco;
                OP                  <= OP_DIVIDE;
                B                   <= RESULT;
                fsm_state           <= fsm_state + 1;
            end

        // Now scale the the new RFREQ by a factor of 2^28
        11: if (fpu_done) begin
                fp_new_RFREQ        <= RESULT;
                A                   <= RESULT;
                OP                  <= OP_MULTIPLY;
                B                   <= fp_2_power_28;
                fsm_state           <= fsm_state + 1;
            end

        // And convert that value to an integer, it's our new RFREQ setting
        12: if (fpu_done) begin
                fp_new_RFREQ_shifted <= RESULT;
                A                    <= RESULT;
                OP                   <= OP_TO_INT;
                fsm_state            <= fsm_state + 1;
            end

        // Store the new value for the RFREQ register
        13: if (fpu_done) begin
                new_RFREQ_REG  <= RESULT;
                si570_regs_out <= {new_HS_DIV_REG[2:0], new_N1_REG[6:0], RESULT[37:0]};
                fsm_state      <= 0;
            end
  
    endcase
end


endmodule
