## ============================================================================
## Zybo Z7-20 SoC QR Project
## OV7670 Camera + HDMI TX
##
## Top  : system_wrapper
## Part : xc7z020clg400-1
##
## Main PL clocks
##   clk_fpga_0 = 62.5 MHz, period 16.000 ns
##   clk_fpga_1 = 100  MHz, period 10.000 ns
##
## This XDC must be registered with:
##   USED_IN_SYNTHESIS      = true
##   USED_IN_IMPLEMENTATION = true
##   PROCESSING_ORDER       = LATE
##
## The Zynq PS clock and DDR/FIXED_IO pins are configured by the
## Processing System IP and are not assigned here.
## ============================================================================


## ============================================================================
## 1. OV7670 Parallel Data Bus
##
## Camera wiring
##
##   JB1  = D1       JB7  = D0
##   JB2  = D3       JB8  = D2
##   JB3  = D5       JB9  = D4
##   JB4  = D7       JB10 = D6
## ============================================================================

## JB7 = OV7670 D0
set_property -dict { \
    PACKAGE_PIN Y7 \
    IOSTANDARD LVCMOS33 \
} [get_ports {cam_data_0[0]}]

## JB1 = OV7670 D1
set_property -dict { \
    PACKAGE_PIN V8 \
    IOSTANDARD LVCMOS33 \
} [get_ports {cam_data_0[1]}]

## JB8 = OV7670 D2
set_property -dict { \
    PACKAGE_PIN Y6 \
    IOSTANDARD LVCMOS33 \
} [get_ports {cam_data_0[2]}]

## JB2 = OV7670 D3
set_property -dict { \
    PACKAGE_PIN W8 \
    IOSTANDARD LVCMOS33 \
} [get_ports {cam_data_0[3]}]

## JB9 = OV7670 D4
set_property -dict { \
    PACKAGE_PIN V6 \
    IOSTANDARD LVCMOS33 \
} [get_ports {cam_data_0[4]}]

## JB3 = OV7670 D5
set_property -dict { \
    PACKAGE_PIN U7 \
    IOSTANDARD LVCMOS33 \
} [get_ports {cam_data_0[5]}]

## JB10 = OV7670 D6
set_property -dict { \
    PACKAGE_PIN W6 \
    IOSTANDARD LVCMOS33 \
} [get_ports {cam_data_0[6]}]

## JB4 = OV7670 D7
set_property -dict { \
    PACKAGE_PIN V7 \
    IOSTANDARD LVCMOS33 \
} [get_ports {cam_data_0[7]}]


## ============================================================================
## 2. OV7670 Returned Pixel Clock
##
## JD7 = U14
## U14 is an SRCC-capable clock input.
##
## Current timing model
##   Maximum PCLK frequency = 25 MHz
##   PCLK period            = 40 ns
## ============================================================================

set_property -dict { \
    PACKAGE_PIN U14 \
    IOSTANDARD LVCMOS33 \
} [get_ports {cam_pclk_0}]

create_clock \
    -name cam_pclk_pin \
    -period 40.000 \
    -waveform {0.000 20.000} \
    [get_ports {cam_pclk_0}]


## ============================================================================
## 3. OV7670 Frame-Control Inputs
## ============================================================================

## JC2 = OV7670 VSYNC
set_property -dict { \
    PACKAGE_PIN W15 \
    IOSTANDARD LVCMOS33 \
} [get_ports {cam_vsync_0}]

## JC3 = OV7670 HREF
set_property -dict { \
    PACKAGE_PIN T11 \
    IOSTANDARD LVCMOS33 \
} [get_ports {cam_href_0}]


## ============================================================================
## 4. OV7670 Source-Synchronous Input Timing (MMCM +90 degree capture)
##
## Camera outputs are modeled relative to the falling edge of PCLK.
##
## External arrival-time model
##   Minimum input delay = -2 ns (assumed cable/board skew budget)
##   Maximum input delay = 7 ns (datasheet 5 ns + assumed 2 ns skew)
##
## These constraints do not physically delay the signals. They describe
## the external camera-to-FPGA timing for static timing analysis.
## ============================================================================

set_input_delay \
    -clock [get_clocks {cam_pclk_pin}] \
    -clock_fall \
    -min -2.000 \
    [get_ports {
        cam_data_0[0]
        cam_data_0[1]
        cam_data_0[2]
        cam_data_0[3]
        cam_data_0[4]
        cam_data_0[5]
        cam_data_0[6]
        cam_data_0[7]
        cam_href_0
        cam_vsync_0
    }]

set_input_delay \
    -clock [get_clocks {cam_pclk_pin}] \
    -clock_fall \
    -max 7.000 \
    [get_ports {
        cam_data_0[0]
        cam_data_0[1]
        cam_data_0[2]
        cam_data_0[3]
        cam_data_0[4]
        cam_data_0[5]
        cam_data_0[6]
        cam_data_0[7]
        cam_href_0
        cam_vsync_0
    }]


## ============================================================================
## 5. OV7670 Master Clock Output
##
## JC4 = OV7670 XCLK
##
## Current RTL clock structure
##
##   clk_fpga_1 = 100 MHz -> MMCM 600 MHz VCO /25 -> ODDR 24 MHz
## Generated-clock period = 41.6667 ns
## ============================================================================

set_property -dict { \
    PACKAGE_PIN T10 \
    IOSTANDARD LVCMOS33 \
    DRIVE 8 \
    SLEW FAST \
} [get_ports {cam_xclk_0}]

create_generated_clock \
    -name cam_xclk_out \
    -source [get_pins {
        qr_ip1_bd_i/ov7670_axis_0/inst/clock_source/forward_clock/C
    }] \
    -divide_by 1 \
    [get_ports {cam_xclk_0}]


## ============================================================================
## 6. OV7670 SCCB
##
## PS I2C0 through EMIO
##
##   JC9  = SIOC / SCL
##   JC10 = SIOD / SDA
## ============================================================================

## JC9 = OV7670 SIOC / SCL
set_property -dict { \
    PACKAGE_PIN T12 \
    IOSTANDARD LVCMOS33 \
    PULLUP TRUE \
} [get_ports {IIC_0_0_scl_io}]

## JC10 = OV7670 SIOD / SDA
set_property -dict { \
    PACKAGE_PIN U12 \
    IOSTANDARD LVCMOS33 \
    PULLUP TRUE \
} [get_ports {IIC_0_0_sda_io}]


## ============================================================================
## 7. Camera PCLK Domain <-> Main PL Clock Domain CDC
##
## cam_pclk_pin is the returned clock from the external OV7670.
## clk_fpga_0 is the 62.5 MHz Zynq PS FCLK0.
##
## These clocks are treated as asynchronous because the returned camera
## clock phase is not modeled as having a fixed deterministic relationship
## with clk_fpga_0.
##
## RTL must contain the appropriate CDC synchronizers, asynchronous FIFO,
## or dual-clock buffering.
## ============================================================================

set_clock_groups \
    -name async_cam_pclk_clk_fpga_0 \
    -asynchronous \
    -group [get_clocks -include_generated_clocks {cam_pclk_pin}] \
    -group [get_clocks {clk_fpga_0}]


## ============================================================================
## 8. HDMI TX
##
## Top-level ports
##
##   hdmi_out_clk_p
##   hdmi_out_clk_n
##   hdmi_out_data_p[2:0]
##   hdmi_out_data_n[2:0]
##
## TMDS serialization and timing are handled by the rgb2dvi and HDMI clock
## generation IP. No arbitrary set_output_delay or false-path constraint
## is added to these serialized output ports.
## ============================================================================

## HDMI TX Clock P
set_property -dict { \
    PACKAGE_PIN H16 \
    IOSTANDARD TMDS_33 \
} [get_ports {hdmi_out_clk_p}]

## HDMI TX Clock N
set_property -dict { \
    PACKAGE_PIN H17 \
    IOSTANDARD TMDS_33 \
} [get_ports {hdmi_out_clk_n}]


## HDMI TX Data Channel 0 P
set_property -dict { \
    PACKAGE_PIN D19 \
    IOSTANDARD TMDS_33 \
} [get_ports {hdmi_out_data_p[0]}]

## HDMI TX Data Channel 0 N
set_property -dict { \
    PACKAGE_PIN D20 \
    IOSTANDARD TMDS_33 \
} [get_ports {hdmi_out_data_n[0]}]


## HDMI TX Data Channel 1 P
set_property -dict { \
    PACKAGE_PIN C20 \
    IOSTANDARD TMDS_33 \
} [get_ports {hdmi_out_data_p[1]}]

## HDMI TX Data Channel 1 N
set_property -dict { \
    PACKAGE_PIN B20 \
    IOSTANDARD TMDS_33 \
} [get_ports {hdmi_out_data_n[1]}]


## HDMI TX Data Channel 2 P
set_property -dict { \
    PACKAGE_PIN B19 \
    IOSTANDARD TMDS_33 \
} [get_ports {hdmi_out_data_p[2]}]

## HDMI TX Data Channel 2 N
set_property -dict { \
    PACKAGE_PIN A20 \
    IOSTANDARD TMDS_33 \
} [get_ports {hdmi_out_data_n[2]}]
