# Portable release asset launcher. RAM/JTAG ONLY: never writes flash or SD.
# Run through run.ps1 to verify all package hashes before touching hardware.
if {$argc != 0} {error "Usage: xsct run.tcl"}
set root [file dirname [file normalize [info script]]]
set app [file join $root runtime application.elf]
set bit [file join $root runtime system.bit]
set xsa [file join $root runtime hardware.xsa]
set psinit [file join $root runtime ps7_init.tcl]
foreach p [list $app $bit $xsa $psinit [file join $root runtime profile.tcl]] {
    if {![file isfile $p]} {error "Missing release payload: $p"}
}
source [file join $root runtime profile.tcl]
connect -url TCP:127.0.0.1:3121
jtag targets -open -filter {name == "arm_dap"}
targets -set -filter {name == "ARM Cortex-A9 MPCore #0"}
rst
fpga -file $bit
loadhw $xsa
source $psinit
ps7_init
ps7_post_config
foreach {address expected} $release_abi_checks {
    if {[expr [mrd -value $address]] != $expected} {
        error "Release ABI mismatch at $address (expected $expected)"
    }
}
dow $app
con
puts "Running release $release_tag; RAM/JTAG only"
disconnect
exit
