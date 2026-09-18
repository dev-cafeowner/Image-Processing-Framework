# Read-only: do not halt/resume/reset the CPU or clear sticky error evidence.
connect -url TCP:127.0.0.1:3121
jtag targets -open -filter {name == "arm_dap"}
puts "TARGETS"
puts [targets]
disconnect
exit
