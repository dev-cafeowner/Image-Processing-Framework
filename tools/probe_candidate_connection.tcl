set url TCP:127.0.0.1:3121
if {$argc} {set url [lindex $argv 0]}
connect -url $url
puts "JTAG_BEGIN"
puts [jtag targets]
after 500
jtag targets -open -filter {name == "arm_dap"}
after 500
puts "CPU_BEGIN"
puts [targets]
disconnect
exit
