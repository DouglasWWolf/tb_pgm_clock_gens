# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "AXI_I2C_BASE" -parent ${Page_0}
  ipgui::add_param $IPINST -name "CLOCK_FREQ" -parent ${Page_0}
  ipgui::add_param $IPINST -name "I2C_SW_ADDR" -parent ${Page_0}
  ipgui::add_param $IPINST -name "SI_570_ADDR" -parent ${Page_0}


}

proc update_PARAM_VALUE.AXI_I2C_BASE { PARAM_VALUE.AXI_I2C_BASE } {
	# Procedure called to update AXI_I2C_BASE when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.AXI_I2C_BASE { PARAM_VALUE.AXI_I2C_BASE } {
	# Procedure called to validate AXI_I2C_BASE
	return true
}

proc update_PARAM_VALUE.CLOCK_FREQ { PARAM_VALUE.CLOCK_FREQ } {
	# Procedure called to update CLOCK_FREQ when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.CLOCK_FREQ { PARAM_VALUE.CLOCK_FREQ } {
	# Procedure called to validate CLOCK_FREQ
	return true
}

proc update_PARAM_VALUE.I2C_SW_ADDR { PARAM_VALUE.I2C_SW_ADDR } {
	# Procedure called to update I2C_SW_ADDR when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.I2C_SW_ADDR { PARAM_VALUE.I2C_SW_ADDR } {
	# Procedure called to validate I2C_SW_ADDR
	return true
}

proc update_PARAM_VALUE.SI_570_ADDR { PARAM_VALUE.SI_570_ADDR } {
	# Procedure called to update SI_570_ADDR when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.SI_570_ADDR { PARAM_VALUE.SI_570_ADDR } {
	# Procedure called to validate SI_570_ADDR
	return true
}


proc update_MODELPARAM_VALUE.CLOCK_FREQ { MODELPARAM_VALUE.CLOCK_FREQ PARAM_VALUE.CLOCK_FREQ } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.CLOCK_FREQ}] ${MODELPARAM_VALUE.CLOCK_FREQ}
}

proc update_MODELPARAM_VALUE.AXI_I2C_BASE { MODELPARAM_VALUE.AXI_I2C_BASE PARAM_VALUE.AXI_I2C_BASE } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.AXI_I2C_BASE}] ${MODELPARAM_VALUE.AXI_I2C_BASE}
}

proc update_MODELPARAM_VALUE.SI_570_ADDR { MODELPARAM_VALUE.SI_570_ADDR PARAM_VALUE.SI_570_ADDR } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.SI_570_ADDR}] ${MODELPARAM_VALUE.SI_570_ADDR}
}

proc update_MODELPARAM_VALUE.I2C_SW_ADDR { MODELPARAM_VALUE.I2C_SW_ADDR PARAM_VALUE.I2C_SW_ADDR } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.I2C_SW_ADDR}] ${MODELPARAM_VALUE.I2C_SW_ADDR}
}

