/*
===============================================================================
si570_prog_ctl.v - This module manages the si570 programmer to program
                   both Si-570's shortly after the system comes out of reset.

Written by Doug Wolf
===============================================================================
*/

module si570_prog_ctl # (parameter CLOCK_FREQ = 200000000)
(
    input             clk, resetn,
    
    // Strobing this high for a cycle will reprogram the Si-570's
    input             reprogram,
    
    // This goes high to start programming an Si-570
    output  reg       pgm_start,

    // This goes high when programming a single Si-570 is complete
    input             pgm_done,

    // The Si-570 programmer reports faults here
    input             pgm_fault,
    
    // This selects which Si-570 is to be programmed
    output  reg       which_si570,
   
    // When this is asserted, both Si-570's have been programmed (or failed)
    output            done,

    // These bits report faults during the Si-570 programming process
    output  reg [1:0] fault
);

reg[ 2:0] fsm_state;
reg[31:0] delay;

localparam FSM_DONE = 7;

// Tell the outside world when we're done
assign done = fsm_state == FSM_DONE;

always @(posedge clk) begin

    // This will strobe high for exactly 1 cycle at a time
    pgm_start <= 0;

    // This is a count-down timer
    if (delay) delay <= delay - 1;

    if (resetn == 0) begin
        fsm_state <= 0;
        
    end else case(fsm_state)

        // Start programming Si-570 #0
        0:  begin
                fault       <= 0;
                which_si570 <= 0;
                pgm_start   <= 1;
                fsm_state   <= fsm_state + 1;
            end

        // Wait for programming to complete, record any fault
        // and start programming Si-570 #1
        1:  if (pgm_done) begin
                fault[0]    <= pgm_fault;
                which_si570 <= 1;
                pgm_start   <= 1;
                fsm_state   <= fsm_state + 1;
            end

        // Wait for programming to complete, record any fault,
        // then start waiting 10 ms for the output frequencies
        // of the Si-570 oscillators to settle
        2:  if (pgm_done) begin
                fault[1]  <= pgm_fault;
                delay     <= CLOCK_FREQ / 100;
                fsm_state <= fsm_state + 1;
            end

        // When the 10 ms is up, we're done
        3:  if (delay == 0)
                fsm_state <= FSM_DONE;

        // While we're in the "DONE" state, if we receive a signal to
        // reprogram the Si-570's, make it so
        FSM_DONE:
            if (reprogram)
                fsm_state <= 0;
    endcase
end


endmodule 