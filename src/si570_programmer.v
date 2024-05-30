module si570_programmer #
(
    parameter CLOCK_FREQ   = 200000000,
    parameter AXI_I2C_BASE = 32'h0000_1000,
    parameter SI_570_ADDR  = 7'h55,
    parameter I2C_SW_ADDR  = 7'h70
)
(
    input clk, resetn,

    // The original configure registers of the Si-570, prior to 
    // reconfiguring the clock frequency
    output reg[47:0] orig_si570_config,

    // This strobes high for one clock cycle to begin programming
    input start,

    // Which Si-570 is being programmed?
    input which,

    // This will go high to indicate completion
    output idle,

    // When "idle" goes high, if this is high, something went wrong
    output reg fault,

    // When the I2C engine is idle, this should be high
    input i2c_engine_idle,

    // This strobes high to tell the compute engine to start
    output reg compute_start,

    // This goes high when the compute engine is done
    input compute_idle,

    // The compute engine fills this in with the new Si-570 config values
    input [47:0] new_si570_config,

    //====================  An AXI-Lite Master Interface  ======================

    // "Specify write address"          -- Master --    -- Slave --
    output[31:0]                        AXI_AWADDR,   
    output                              AXI_AWVALID,  
    output[2:0]                         AXI_AWPROT,
    input                                               AXI_AWREADY,

    // "Write Data"                     -- Master --    -- Slave --
    output[31:0]                        AXI_WDATA,      
    output                              AXI_WVALID,
    output[3:0]                         AXI_WSTRB,
    input                                               AXI_WREADY,

    // "Send Write Response"            -- Master --    -- Slave --
    input[1:0]                                          AXI_BRESP,
    input                                               AXI_BVALID,
    output                              AXI_BREADY,

    // "Specify read address"           -- Master --    -- Slave --
    output[31:0]                        AXI_ARADDR,     
    output                              AXI_ARVALID,
    output[2:0]                         AXI_ARPROT,     
    input                                               AXI_ARREADY,

    // "Read data back to master"       -- Master --    -- Slave --
    input[31:0]                                         AXI_RDATA,
    input                                               AXI_RVALID,
    input[1:0]                                          AXI_RRESP,
    output                              AXI_RREADY
    //==========================================================================

);

//==========================================================================
// We use these as the AMCI interface to an AXI4-Lite Master
//==========================================================================
reg[31:0]  AMCI_WADDR;
reg[31:0]  AMCI_WDATA;
reg        AMCI_WRITE;
wire[1:0]  AMCI_WRESP;
wire       AMCI_WIDLE;
reg[31:0]  AMCI_RADDR;
reg        AMCI_READ;
wire[31:0] AMCI_RDATA;
wire[1:0]  AMCI_RRESP;
wire       AMCI_RIDLE;
//==========================================================================


//==========================================================================
//                Register map of the I2C controller
//==========================================================================
localparam SREG_MODULE_REV        = ( 0 * 4);  
localparam SREG_I2C_STATUS        = ( 1 * 4);  
localparam SREG_I2C_RX_DATA       = ( 2 * 4);
localparam SREG_I2C_TRANSACT_USEC = ( 3 * 4);
localparam SREG_PASSTHRU_RDATA    = ( 4 * 4);
localparam SREG_PASSTHRU_RESP     = ( 5 * 4);
localparam SREG_RESERVED_1        = ( 6 * 4);
localparam SREG_RESERVED_2        = ( 7 * 4);
localparam SREG_RESERVED_3        = ( 8 * 4);
localparam SREG_RESERVED_4        = ( 9 * 4);

localparam CREG_DEV_ADDR          = (10 * 4);
localparam CREG_REG_NUM           = (11 * 4);
localparam CREG_REG_NUM_LEN       = (12 * 4);
localparam CREG_READ_LEN          = (13 * 4);    
localparam CREG_TX_DATA           = (14 * 4);
localparam CREG_WRITE_LEN         = (15 * 4);
localparam CREG_TLIMIT_USEC       = (16 * 4);
localparam CREG_PASSTHRU_ADDR     = (17 * 4);
localparam CREG_PASSTHRU_WDATA    = (18 * 4);
localparam CREG_PASSTHRU          = (19 * 4);
//==========================================================================


//==========================================================================
// Registers on the Si-570 
//==========================================================================
localparam SI570_FREQ_CFG   = 7;
localparam SI570_CTRL       = 135;
localparam SI570_FREEZE_DCO = 137;
//==========================================================================

// State Machine State Width (in bits)
localparam SMSW = 8;

// State of the state machine
reg [SMSW-1  :0] fsm_state;

// A "return address" stack for the state machine
reg [SMSW*4-1:0] fsm_stack;

// Important states of the state machine
localparam FSM_IDLE      = 0;
localparam FSM_BEGIN     = 1;
localparam FSM_WRITE_I2C = 20;
localparam FSM_READ_I2C  = 30;

// The "idle" port is high when we're not doing anything
assign idle = (start == 0) && (fsm_state == FSM_IDLE);

//=============================================================================
// These register are input and output parameters for the FSM_WRITE_I2C and
// FSM_READ_I2C subroutines
//=============================================================================

// TX and RX data to/from the I2C device
reg[31:0] tx_data, rx_data;

// I2C device register number
reg[ 8:0] reg_num;

// Number of bytes to read/write to/from the I2C device
reg[ 2:0] byte_count;
//=============================================================================


reg[31:0] delay;

always @(posedge clk) begin

    // This is a count-down timer
    if (delay) delay <= delay -1;

    // These strobe high for a single cycle at a time
    AMCI_WRITE    <= 0;
    AMCI_READ     <= 0; 
    compute_start <= 0;

    if (resetn == 0) begin
        fsm_state <= FSM_IDLE;
        fault     <= 0;
    end else case (fsm_state)

        FSM_IDLE:
            if (start) begin
                fault     <= 0;
                fsm_state <= FSM_BEGIN;
            end

        // Tell our I2C driver to use a 2000 microsecond (2ms) timeout
        FSM_BEGIN:
            begin
                AMCI_WADDR <= AXI_I2C_BASE + CREG_TLIMIT_USEC;
                AMCI_WDATA <= 2000;
                AMCI_WRITE <= 1;
                fsm_state  <= fsm_state + 1;
            end

        // Tell our I2C driver what the address of the I2C-switch is
        FSM_BEGIN + 1:
            begin
                AMCI_WADDR <= AXI_I2C_BASE + CREG_DEV_ADDR;
                AMCI_WDATA <= I2C_SW_ADDR;
                AMCI_WRITE <= 1;
                fsm_state  <= fsm_state + 1;
            end


        // Tell our I2C driver that the I2C switch doesn't use register numbers
        FSM_BEGIN + 2:
            if (AMCI_WIDLE) begin
                AMCI_WADDR <= AXI_I2C_BASE + CREG_REG_NUM_LEN;
                AMCI_WDATA <= 0;
                AMCI_WRITE <= 1;
                fsm_state  <= fsm_state + 1;
            end

        // Tell the I2C switch to select our desired Si-570
        FSM_BEGIN + 3:
            if (AMCI_WIDLE) begin
                tx_data    <= (1 << which);
                byte_count <= 1;
                fsm_stack  <= (fsm_stack << SMSW) | (fsm_state + 1);  // push return addr
                fsm_state  <= FSM_WRITE_I2C;                          // call subroutine
            end

        // Now, tell our I2C driver what the I2C address of the Si-570 is
        FSM_BEGIN + 4:
            begin
                AMCI_WADDR <= AXI_I2C_BASE + CREG_DEV_ADDR;
                AMCI_WDATA <= SI_570_ADDR;
                AMCI_WRITE <= 1;
                fsm_state  <= fsm_state + 1;
            end

        // Tell our I2C driver that an Si-570 uses 1 byte long register numbers
        FSM_BEGIN + 5:
            if (AMCI_WIDLE) begin
                AMCI_WADDR <= AXI_I2C_BASE + CREG_REG_NUM_LEN;
                AMCI_WDATA <= 1;
                AMCI_WRITE <= 1;
                fsm_state  <= fsm_state + 1;
            end

        // Tell the Si-570 to reset to factory default configuration
        FSM_BEGIN + 6:
            if (AMCI_WIDLE) begin
                reg_num    <= SI570_CTRL;
                tx_data    <= 1;  /* Recall NVM to RAM */
                byte_count <= 1;
                fsm_stack  <= (fsm_stack << SMSW) | (fsm_state + 1);  // push return addr
                fsm_state  <= FSM_WRITE_I2C;                          // call subroutine
            end

        // Pause for a tenth of a second while the Si-570 resets
        FSM_BEGIN + 7:
            begin
                delay     <= 1;  //CLOCK_FREQ / 100;
                fsm_state <= fsm_state + 1;
            end

        // Read the first four bytes of the freq config registers
        FSM_BEGIN + 8:
            if (delay == 0) begin
                reg_num    <= SI570_FREQ_CFG;
                byte_count <= 4;
                fsm_stack  <= (fsm_stack << SMSW) | (fsm_state + 1);  // push return addr
                fsm_state  <= FSM_READ_I2C;                           // call subroutine
            end

        // Save the four bytes of configuration we just read and
        // go fetch the remaining two bytes of freq config data.
        FSM_BEGIN + 9:
            begin
                orig_si570_config[47:16] <= rx_data;
                reg_num                  <= SI570_FREQ_CFG + 4;
                byte_count               <= 2;
                fsm_stack                <= (fsm_stack << SMSW) | (fsm_state + 1);  // push return addr
                fsm_state                <= FSM_READ_I2C;                           // call subroutine
            end

        // Save the two bytes of config we just read and compute
        // the new values of the configuration registers
        FSM_BEGIN + 10:
            begin
                orig_si570_config[15:0] <= rx_data;
                compute_start           <= 1;
                fsm_state               <= fsm_state + 1;
            end

        // Wait for the computation to complete.  When it does, tell the Si-570
        // to freeze the DCO
        FSM_BEGIN + 11:
            if (compute_idle) begin
                reg_num    <= SI570_FREEZE_DCO;
                tx_data    <= (1 << 4);
                byte_count <= 1;
                fsm_stack  <= (fsm_stack << SMSW) | (fsm_state + 1);  // push return addr
                fsm_state  <= FSM_WRITE_I2C;                          // call subroutine
            end

        // Write the first 4 bytes of the new configuration to the Si-570
        FSM_BEGIN + 12:
             begin
                reg_num    <= SI570_FREQ_CFG;
                tx_data    <= new_si570_config[47:16];
                byte_count <= 4;
                fsm_stack  <= (fsm_stack << SMSW) | (fsm_state + 1);  // push return addr
                fsm_state  <= FSM_WRITE_I2C;                          // call subroutine
            end

        // Now write the last two bytes of the new configuration to the Si-570 
        FSM_BEGIN + 13:
            begin
                reg_num    <= SI570_FREQ_CFG + 4;
                tx_data    <= new_si570_config[15:0];
                byte_count <= 2;
                fsm_stack  <= (fsm_stack << SMSW) | (fsm_state + 1);  // push return addr
                fsm_state  <= FSM_WRITE_I2C;                          // call subroutine
            end

        // Unfreeze the DCO
        FSM_BEGIN + 14:
            begin
                reg_num    <= SI570_FREEZE_DCO;
                tx_data    <= 0;
                byte_count <= 1;
                fsm_stack  <= (fsm_stack << SMSW) | (fsm_state + 1);  // push return addr
                fsm_state  <= FSM_WRITE_I2C;                          // call subroutine
            end

  
        // Tell the Si-570 to start generating at the new frequency
        FSM_BEGIN + 15:
            begin
                reg_num    <= SI570_CTRL;
                tx_data    <= (1 << 6);  /* Assert the NewFreq bit */
                byte_count <= 1;
                fsm_stack  <= (fsm_stack << SMSW) | (fsm_state + 1);  // push return addr
                fsm_state  <= FSM_WRITE_I2C;                          // call subroutine
            end

        // We're done!
        FSM_BEGIN + 16:
            fsm_state <= FSM_IDLE;


        //---------------------------------------------------------------------
        // This is a subroutine that writes a value to an Si-570 register
        //
        // On Entry: reg_num    = Si-570 register number
        //           tx_data    = 1 to 4 bytes of data to be written
        //           byte_count = # of bytes to write
        //
        // On Exit: AMCI_RDATA = The I2C engine status register
        //---------------------------------------------------------------------

        // Tell the I2C controller what device register to write to
        FSM_WRITE_I2C:
            if (AMCI_WIDLE) begin
                AMCI_WADDR <= AXI_I2C_BASE + CREG_REG_NUM;
                AMCI_WDATA <= reg_num;
                AMCI_WRITE <= 1;
                fsm_state  <= fsm_state + 1;
            end

        // Tell the I2C controller what data to write
        FSM_WRITE_I2C + 1:
            if (AMCI_WIDLE) begin
                AMCI_WADDR <= AXI_I2C_BASE + CREG_TX_DATA;
                AMCI_WDATA <= tx_data;
                AMCI_WRITE <= 1;
                fsm_state  <= fsm_state + 1;                
            end

        // Tell the I2C controller to write N bytes of data to the device
        FSM_WRITE_I2C + 2:
            if (AMCI_WIDLE) begin
                AMCI_WADDR <= AXI_I2C_BASE + CREG_WRITE_LEN;
                AMCI_WDATA <= byte_count;
                AMCI_WRITE <= 1;
                fsm_state  <= fsm_state + 1;
            end

        // Wait for the I2C controller to start processing our request
        FSM_WRITE_I2C + 3:
            if (AMCI_WIDLE && ~i2c_engine_idle)
                fsm_state <= fsm_state + 1;

        // Now wait for the I2C controller to complete our request.  When it
        // does, read the status register of the I2C controller to find out
        // if our I2C transmit request worked.
        FSM_WRITE_I2C + 4:
            if (i2c_engine_idle) begin
                AMCI_RADDR <= AXI_I2C_BASE + SREG_I2C_STATUS;
                AMCI_READ  <= 1;
                fsm_state <= fsm_state + 1;
            end

        // When that read completes, we'll have the I2C status in AMCI_RDATA
        FSM_WRITE_I2C + 5:
            if (AMCI_RIDLE) begin
                if (AMCI_RDATA == 1) begin
                    fsm_stack <= (fsm_stack >> SMSW);  // pop the stack
                    fsm_state <= fsm_stack;            // return
                end else begin
                    fault     <= 1;
                    fsm_state <= FSM_IDLE;
                end
            end


        //---------------------------------------------------------------------
        // This is a subroutine that reads a value from an Si-570 register
        //
        // On Entry: reg_num    = Si-570 register number
        //           byte_count = # of bytes to read
        //
        // On Exit: AMCI_RDATA = The I2C engine status register
        //          rx_data    = The data we read from the Si-570
        //---------------------------------------------------------------------
        
        // Tell the I2C controller what device register to read from
        FSM_READ_I2C:
            if (AMCI_WIDLE) begin
                AMCI_WADDR <= AXI_I2C_BASE + CREG_REG_NUM;
                AMCI_WDATA <= reg_num;
                AMCI_WRITE <= 1;
                fsm_state  <= fsm_state + 1;
            end

        // Tell the I2C controller to read N bytes of data from the device
        FSM_READ_I2C + 1:
            if (AMCI_WIDLE) begin
                AMCI_WADDR <= AXI_I2C_BASE + CREG_READ_LEN;
                AMCI_WDATA <= byte_count;
                AMCI_WRITE <= 1;
                fsm_state  <= fsm_state + 1;
            end

        // Wait for the I2C engine to start up
        FSM_READ_I2C + 2:
            if (AMCI_WIDLE && ~i2c_engine_idle)
                fsm_state <= fsm_state + 1;

        // Now wait for the I2C transaction to complete.  When it does, 
        // fetch the data that was just read
        FSM_READ_I2C + 3:
            if (i2c_engine_idle) begin
                AMCI_RADDR <= AXI_I2C_BASE + SREG_I2C_RX_DATA;
                AMCI_READ  <= 1;
                fsm_state  <= fsm_state + 1;
            end

        // Save the device data in "rx_data", and fetch the status
        // of the last I2C transaction
        FSM_READ_I2C + 4:
            if (AMCI_RIDLE) begin
                rx_data    <= AMCI_RDATA;
                AMCI_RADDR <= AXI_I2C_BASE + SREG_I2C_STATUS;
                AMCI_READ  <= 1;
                fsm_state  <= fsm_state + 1;
            end

        // When that read completes, the status from the last I2C
        // transaction is now in AMCI_RDATA. 
        FSM_READ_I2C + 5:
            if (AMCI_RIDLE) begin
                if (AMCI_RDATA == 1) begin
                    fsm_stack <= (fsm_stack >> SMSW);  // pop the stack
                    fsm_state <= fsm_stack;            // return
                end else begin
                    fault     <= 1;
                    fsm_state <= FSM_IDLE;
                end
            end

    endcase


end





//==========================================================================
// This wires a connection to an AXI4-Lite bus master
//==========================================================================
axi4_lite_master
(
    .clk            (clk),
    .resetn         (resetn),

    .AMCI_WADDR     (AMCI_WADDR),
    .AMCI_WDATA     (AMCI_WDATA),
    .AMCI_WRITE     (AMCI_WRITE),
    .AMCI_WRESP     (AMCI_WRESP),
    .AMCI_WIDLE     (AMCI_WIDLE),

    .AMCI_RADDR     (AMCI_RADDR),
    .AMCI_READ      (AMCI_READ ),
    .AMCI_RDATA     (AMCI_RDATA),
    .AMCI_RRESP     (AMCI_RRESP),
    .AMCI_RIDLE     (AMCI_RIDLE),

    .AXI_AWADDR     (AXI_AWADDR),
    .AXI_AWVALID    (AXI_AWVALID),
    .AXI_AWPROT     (AXI_AWPROT),
    .AXI_AWREADY    (AXI_AWREADY),

    .AXI_WDATA      (AXI_WDATA),
    .AXI_WVALID     (AXI_WVALID),
    .AXI_WSTRB      (AXI_WSTRB),
    .AXI_WREADY     (AXI_WREADY),

    .AXI_BRESP      (AXI_BRESP),
    .AXI_BVALID     (AXI_BVALID),
    .AXI_BREADY     (AXI_BREADY),

    .AXI_ARADDR     (AXI_ARADDR),
    .AXI_ARVALID    (AXI_ARVALID),
    .AXI_ARPROT     (AXI_ARPROT),
    .AXI_ARREADY    (AXI_ARREADY),

    .AXI_RDATA      (AXI_RDATA),
    .AXI_RVALID     (AXI_RVALID),
    .AXI_RRESP      (AXI_RRESP),
    .AXI_RREADY     (AXI_RREADY)
);
//==========================================================================



endmodule
