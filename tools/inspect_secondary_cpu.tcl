connect -url TCP:127.0.0.1:3121
jtag targets -open -filter {name == "arm_dap"}
targets -set -filter {name =~ "ARM Cortex-A9 MPCore #1"}
stop
puts [rrd pc]
puts [rrd sp]
disconnect
exit
