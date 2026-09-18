# Stub every XSCT hardware operation. This test never connects to a board.
set package [file normalize [lindex $argv 0]]
set reject [expr {$argc > 1 && [lindex $argv 1] eq "reject"}]
set commands {}
foreach command {connect jtag targets rst fpga loadhw dow con disconnect} {
    proc $command {args} [format {lappend ::commands [linsert $args 0 %s]} $command]
}
proc mrd {args} {
    if {$::reject} {return 0}
    set address [lindex $args end]
    foreach {a expected} $::release_abi_checks {
        if {$a eq $address} {return $expected}
    }
    error "Unexpected MMIO address $address"
}
rename source real_source
proc source {path} {
    if {[file tail $path] eq "ps7_init.tcl"} {
        proc ::ps7_init {} {lappend ::commands ps7_init}
        proc ::ps7_post_config {} {lappend ::commands ps7_post_config}
        return
    }
    uplevel 1 [list real_source $path]
}
rename exit real_exit
proc exit {args} {return}
set argc 0
set argv {}
set rc [catch {source [file join $package run.tcl]} message]
if {$reject} {
    if {!$rc || ![string match "Release ABI mismatch*" $message]} {error "ABI rejection was not enforced"}
    foreach c $commands {if {[lindex $c 0] in {dow con}} {error "Downloaded despite ABI rejection"}}
    puts "DRYRUN ABI_REJECTION PASS"
} else {
    if {$rc} {error $message}
    set names {}
    foreach c $commands {lappend names [lindex $c 0]}
    if {$names ne {connect jtag targets rst fpga loadhw ps7_init ps7_post_config dow con disconnect}} {
        error "Unexpected deployment ordering: $names"
    }
    puts "DRYRUN DEPLOY_ORDER PASS"
}
real_exit 0
