/*
    This module serves as a "front-end" for the Xilinx AXI IIC module, and greatly 
    simplifies performing register read/writes to I2C devices.

    Note: On the Xilinx AXI IIC module, the TX_FIFO_EMPTY bit of the IER doesn't work 
          the way the documentation implies.   There is no way to generate an interrupt
          at the completion of an I2C write-transaction, which is why this module polls 
          to find out when a write-transaction is complete.

*/

module emu_iic # (parameter IIC_BASE = 32'h0000_0000_0000_0000, parameter CLKS_PER_USEC = 100)
(
    input wire clk, resetn,
 
    // This is high when we're not doing anything
    output            idle,

    // Address of the I2C device we want to read/write
    input[6:0]        i_I2C_DEV_ADDR,

    // The number of bytes of "register number" to send (0, 1, or 2)
    input[1:0]        i_I2C_REG_NUM_LEN,

    // The target register of that I2C device
    input[15:0]       i_I2C_REG_NUM,

    // Set the read length and start an I2C read
    input[2:0]        i_I2C_READ_LEN,
    input             i_I2C_READ_LEN_wstrobe,

    // Data to be written to an I2C register
    input[31:0]       i_I2C_TX_DATA,

    // Set the write-length and start an I2C write
    input[2:0]        i_I2C_WRITE_LEN,
    input             i_I2C_WRITE_LEN_wstrobe,

    // Max allow duration of an I2C transaction, in microseconds
    input[31:0]       i_I2C_TLIMIT_USEC,

    // The AXI address for a "pass-through" AXI read/write of the AXI IIC module
    input[11:0]       i_PASSTHRU_ADDR,
    
    // The write-data for a "pass-through" AXI write of the AXI IIC module
    input[31:0]       i_PASSTHRU_WDATA,
    
    // Begin a "pass-thru" AXI transaction to the AXI IIC module
    input             i_PASSTHRU,
    input             i_PASSTHRU_wstrobe,  

    // The revision number of this module
    output[31:0]      o_MODULE_REV,

    // Status: idle/fault
    output[7:0]       o_I2C_STATUS,
    
    // The result of an I2C read operation is output here
    output [31:0]     o_I2C_RX_DATA,

    // The number of microseconds that the I2C transaction took
    output reg[31:0]  o_I2C_TRANSACT_USEC,

    // The data-returned from a "pass-thru" AXI read of the AXI IIC module
    output reg[31:0]  o_PASSTHRU_RDATA,

    // The RRESP or BRESP value from the most recent pass-thu transaction
    output reg[1:0]   o_PASSTHRU_RESP

);

// AXI IIC registers
localparam  IIC_GIE          = IIC_BASE + 12'h01C;
localparam  IIC_ISR          = IIC_BASE + 12'h020;
localparam  IIC_IER          = IIC_BASE + 12'h028;
localparam  IIC_SOFTR        = IIC_BASE + 12'h040;
localparam  IIC_CR           = IIC_BASE + 12'h100;
localparam  IIC_SR           = IIC_BASE + 12'h104;
localparam  IIC_TX_FIFO      = IIC_BASE + 12'h108;
localparam  IIC_RX_FIFO      = IIC_BASE + 12'h10C;
localparam  IIC_RX_FIFO_OCY  = IIC_BASE + 12'h118;
localparam  IIC_RX_FIFO_PIRQ = IIC_BASE + 12'h120;


// Bit fields of IIC_CR
localparam  EN = 1;
localparam  TX_FIFO_RESET = 2;

// Bit fields in IIC_IER and IIC_ISR
localparam ARB_LOST = 1;
localparam TX_ERR   = 2;
localparam TX_EMPTY = 4;
localparam RX_FULL  = 8;

// Bit values for IIC_TX_FIFO
localparam I2C_START = {2'b01};
localparam I2C_STOP  = {2'b10};
localparam I2C_RD    = 1'b1;
localparam I2C_WR    = 1'b0;


//------------------- States of our primary state machine ---------------------
reg[6:0]    fsm_state, return_state;
localparam  FSM_IDLE         = 0;
localparam  FSM_READ_IIC     = 10;
localparam  FSM_WRITE_IIC    = 20;
localparam  FSM_PASSTHRU_WR  = 30;
localparam  FSM_PASSTHRU_RD  = 40;
localparam  FSM_SEND_REG_NUM = 45;
localparam  FSM_TIMEOUT      = 50;
localparam  FSM_BUS_FAULT    = 51;
//-----------------------------------------------------------------------------

// Definitions i_PASSTHRU
localparam  PASSTHRU_READ  = 0;
localparam  PASSTHRU_WRITE = 1;

// This is high when a bus-fault has occured
reg bus_fault;

// This is high when the duration an I2C transaction has exceeded i_I2C_TLIMIT_USEC
reg i2c_timeout;

// We're idle when we're in IDLE state, and no "start this function" signals are asserted
assign idle =
(
    (fsm_state == FSM_IDLE       ) && 
    (i_I2C_READ_LEN_wstrobe  == 0) &&
    (i_I2C_WRITE_LEN_wstrobe == 0) &&
    (i_PASSTHRU_wstrobe      == 0)
);


// The status output is an aggregation of these states
assign o_I2C_STATUS = {i2c_timeout, bus_fault, idle};

// This is the first revision of this module
assign o_MODULE_REV = 1;

// Received data from the I2C device
reg[7:0] rx_data[0:3];
reg[1:0] byte_index;

// The data we receive from the I2C device is stored in rx_data[]
assign o_I2C_RX_DATA = {rx_data[3], rx_data[2], rx_data[1], rx_data[0]};

// This is an index into the "rca" and "rcd" arrays below
reg[3:0] cmd_index;

// This is a convenient short-cut for indexing the bytes of "i_TX_TDATA"
wire[7:0] tx_byte = (byte_index == 3) ? i_I2C_TX_DATA[31:24] :
                    (byte_index == 2) ? i_I2C_TX_DATA[23:16] :
                    (byte_index == 1) ? i_I2C_TX_DATA[15:08] :
                                        i_I2C_TX_DATA[07:00];

wire[7:0] tx_data[3:0];
assign tx_data[0] = i_I2C_TX_DATA[ 7: 0];
assign tx_data[1] = i_I2C_TX_DATA[15: 8];
assign tx_data[2] = i_I2C_TX_DATA[23:16];
assign tx_data[3] = i_I2C_TX_DATA[31:24];


//-----------------------------------------------------------------------------
// IIC AXI configuration for a read operation
//-----------------------------------------------------------------------------

// Read-command address, and Read-command data
wire[31:0] rca[0:4], rcd[0:4];

assign rca[00] = IIC_SOFTR;      ;assign rcd[00] = 4'b1010;             // Soft-reset of the AXI IIC module
assign rca[01] = IIC_RX_FIFO_PIRQ;assign rcd[01] = i_I2C_READ_LEN - 1;  // Set the number of bytes we expect to receive
assign rca[02] = IIC_IER         ;assign rcd[02] = RX_FULL | TX_ERR | ARB_LOST;
assign rca[03] = IIC_GIE         ;assign rcd[03] = 32'h8000_0000;       // Globally enable interrupts
assign rca[04] = 0               ;assign rcd[04] = 0;
//-----------------------------------------------------------------------------




//-----------------------------------------------------------------------------
// IIC AXI configuration for a write operation
//-----------------------------------------------------------------------------

// Write-command address, and Write-command data
wire[31:0] wca[0:3], wcd[0:3];

assign wca[00] = IIC_SOFTR;      ;assign wcd[00] = 4'b1010;             // Soft-reset of the AXI IIC module
assign wca[01] = IIC_IER         ;assign wcd[01] = TX_ERR | ARB_LOST;
assign wca[02] = IIC_GIE         ;assign wcd[02] = 32'h8000_0000;       // Globally enable interrupts
assign wca[03] = 0;              ;assign wcd[03] = 0;
//-----------------------------------------------------------------------------


//=============================================================================
// This block counts elapsed microseconds.  Count is reset to zero on 
// any cycle where "usec_reset" is high
//=============================================================================
reg                            usec_reset;
//-----------------------------------------------------------------------------
reg[31:0]                      usec_ticks;
reg[$clog2(CLKS_PER_USEC-1):0] usec_counter;
//-----------------------------------------------------------------------------
always @(posedge clk) begin

    if (resetn == 0 || usec_reset == 1) begin
        usec_counter <= 0;
        usec_ticks   <= 0; 
    end

    else if (usec_counter < CLKS_PER_USEC-1)
        usec_counter <= usec_counter + 1;

    else begin
        usec_counter <= 0;
        usec_ticks   <= usec_ticks + 1;
    end

end

// Other blocks should use "usec_elapsed" to determine how many
// microseconds have elapsed since usec_reset was last asserted
wire[31:0] usec_elapsed = usec_reset ? 0 : usec_ticks;
//=============================================================================

localparam[47:0] SI570_DEFAULT = 48'h01C2BC011EB8;
reg[7:0] i2c_switch;
reg[7:0] si570[0:137];

reg[31:0] delay;

//=============================================================================
// This is the main state machine, handling I2C-related transactions
//=============================================================================
reg[31:0] end_of_transaction;

//-----------------------------------------------------------------------------
always @(posedge clk) begin

    if (delay) delay <= delay - 1;

    // These signals only strobe high for a single cycle
    usec_reset <= 0;

    if (resetn == 0) begin
        fsm_state <= 0;
        i2c_switch <= 0;
        si570[ 7]  <= 8'h01;
        si570[ 8]  <= 8'hC2;
        si570[ 9]  <= 8'hBC;
        si570[10]  <= 8'h01;
        si570[11]  <= 8'h1E;
        si570[12]  <= 8'hB8;
    end else case (fsm_state)

        FSM_IDLE:
            begin
                // Were we just told to start an I2C "read register" transaction?
                if (i_I2C_READ_LEN_wstrobe && i_I2C_READ_LEN >= 1 && i_I2C_READ_LEN <= 4) begin
                    {rx_data[3], rx_data[2], rx_data[1],rx_data[0]} <= 0;
                    cmd_index   <= 0;
                    i2c_timeout <= 0;
                    bus_fault   <= 0;
                    byte_index  <= i_I2C_READ_LEN - 1;
                    fsm_state   <= FSM_READ_IIC;
                end

                // Were we just told to start an I2C "write register" transaction?
                if (i_I2C_WRITE_LEN_wstrobe && i_I2C_WRITE_LEN >= 1 && i_I2C_WRITE_LEN <= 4) begin
                    cmd_index   <= 0;
                    i2c_timeout <= 0;
                    bus_fault   <= 0;
                    byte_index  <= i_I2C_WRITE_LEN - 1;                
                    fsm_state   <= FSM_WRITE_IIC;
                end

            end

        //-----------------------------------------------------------------------------------
        // Start of state machine for performing an I2C read operation
        //-----------------------------------------------------------------------------------

        // Configure all the neccessary registers in the AXI IIC core. When
        // that's done, we'll set up to send the device-register number  
        FSM_READ_IIC:
            begin 
                rx_data[0] <= 0;
                rx_data[1] <= 0;
                rx_data[2] <= 0;
                rx_data[3] <= 0;
                if (i_I2C_DEV_ADDR == 7'h70) begin
                    rx_data[0] <= i2c_switch;
                end 

                else if (i_I2C_DEV_ADDR == 7'h55) begin
                    case (i_I2C_READ_LEN)

                    1:  begin
                            rx_data[0] <= si570[i_I2C_REG_NUM + 0];
                        end

                    2:  begin
                            rx_data[1] <= si570[i_I2C_REG_NUM + 0];
                            rx_data[0] <= si570[i_I2C_REG_NUM + 1];
                        end

                    3:  begin
                            rx_data[2] <= si570[i_I2C_REG_NUM + 0];
                            rx_data[1] <= si570[i_I2C_REG_NUM + 1];
                            rx_data[0] <= si570[i_I2C_REG_NUM + 2];
                        end

                    4:  begin
                            rx_data[3] <= si570[i_I2C_REG_NUM + 0];
                            rx_data[2] <= si570[i_I2C_REG_NUM + 1];
                            rx_data[1] <= si570[i_I2C_REG_NUM + 2];
                            rx_data[0] <= si570[i_I2C_REG_NUM + 3];
                        end

                    endcase                
                end

                delay     <= 10;
                fsm_state <= fsm_state  + 1;

            end

        FSM_READ_IIC + 1:
            if (delay == 0) fsm_state <= FSM_IDLE;
   
        //-----------------------------------------------------------------------------------
        // Start of state machine for performing an I2C write operation
        //-----------------------------------------------------------------------------------

        FSM_WRITE_IIC:
            begin 
                if (i_I2C_DEV_ADDR == 7'h70) begin
                    i2c_switch <= tx_data[0];
                end 

                else if (i_I2C_DEV_ADDR == 7'h55) begin
                    case (i_I2C_WRITE_LEN)

                    1:  begin
                            si570[i_I2C_REG_NUM + 0] <= tx_data[0] ;
                        end

                    2:  begin
                            si570[i_I2C_REG_NUM + 0] <= tx_data[1] ;
                            si570[i_I2C_REG_NUM + 1] <= tx_data[0] ;
                        end

                    3:  begin
                            si570[i_I2C_REG_NUM + 0] <= tx_data[2] ;
                            si570[i_I2C_REG_NUM + 1] <= tx_data[1] ;
                            si570[i_I2C_REG_NUM + 2] <= tx_data[0] ;
                        end

                    4:  begin
                            si570[i_I2C_REG_NUM + 0] <= tx_data[3] ;
                            si570[i_I2C_REG_NUM + 1] <= tx_data[2] ;
                            si570[i_I2C_REG_NUM + 2] <= tx_data[1] ;
                            si570[i_I2C_REG_NUM + 3] <= tx_data[0] ;
                        end

                    endcase                
                end

                fsm_state <= fsm_state  + 1;

            end

        FSM_WRITE_IIC + 1:
            begin
                if (i_I2C_DEV_ADDR == 7'h55 && i_I2C_REG_NUM == 135) begin
                    if (si570[135][0] == 1) begin
                        si570[135][0] <= 0;
                        si570[ 7]     <= 8'h01;
                        si570[ 8]     <= 8'hC2;
                        si570[ 9]     <= 8'hBC;
                        si570[10]     <= 8'h01;
                        si570[11]     <= 8'h1E;
                        si570[12]     <= 8'hB8;
                    end
                end 
                delay     <= 8;
                fsm_state <= fsm_state + 1;
            end

        FSM_WRITE_IIC + 2:
            if (delay == 0) fsm_state <= FSM_IDLE;

   
        //-----------------------------------------------------------------------------------
        // We get here if the duration of a transaction exceed i_I2C_TLIMIT_USEC
        //-----------------------------------------------------------------------------------
        FSM_TIMEOUT:
            begin
                {rx_data[3], rx_data[2], rx_data[1],rx_data[0]} <= 32'hDEAD_BEEF;
                o_I2C_TRANSACT_USEC <= usec_elapsed;
                i2c_timeout         <= 1;
                fsm_state           <= FSM_IDLE;
            end

        //-----------------------------------------------------------------------------------
        // We get here if a bus fault is detected
        //-----------------------------------------------------------------------------------
        FSM_BUS_FAULT:
            begin
                {rx_data[3], rx_data[2], rx_data[1],rx_data[0]} <= 32'hDEAD_BEEF;
                o_I2C_TRANSACT_USEC <= usec_elapsed;
                bus_fault           <= 1;
                fsm_state           <= FSM_IDLE;
            end

 
    endcase

end
//=============================================================================



endmodule