/*
=========================================================================================
si570_math.v - This module takes as its input the configuration values of an Si-570
               oscillator when it first boots up.   It uses those values to compute the
               frequency of the on-board crystal, then uses the frequency of that crystal
               to compute the new configuration values that are required to output our
               desired frequency.

               Most of the calculations in this module are in Q36.28 fixed-point.

               The target frequency that this module seeks to output is 322.265625 Mhz,
               a common frequency used to clock a 100G Ethernet CMAC.

The Si-570 datasheet that describes the calculations in the module is
available here:

https://www.skyworksinc.com/-/media/skyworks/sl/documents/public/data-sheets/si570-71.pdf

Written By: Doug Wolf
=========================================================================================
*/

module si570_math
(
    input             clk, resetn,

    // The value of the Si-570 configuration registers when it first powers up
    input      [47:0] old_si570_regs,
    
    // The new value of those registers required to generate our desired frequency
    output     [47:0] new_si570_regs,

    // We output the frequency of the Si-570 crystal for easy inspection
    output reg [31:0] fxtal,
    
    // Computation begins when this strobes high
    input             start,

    // Computation is complete when this strobes high
    output            idle

);

// The geometry of our fixed-point math is Q36.28: 36 integer bits and 28 fractional bits.
// The numerator in a division operation needs to be shifted left by "FB" bits in 
// order for the result to be in fixed point.  We're using 28 fractional bits because
// the RFREQ register in the Si-570 is in Q10.28 fixed-point format.
localparam IB = 40;
localparam FB = 28;
localparam TB = IB + FB;
localparam DB = IB + FB + FB;

// The default frequency of the Si-570, and the frequency we want to output
localparam[TB-1:0] OLD_FREQ = 156250000;
localparam[TB-1:0] NEW_FREQ = 322265625;

// These registers/wires are inputs and outputs to the "uint_div" module
reg          div_start;
reg [DB-1:0] div_A, div_B;
wire         div_idle;
wire[TB-1:0] div_RESULT;
wire[TB-1:0] div_REMAINDER;
wire         div_ROUND = (div_REMAINDER >= (div_B/2));

// There are a couple places in the state machine below where we need to do fixed-point
// division.   This is our integer division engine
uint_div #(.WIDTH(DB)) i_uint_div
( 
    .clk        (clk),
    .resetn     (resetn),
    .start      (div_start),
    .idle       (div_idle),
    .A          (div_A),
    .B          (div_B),
    .RESULT     (div_RESULT),
    .remainder  (div_REMAINDER),
    .dbz        () 
);

// The state of our state machine
reg[2:0] fsm_state;

// These are the fields that are packed into port old_si570_regs
wire[ 2:0] old_HS_DIV_reg;
wire[ 6:0] old_N1_reg;
wire[37:0] old_RFREQ;
assign {old_HS_DIV_reg, old_N1_reg, old_RFREQ} = old_si570_regs;

// Compute HS_DIV and N1 from their register values
wire[ 3:0] old_HS_DIV = old_HS_DIV_reg + 4;
wire[ 7:0] old_N1     = old_N1_reg     + 1;

// Skyworks oscillator software recommended these values for HS_DIV and N1
localparam[3:0] new_HS_DIV = 4;
localparam[7:0] new_N1     = 4;

// Compute the register settings that correspond to our new HSDIV and N1
localparam[2:0] new_HS_DIV_reg = new_HS_DIV - 4;
localparam[6:0] new_N1_reg     = new_N1      -1;
 
// Frequency of the DCO depends on this value
localparam[12:0] new_HS_DIVxN1 = new_HS_DIV * new_N1;

// Compute the DCO frequency required to achieve our desired output frequency
localparam[TB-1:0] new_fdco = (NEW_FREQ * new_HS_DIVxN1) << FB;

// This is the original frequency of the DCO
reg[TB-1:0] old_fdco;

// The Q10.28 value we need to store in RFREQ to acheive our desired output frequency
reg[37:0] new_RFREQ;

// The product of HS_DIV x N1
reg[12:0] old_HS_DIVxN1;

// This is the 6-byte value that needs to be programmed into the Si-570 frequency
// configuration registers in order to acheive our desired frequency
assign new_si570_regs = {new_HS_DIV_reg, new_N1_reg, new_RFREQ};

// We're idle when when we're in state 0 and not being told to start
assign idle = (fsm_state == 0 && start == 0); 

always @(posedge clk) begin

    // This strobes high for exactly 1 clock cycle
    div_start <= 0;

    if (resetn == 0) begin
        fsm_state <= 0;
        div_start <= 0;

    end else case (fsm_state)

        // If told to start, compute the original DCO divider
        0:  if (start) begin
                old_HS_DIVxN1 <= old_HS_DIV * old_N1;
                fsm_state     <= fsm_state + 1;
            end

        // Compute the DCO frequency of the original Si-570 settings
        1:  begin
                old_fdco  <= (OLD_FREQ * old_HS_DIVxN1) << FB;
                fsm_state <= fsm_state + 1;
            end

        // Compute the frequency of the crystal (in fixed point)
        2:  begin
                div_A     <= old_fdco << FB;
                div_B     <= old_RFREQ;
                div_start <= 1;
                fsm_state <= fsm_state + 1;
            end

        // Store the crystal frequency in fxtal (as an ordinary 32-bit integer),
        // then find the value of "new_fdco/fxtal"
        3:  if (div_idle) begin
                fxtal     <= (div_RESULT >> FB);
                div_A     <= new_fdco << FB;
                div_B     <= div_RESULT;
                div_start <= 1;
                fsm_state <= fsm_state + 1;
            end

        // When the division result becomes available, it is the Q10.28 value that
        // needs to be stored in the RFREQ register to acheive our desired frequency.
        4:  if (div_idle) begin
                new_RFREQ <= div_RESULT + div_ROUND;
                fsm_state <= 0;
            end
    endcase
 

end


endmodule