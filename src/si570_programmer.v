module si570_programmer #
(
    parameter AXI_I2C_BASE = 32'h0000_0000,
    parameter SI_570_ADDR  = 7'h4B
)
(
    input clk, resetn,

    output reg trigger1, trigger2, trigger3,

    // The original configure registers of the Si-570, prior to 
    // reconfiguring the clock frequency
    output reg[47:0] orig_si570_config,

    // This strobes high for one clock cycle to begin programming
    input start,

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

//=========================  AXI Register Map  =============================
localparam SREG_MODULE_REV        =  0 * 4;  
localparam SREG_I2C_STATUS        =  1 * 4;  
localparam SREG_I2C_RX_DATA       =  2 * 4;
localparam SREG_I2C_TRANSACT_USEC =  3 * 4;
localparam SREG_PASSTHRU_RDATA    =  4 * 4;
localparam SREG_PASSTHRU_RESP     =  5 * 4; 

localparam CREG_DEV_ADDR          =  6 * 4;
localparam CREG_REG_NUM           =  7 * 4;
localparam CREG_REG_NUM_LEN       =  8 * 4;
localparam CREG_READ_LEN          =  9 * 4;    
localparam CREG_TX_DATA           = 10 * 4;
localparam CREG_WRITE_LEN         = 11 * 4;
localparam CREG_TLIMIT_USEC       = 12 * 4;
localparam CREG_PASSTHRU_ADDR     = 13 * 4;
localparam CREG_PASSTHRU_WDATA    = 14 * 4;
localparam CREG_PASSTHRU          = 15 * 4;
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
localparam FSM_IDLE            = 0;
localparam FSM_BEGIN           = 1;
localparam FSM_WRITE_SI570     = 20;
localparam FSM_READ_SI570      = 30;


// TX and RX data to/from the Si-570
reg[31:0] tx_data, rx_data;

// Si-570 register number
reg[ 8:0] reg_num;

// Number of bytes to read/write to/from the Si-570
reg[ 2:0] byte_count;

always @(posedge clk) begin

    trigger1 <= 0;
    trigger2 <= 0;
    trigger3 <= 0;

    // These strobe high for a single cycle at a time
    AMCI_WRITE    <= 0;
    AMCI_READ     <= 0; 
    compute_start <= 0;

    if (resetn == 0) begin
        fsm_state <= FSM_IDLE;
    end else case (fsm_state)

        FSM_IDLE:
            if (start) begin
                fsm_state <= FSM_BEGIN;
            end

        // First, tell our I2C driver what the I2C address of the Si-570 is
        FSM_BEGIN:
            begin
                AMCI_WADDR <= AXI_I2C_BASE + CREG_DEV_ADDR;
                AMCI_WDATA <= SI_570_ADDR;
                AMCI_WRITE <= 1;
                fsm_state  <= fsm_state + 1;
            end

        // Tell our I2C driver that an Si-570 uses 1 byte long register numbers
        FSM_BEGIN + 1:
            if (AMCI_WIDLE) begin
                AMCI_WADDR <= AXI_I2C_BASE + CREG_REG_NUM_LEN;
                AMCI_WDATA <= 1;
                AMCI_WRITE <= 1;
                fsm_state  <= fsm_state + 1;
            end

        // Tell our I2C driver to use a 2000 microsecond (2ms) timeout
        FSM_BEGIN + 2:
            if (AMCI_WIDLE) begin
                AMCI_WADDR <= AXI_I2C_BASE + CREG_TLIMIT_USEC;
                AMCI_WDATA <= 2000;
                AMCI_WRITE <= 1;
                fsm_state  <= fsm_state + 1;
            end
 
        // Tell the Si-570 to reset to factory default configuration
        FSM_BEGIN + 3:
            if (AMCI_WIDLE) begin
                reg_num    <= SI570_CTRL;
                tx_data    <= 1;  /* Recall NVM to RAM */
                byte_count <= 1;
                fsm_stack  <= (fsm_stack << SMSW) | (fsm_state + 1);  // push return addr
                fsm_state  <= FSM_WRITE_SI570;  // Call subroutine
            end

        // Read the first four bytes of the freq config registers
        FSM_BEGIN + 4:
            begin
                reg_num    <= SI570_FREQ_CFG;
                byte_count <= 4;
                fsm_stack  <= (fsm_stack << SMSW) | (fsm_state + 1);  // push return addr
                fsm_state  <= FSM_READ_SI570;  // Call subroutine
            end

        // Save the four bytes of configuration we just read and
        // go fetch the remaining two bytes of freq config data.
        FSM_BEGIN + 5:
            begin
                orig_si570_config[47:16] <= rx_data;
                reg_num    <= SI570_FREQ_CFG + 4;
                byte_count <= 2;
                fsm_stack  <= (fsm_stack << SMSW) | (fsm_state + 1);  // push return addr
                fsm_state  <= FSM_READ_SI570;  // Call subroutine
            end

        // Save the two bytes of config we just read and compute
        // the new values of the configuration registers
        FSM_BEGIN + 6:
            begin
                orig_si570_config[15:0] <= rx_data;
                compute_start           <= 1;
                fsm_state               <= fsm_state + 1;
                
                /// ****************** REMOVE THIS !!!!!!!!!!!!!!!!!!!!!!!!!
                orig_si570_config       <= 48'h01C2BC011EB8;
                /// ****************** REMOVE THIS !!!!!!!!!!!!!!!!!!!!!!!!!
            end

        FSM_BEGIN + 7:
            begin
                trigger1 <= 1;
                fsm_state <= FSM_IDLE;
            end




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
        FSM_WRITE_SI570:
            if (AMCI_WIDLE) begin
                AMCI_WADDR <= AXI_I2C_BASE + CREG_REG_NUM;
                AMCI_WDATA <= reg_num;
                AMCI_WRITE <= 1;
                fsm_state  <= fsm_state + 1;
            end

        // Tell the I2C controller what data to write
        FSM_WRITE_SI570 + 1:
            if (AMCI_WIDLE) begin
                AMCI_WADDR <= AXI_I2C_BASE + CREG_TX_DATA;
                AMCI_WDATA <= tx_data;
                AMCI_WRITE <= 1;
                fsm_state  <= fsm_state + 1;                
            end

        // Tell the I2C controller to write N bytes of data to the device
        FSM_WRITE_SI570 + 2:
            if (AMCI_WIDLE) begin
                AMCI_WADDR <= AXI_I2C_BASE + CREG_WRITE_LEN;
                AMCI_WDATA <= byte_count;
                AMCI_WRITE <= 1;
                fsm_state  <= fsm_state + 1;
            end

        // Wait for the I2C controller to start processing our request
        FSM_WRITE_SI570 + 3:
            if (AMCI_WIDLE && ~i2c_engine_idle)
                fsm_state <= fsm_state + 1;

        // Now wait for the I2C controller to complete our request.  When it
        // does, read the status register of the I2C controller to find out
        // if our I2C transmit request worked.
        FSM_WRITE_SI570 + 4:
            if (i2c_engine_idle) begin
                AMCI_RADDR <= AXI_I2C_BASE + SREG_I2C_STATUS;
                AMCI_READ  <= 1;
                fsm_state <= fsm_state + 1;
            end

        // When that read completes, we'll have the I2C status in
        // RDATA.  Pop the return address off the stack and return
        // to the caller
        FSM_WRITE_SI570 + 5:
            if (AMCI_RIDLE) begin
                fsm_stack <= (fsm_stack >> SMSW);  // pop the stack
                fsm_state <= fsm_stack;            // return
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
        FSM_READ_SI570:
            if (AMCI_WIDLE) begin
                AMCI_WADDR <= AXI_I2C_BASE + CREG_REG_NUM;
                AMCI_WDATA <= reg_num;
                AMCI_WRITE <= 1;
                fsm_state  <= fsm_state + 1;
            end

        // Tell the I2C controller to read N bytes of data from the device
        FSM_READ_SI570 + 1:
            if (AMCI_WIDLE) begin
                AMCI_WADDR <= AXI_I2C_BASE + CREG_READ_LEN;
                AMCI_WDATA <= byte_count;
                AMCI_WRITE <= 1;
                fsm_state  <= fsm_state + 1;
            end

        // Wait for the I2C engine to start up
        FSM_READ_SI570 + 2:
            if (AMCI_WIDLE && ~i2c_engine_idle)
                fsm_state <= fsm_state + 1;

        // Now wait for the I2C transaction to complete.  When it does, 
        // fetch the data that was just read
        FSM_READ_SI570 + 3:
            if (i2c_engine_idle) begin
                AMCI_RADDR <= AXI_I2C_BASE + SREG_I2C_RX_DATA;
                AMCI_READ  <= 1;
                fsm_state  <= fsm_state + 1;
            end

        // Save the device data in "rx_data", and fetch the status
        // of the last I2C transaction
        FSM_READ_SI570 + 4:
            if (AMCI_RIDLE) begin
                rx_data    <= AMCI_RDATA;
                AMCI_RADDR <= AXI_I2C_BASE + SREG_I2C_STATUS;
                AMCI_READ  <= 1;
                fsm_state  <= fsm_state + 1;
            end

        // When that read completes, the status from the last I2C
        // transaction is now in AMCI_RDATA.  Pop the return
        // address off the stack and return to the caller
        FSM_READ_SI570 + 5:
            if (AMCI_RIDLE) begin
                fsm_stack <= (fsm_stack >> SMSW);  // pop the stack
                fsm_state <= fsm_stack;            // return
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
