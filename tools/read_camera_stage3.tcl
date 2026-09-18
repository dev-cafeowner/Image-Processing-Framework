# Non-halting APU register inspection. No writes, reset or programming.
set root [file dirname [file dirname [file normalize [info script]]]]
connect -url TCP:127.0.0.1:3121
jtag targets -open -filter {name == "arm_dap"}
targets -set -filter {name == "APU"}
loadhw [file join $root Vivado qr_video30_stage3 qr_video30_stage3.xsa]
foreach {label addr words} {
    CAM3 0x40010000 13
    PREVIEW_ID_CTRL 0x43c30000 2
    PREVIEW_COUNTERS 0x43c30010 10
    VDMA_MM2S 0x43000000 2
    VDMA_S2MM 0x43000030 2
    IMAGE_DMA 0x40410030 7
    RUNTIME 0x43c20000 16
} {
    puts $label
    if {[catch {mrd $addr $words} value]} {puts "READ_ERROR $value"} else {puts $value}
}
disconnect
exit
