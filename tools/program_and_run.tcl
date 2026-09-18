# Program the Zybo Z7-20 FPGA and run the bare-metal QR application.
#
# Usage:
#   xsct.bat tools/program_and_run.tcl <bitstream.bit> <application.elf>

if {$argc != 2} {
    puts stderr "Usage: xsct program_and_run.tcl <bitstream.bit> <application.elf>"
    exit 2
}

set bitstream [file normalize [lindex $argv 0]]
set application [file normalize [lindex $argv 1]]
set project_root [file dirname [file dirname [file normalize [info script]]]]
set hardware [file join $project_root hardware baseline qr_test_working_ver0.xsa]
set ps_init [file join [file dirname [file dirname $application]] _ide psinit ps7_init.tcl]

foreach required_file [list $bitstream $application $hardware $ps_init] {
    if {![file isfile $required_file]} {
        puts stderr "Required file not found: $required_file"
        exit 2
    }
}

# Start hw_server separately, then this connects to its standard local port.
if {[catch {connect -url TCP:127.0.0.1:3121} connect_error]} {
    puts stderr "Cannot connect to hw_server at TCP:127.0.0.1:3121"
    puts stderr "Start C:/Xilinx/Vivado/2024.2/bin/hw_server.bat, power the board, and check the JTAG cable."
    puts stderr $connect_error
    exit 1
}

jtag targets -open -filter {name == "arm_dap"}
targets -set -filter {name =~ "ARM Cortex-A9 MPCore #0"}
rst
puts "Programming FPGA with $bitstream"
fpga -file $bitstream
loadhw $hardware
source $ps_init
ps7_init
ps7_post_config
puts "Downloading $application"
dow $application
puts "Starting application. Check the board UART at 115200 baud."
con
