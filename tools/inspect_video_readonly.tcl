# Video bottleneck observation only: no reset/halt/program/mwr/I2C transactions. AXI-Lite debug
# reads can perturb bus traffic, so this is a coarse trace, not cycle profiling.
set root [file dirname [file dirname [file normalize [info script]]]]
connect -url TCP:127.0.0.1:3121
jtag targets -open -filter {name == "arm_dap"}
targets -set -filter {name == "APU"}
loadhw [file join $root Vivado qr_perf qr_perf.xsa]
puts [targets]
foreach {label addr count} {
    CLOCKS 0xf8000100 9
    FCLK0 0xf8000170 1
    CAMERA 0x40010000 4
    VDMA_READ 0x43000000 2
    VDMA_WRITE 0x43000030 2
    DYNCLK 0x43c00000 10
    VTC_GENERATOR 0x43c10060 10
} {puts "$label [mrd $addr $count]"}
puts "TRACE_CSV ms_begin,ms_end,ctrl,status,candidates,error,active_id,image_id,skipped,fe_status,fe_count,vdma_park"
set started [clock milliseconds]
while {[clock milliseconds] - $started < 6000} {
    set begin [expr {[clock milliseconds] - $started}]
    set runtime [mrd -value 0x43c20000 16]
    set frontend [mrd -value 0x40000010 2]
    set park [lindex [mrd -value 0x43000028 1] 0]
    set end [expr {[clock milliseconds] - $started}]
    puts [format "TRACE,%d,%d,%08X,%08X,%d,%08X,%d,%d,%d,%08X,%08X,%08X" \
        $begin $end [lindex $runtime 0] [lindex $runtime 1] \
        [lindex $runtime 4] [lindex $runtime 5] [lindex $runtime 13] \
        [lindex $runtime 15] [lindex $runtime 14] \
        [lindex $frontend 0] [lindex $frontend 1] $park]
    after 2
}
puts "TRACE_END"
disconnect
exit
