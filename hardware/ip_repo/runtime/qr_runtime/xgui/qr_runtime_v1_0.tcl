# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "C_S00_AXI_DATA_WIDTH" -parent ${Page_0} -widget comboBox
  ipgui::add_param $IPINST -name "C_S00_AXI_ADDR_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "C_S00_AXI_BASEADDR" -parent ${Page_0}
  ipgui::add_param $IPINST -name "C_S00_AXI_HIGHADDR" -parent ${Page_0}


}

proc update_PARAM_VALUE.EVENT_FIFO_ADDR_WIDTH { PARAM_VALUE.EVENT_FIFO_ADDR_WIDTH } {
	# Procedure called to update EVENT_FIFO_ADDR_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.EVENT_FIFO_ADDR_WIDTH { PARAM_VALUE.EVENT_FIFO_ADDR_WIDTH } {
	# Procedure called to validate EVENT_FIFO_ADDR_WIDTH
	return true
}

proc update_PARAM_VALUE.EVENT_FIFO_DEPTH { PARAM_VALUE.EVENT_FIFO_DEPTH } {
	# Procedure called to update EVENT_FIFO_DEPTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.EVENT_FIFO_DEPTH { PARAM_VALUE.EVENT_FIFO_DEPTH } {
	# Procedure called to validate EVENT_FIFO_DEPTH
	return true
}

proc update_PARAM_VALUE.FRAME_TIMEOUT_W { PARAM_VALUE.FRAME_TIMEOUT_W } {
	# Procedure called to update FRAME_TIMEOUT_W when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.FRAME_TIMEOUT_W { PARAM_VALUE.FRAME_TIMEOUT_W } {
	# Procedure called to validate FRAME_TIMEOUT_W
	return true
}

proc update_PARAM_VALUE.MAX_RECORDS { PARAM_VALUE.MAX_RECORDS } {
	# Procedure called to update MAX_RECORDS when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.MAX_RECORDS { PARAM_VALUE.MAX_RECORDS } {
	# Procedure called to validate MAX_RECORDS
	return true
}

proc update_PARAM_VALUE.C_S00_AXI_DATA_WIDTH { PARAM_VALUE.C_S00_AXI_DATA_WIDTH } {
	# Procedure called to update C_S00_AXI_DATA_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.C_S00_AXI_DATA_WIDTH { PARAM_VALUE.C_S00_AXI_DATA_WIDTH } {
	# Procedure called to validate C_S00_AXI_DATA_WIDTH
	return true
}

proc update_PARAM_VALUE.C_S00_AXI_ADDR_WIDTH { PARAM_VALUE.C_S00_AXI_ADDR_WIDTH } {
	# Procedure called to update C_S00_AXI_ADDR_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.C_S00_AXI_ADDR_WIDTH { PARAM_VALUE.C_S00_AXI_ADDR_WIDTH } {
	# Procedure called to validate C_S00_AXI_ADDR_WIDTH
	return true
}

proc update_PARAM_VALUE.C_S00_AXI_BASEADDR { PARAM_VALUE.C_S00_AXI_BASEADDR } {
	# Procedure called to update C_S00_AXI_BASEADDR when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.C_S00_AXI_BASEADDR { PARAM_VALUE.C_S00_AXI_BASEADDR } {
	# Procedure called to validate C_S00_AXI_BASEADDR
	return true
}

proc update_PARAM_VALUE.C_S00_AXI_HIGHADDR { PARAM_VALUE.C_S00_AXI_HIGHADDR } {
	# Procedure called to update C_S00_AXI_HIGHADDR when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.C_S00_AXI_HIGHADDR { PARAM_VALUE.C_S00_AXI_HIGHADDR } {
	# Procedure called to validate C_S00_AXI_HIGHADDR
	return true
}


proc update_MODELPARAM_VALUE.C_S00_AXI_DATA_WIDTH { MODELPARAM_VALUE.C_S00_AXI_DATA_WIDTH PARAM_VALUE.C_S00_AXI_DATA_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.C_S00_AXI_DATA_WIDTH}] ${MODELPARAM_VALUE.C_S00_AXI_DATA_WIDTH}
}

proc update_MODELPARAM_VALUE.C_S00_AXI_ADDR_WIDTH { MODELPARAM_VALUE.C_S00_AXI_ADDR_WIDTH PARAM_VALUE.C_S00_AXI_ADDR_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.C_S00_AXI_ADDR_WIDTH}] ${MODELPARAM_VALUE.C_S00_AXI_ADDR_WIDTH}
}

proc update_MODELPARAM_VALUE.MAX_RECORDS { MODELPARAM_VALUE.MAX_RECORDS PARAM_VALUE.MAX_RECORDS } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.MAX_RECORDS}] ${MODELPARAM_VALUE.MAX_RECORDS}
}

proc update_MODELPARAM_VALUE.EVENT_FIFO_DEPTH { MODELPARAM_VALUE.EVENT_FIFO_DEPTH PARAM_VALUE.EVENT_FIFO_DEPTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.EVENT_FIFO_DEPTH}] ${MODELPARAM_VALUE.EVENT_FIFO_DEPTH}
}

proc update_MODELPARAM_VALUE.EVENT_FIFO_ADDR_WIDTH { MODELPARAM_VALUE.EVENT_FIFO_ADDR_WIDTH PARAM_VALUE.EVENT_FIFO_ADDR_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.EVENT_FIFO_ADDR_WIDTH}] ${MODELPARAM_VALUE.EVENT_FIFO_ADDR_WIDTH}
}

proc update_MODELPARAM_VALUE.FRAME_TIMEOUT_W { MODELPARAM_VALUE.FRAME_TIMEOUT_W PARAM_VALUE.FRAME_TIMEOUT_W } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.FRAME_TIMEOUT_W}] ${MODELPARAM_VALUE.FRAME_TIMEOUT_W}
}

