# Primary clock: 100 MHz
create_clock -name sys_clk -period 10.000 [get_ports clk]

# Illustrative values only; replace with actual interface timing

set_input_delay -clock sys_clk -max 2.0 \
    [get_ports {rst valid key[*]}]

set_input_delay -clock sys_clk -min 0.5 \
    [get_ports {rst valid key[*]}]

set_output_delay -clock sys_clk -max 2.0 \
    [get_ports {stop}]

set_output_delay -clock sys_clk -min 0.5 \
    [get_ports {stop}]