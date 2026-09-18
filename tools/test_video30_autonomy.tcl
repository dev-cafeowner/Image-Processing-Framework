# Diagnostic: stop only CPU0 for 15s, observe independent PL/VDMA, always resume.
# QR wall-clock timeout may expire during debugger halt; reload normal firmware
# after this experiment. Do not merge this interval into recognition statistics.
connect -url TCP:127.0.0.1:3121
jtag targets -open -filter {name == "arm_dap"}
targets -set -filter {name == "ARM Cortex-A9 MPCore #0"}
set root [file dirname [file dirname [file normalize [info script]]]]
loadhw [file join $root Vivado qr_video30_stage2 qr_video30_stage2.xsa]
proc read32 {a} {return [expr [mrd -value $a]]}
if {[read32 0x43c30000] != 0x50525631} {error "Not stage2 hardware"}
puts [format "CR mm2s=%08x s2mm=%08x" [read32 0x43000000] [read32 0x43000030]]
set buffers {}
for {set i 0} {$i < 4} {incr i} {
    set read_addr [read32 [expr {0x4300005c+4*$i}]]
    set write_addr [read32 [expr {0x430000ac+4*$i}]]
    if {$read_addr == 0 || $read_addr != $write_addr || $read_addr in $buffers} {error "Shared buffer table mismatch"}
    lappend buffers $read_addr
    puts [format "SHARED_BUFFER %d %08x" $i $read_addr]
}
set before_camera [read32 0x43c30010]
set before_scan [read32 0x43c30014]
set before_hud [read32 0x43c3000c]
set start [clock milliseconds]
set previous_reader -1
set changes 0
set collisions 0
set bad 0
stop
puts "CPU0_HALTED"
set outcome [catch {
    for {set i 0} {$i < 150} {incr i} {
        set ptr [read32 0x43000028]
        set reader [expr {($ptr >> 16) & 31}]
        set writer [expr {($ptr >> 24) & 31}]
        if {$reader == $writer} {incr collisions}
        if {$previous_reader >= 0 && $reader != $previous_reader} {incr changes}
        set previous_reader $reader
        puts [format "SAMPLE ms=%d reader=%d writer=%d camera=%d scan=%d" [expr {[clock milliseconds]-$start}] $reader $writer [read32 0x43c30010] [read32 0x43c30014]]
        after 100
    }
    set camera [expr {[read32 0x43c30010]-$before_camera}]
    set scan [expr {[read32 0x43c30014]-$before_scan}]
    set hud [expr {[read32 0x43c3000c]-$before_hud}]
    set sr [expr {[read32 0x43000004] | [read32 0x43000034]}]
    set elapsed [expr {[clock milliseconds]-$start}]
    puts [format "AUTONOMY elapsed_ms=%d camera_sof=%d scan_sof=%d reader_changes=%d overlap_samples=%d hud_commits=%d hud_age=%d status=%08x" $elapsed $camera $scan $changes $collisions $hud [read32 0x43c30030] $sr]
    # status error mask from xaxivdma_hw.h; frame-count interrupt alone is not error.
    if {$camera < 100 || $scan < 600 || $changes < 70 || $collisions != 0 || $hud > 1 || ($sr & 0x00000ff1) != 0} {set bad 1}
} message options]
con
puts "CPU0_RESUMED"
disconnect
if {$outcome} {return -options $options $message}
if {$bad} {error "Autonomy acceptance failed"}
puts "AUTONOMY_PASS (sampled buffer ownership, not proof against every possible tear)"
exit
