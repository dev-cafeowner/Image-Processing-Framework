set root [file dirname [file dirname [file normalize [info script]]]]
set out [file join $root Vivado qr_perf]
open_project [file join $out qr_perf.xpr]
open_run impl_1
report_bus_skew -file [file join $out bus_skew.rpt]
report_clocks -file [file join $out clocks.rpt]
report_cdc -details -file [file join $out cdc_details.rpt]
close_project
exit
