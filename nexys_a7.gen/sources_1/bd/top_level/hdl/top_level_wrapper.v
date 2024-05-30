//Copyright 1986-2021 Xilinx, Inc. All Rights Reserved.
//--------------------------------------------------------------------------------
//Tool Version: Vivado v.2021.1 (win64) Build 3247384 Thu Jun 10 19:36:33 MDT 2021
//Date        : Wed Feb  7 04:47:50 2024
//Host        : DESKTOP-06LMOH5 running 64-bit major release  (build 9200)
//Command     : generate_target top_level_wrapper.bd
//Design      : top_level_wrapper
//Purpose     : IP block netlist
//--------------------------------------------------------------------------------
`timescale 1 ps / 1 ps

module top_level_wrapper
   (BTNC,
    CLK100MHZ,
    CPU_RESETN,
    IIC_scl_io,
    IIC_sda_io);
  input BTNC;
  input CLK100MHZ;
  input CPU_RESETN;
  inout IIC_scl_io;
  inout IIC_sda_io;

  wire BTNC;
  wire CLK100MHZ;
  wire CPU_RESETN;
  wire IIC_scl_i;
  wire IIC_scl_io;
  wire IIC_scl_o;
  wire IIC_scl_t;
  wire IIC_sda_i;
  wire IIC_sda_io;
  wire IIC_sda_o;
  wire IIC_sda_t;

  IOBUF IIC_scl_iobuf
       (.I(IIC_scl_o),
        .IO(IIC_scl_io),
        .O(IIC_scl_i),
        .T(IIC_scl_t));
  IOBUF IIC_sda_iobuf
       (.I(IIC_sda_o),
        .IO(IIC_sda_io),
        .O(IIC_sda_i),
        .T(IIC_sda_t));
  top_level top_level_i
       (.BTNC(BTNC),
        .CLK100MHZ(CLK100MHZ),
        .CPU_RESETN(CPU_RESETN),
        .IIC_scl_i(IIC_scl_i),
        .IIC_scl_o(IIC_scl_o),
        .IIC_scl_t(IIC_scl_t),
        .IIC_sda_i(IIC_sda_i),
        .IIC_sda_o(IIC_sda_o),
        .IIC_sda_t(IIC_sda_t));
endmodule
