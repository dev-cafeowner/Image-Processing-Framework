# Read-only performance observation. Does not reset, halt, program, or write
# target memory/registers. Run with XSCT while the Stage 6 application runs.
connect -url TCP:127.0.0.1:3121
jtag targets -open -filter {name == "arm_dap"}
targets -set -filter {name == "APU"}
set project_root [file dirname [file dirname [file normalize [info script]]]]
loadhw [file join $project_root Vivado qr_probe qr_camera_fixed.xsa]
puts "TARGETS_BEGIN"
puts [targets]
puts "TARGETS_END"
foreach {label addr words} {
    PLL 0xF8000100 5
    ARM_CLOCK 0xF8000120 1
    FPGA0_CLOCK 0xF8000170 1
    CAMERA 0x40010000 4
    FRONTEND 0x40000000 8
    RUNTIME 0x43C20000 16
    IMAGE_DMA 0x40410030 7
} {
    puts "SNAPSHOT $label"
    if {[catch {mrd $addr $words} result]} {
        puts "READ_ERROR $result"
    } else {
        puts $result
    }
}
puts "TRACE_BEGIN ms runtime_status camera_control frontend_counts image_dma_status"
set started [clock milliseconds]
set previous ""
while {[expr {[clock milliseconds] - $started}] < 6500} {
    if {[catch {
        set status [lindex [mrd -value 0x43C20004 1] 0]
        set camera [lindex [mrd -value 0x40010000 1] 0]
        set counts [lindex [mrd -value 0x40000014 1] 0]
        set image_status [lindex [mrd -value 0x40410034 1] 0]
        set value [format "0x%08X 0x%08X 0x%08X 0x%08X" $status $camera $counts $image_status]
    } read_error]} {
        puts "READ_ERROR $read_error"
        break
    }
    if {$value ne $previous} {
        puts "TRACE [expr {[clock milliseconds] - $started}] $value"
        set previous $value
    }
    after 5
}
puts "TRACE_END"
disconnect
exit
