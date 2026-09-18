# Incremental retry of OUR unqualified diagnostic project only. Never reset a
# qualified release or the normal QPP1 project; preserve failed timing evidence.
set root [file dirname [file dirname [file normalize [info script]]]]
set name qr_hdmi_cadence
set out [file join $root Vivado $name]
if {[file exists [file join $out ${name}.bit]]} {error "Qualified diagnostic exists; no overwrite"}
set previous [file join $out timing_summary.rpt]
set evidence [file join $root Docs performance hdmi_tag_initial_timing_rejected.rpt]
if {[file exists $previous] && ![file exists $evidence]} {file copy $previous $evidence}
open_project [file join $out ${name}.xpr]
set bd [get_files */qr_ip1_bd.bd]
open_bd_design $bd
update_compile_order -fileset sources_1
# Ports/parameters are unchanged. The OOC run scripts read the source RTL
# directly; resetting just these two runs rebuilds the changed datapath.
validate_bd_design
save_bd_design
write_bd_tcl -force [file join $out design.tcl]
generate_target all $bd
puts [exec pwsh.exe -NoProfile -File [file join $root tools verify_frame_pingpong.ps1] -BuildName $name]
foreach run {qr_ip1_bd_camera_tag_0_synth_1 qr_ip1_bd_scan_tag_0_synth_1 synth_1} {reset_run $run}
source [file join $root tools finish_frame_pingpong_build.tcl]
