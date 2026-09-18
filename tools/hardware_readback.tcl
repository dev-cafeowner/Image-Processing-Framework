set root [file dirname [file dirname [file normalize [info script]]]]
connect -url TCP:127.0.0.1:3121
jtag targets -open -filter {name == "arm_dap"}
targets -set -filter {name == "APU"}
loadhw [file join $root Vivado qr_perf qr_perf.xsa]
foreach {label addr words} {
    CLOCK 0xf8000170 1
    CAMERA 0x40010000 4
    FRONTEND 0x40000000 8
    IMAGE_DMA 0x40410030 3
    VDMA_READ 0x43000000 2
    VDMA_WRITE 0x43000030 2
    RUNTIME 0x43c20000 16
} {puts "$label [mrd $addr $words]"}
disconnect
exit
