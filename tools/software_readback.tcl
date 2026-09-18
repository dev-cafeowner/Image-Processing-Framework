set root [file dirname [file dirname [file normalize [info script]]]]
connect -url TCP:127.0.0.1:3121
jtag targets -open -filter {name == "arm_dap"}
targets -set -filter {name == "APU"}
loadhw [file join $root Vivado qr_probe qr_camera_fixed.xsa]
puts [targets]
foreach {label addr words} {
    I2C_CONTROL 0xe0004000 3
    I2C_STATUS 0xe0004010 1
    CLOCK 0xf8000170 4
    CAMERA 0x40010000 4
    VDMA 0x43000000 24
    RUNTIME 0x43c20000 16
} {
    puts $label
    puts [mrd $addr $words]
}
puts "TRACE ms camera_control snapshot_control vdma_park read_status write_status"
set start [clock milliseconds]
set previous ""
while {[clock milliseconds] - $start < 4500} {
    set park [mrd -value 0x43000028 1]
    if {$park ne $previous} {
        puts "[expr {[clock milliseconds] - $start}] [mrd -value 0x40010000 1] [mrd -value 0x43c20000 1] $park [mrd -value 0x43000004 1] [mrd -value 0x43000034 1]"
        set previous $park
    }
    after 20
}
disconnect
exit
