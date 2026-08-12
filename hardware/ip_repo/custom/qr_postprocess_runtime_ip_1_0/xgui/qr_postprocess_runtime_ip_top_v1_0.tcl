# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "ADDR_W" -parent ${Page_0}
  ipgui::add_param $IPINST -name "EVENT_FIFO_ADDR_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "EVENT_FIFO_DEPTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "FRAME_TIMEOUT_W" -parent ${Page_0}
  ipgui::add_param $IPINST -name "MAX_RECORDS" -parent ${Page_0}


}

proc update_PARAM_VALUE.ADDR_W { PARAM_VALUE.ADDR_W } {
	# Procedure called to update ADDR_W when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.ADDR_W { PARAM_VALUE.ADDR_W } {
	# Procedure called to validate ADDR_W
	return true
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

proc update_MODELPARAM_VALUE.ADDR_W { MODELPARAM_VALUE.ADDR_W PARAM_VALUE.ADDR_W } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.ADDR_W}] ${MODELPARAM_VALUE.ADDR_W}
}

