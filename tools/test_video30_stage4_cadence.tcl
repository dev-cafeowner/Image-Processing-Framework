# Read-only JTAG sampling, separate from the UART benchmark. Samples can miss
# transitions; this is not HDMI pin-level cadence or tearing verification.
set root [file dirname [file dirname [file normalize [info script]]]]
connect -url TCP:127.0.0.1:3121
jtag targets -open -filter {name == "arm_dap"}
targets -set -filter {name == "APU"}
loadhw [file join $root Vivado qr_video30_stage4 qr_video30_stage4.xsa]
proc read32 {a} {return [expr [mrd -value $a]]}
if {[read32 0x40010010]!=0x43414d33 || [read32 0x4001000c]!=0x00030000} {error "Not Stage4 hardware"}
if {[read32 0x40010034]!=3 || [read32 0x40010038]!=0} {error "Clock integrity failed"}
set before_cam [read32 0x43c30010]
set before_scan [read32 0x43c30014]
set before_ticks [read32 0x43c30034]
set start [clock milliseconds]
set prev_reader -1
set prev_ms $start
set changes 0
set overlaps 0
set max_gap 0
for {set i 0} {$i<1500} {incr i} {
    set ptr [read32 0x43000028]
    set now [clock milliseconds]
    set gap [expr {$now-$prev_ms}]
    if {$gap>$max_gap} {set max_gap $gap}
    set prev_ms $now
    set reader [expr {($ptr>>16)&31}]
    set writer [expr {($ptr>>24)&31}]
    if {$reader==$writer} {incr overlaps}
    if {$prev_reader>=0 && $reader!=$prev_reader} {incr changes}
    set prev_reader $reader
    puts [format "CADENCE_SAMPLE ms=%d read=%d write=%d" [expr {$now-$start}] $reader $writer]
    after 3
}
set elapsed [expr {([read32 0x43c30034]-$before_ticks)&0xffffffff}]
set cam [expr {[read32 0x43c30010]-$before_cam}]
set scan [expr {[read32 0x43c30014]-$before_scan}]
set sr [expr {[read32 0x43000004]|[read32 0x43000034]}]
set lost [read32 0x40010020]
set bad [read32 0x40010024]
set clock_status [read32 0x40010034]
set clock_losses [read32 0x40010038]
puts [format "CADENCE seconds=%.6f camera=%d scan=%d read_changes=%d sampled_updates_per_s=%.5f max_sample_gap_ms=%d overlap_samples=%d vdma_status=%08x lost_tokens=%d bad_lines=%d rx_status=%08x rx_losses=%d" [expr {$elapsed/62500000.0}] $cam $scan $changes [expr {$changes*62500000.0/$elapsed}] $max_gap $overlaps $sr $lost $bad $clock_status $clock_losses]
disconnect
if {$overlaps || ($sr&0x00000ff1) || $lost || $bad || $clock_status!=3 || $clock_losses} {error "Cadence/ownership diagnostic failed"}
puts "CADENCE_PASS (sampled, not a pin-level HDMI/tearing proof)"
exit
