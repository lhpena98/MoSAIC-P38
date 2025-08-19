#!/usr/bin/perl

use lib "$ENV{PWD}";
use lib "$ENV{PWD}/../picorv_c/c_sne";
use gen_mosaic;
use gen_hex;
use POSIX;

my %param;

###########################################
# 1. Define New Accelerator
###########################################
# - Associate the name 'sne' with the Verilog module 'Tile_sne'
my %new_tile;
$new_tile{'sne'} = 'Tile_sne';
$param{'new_tile'} = \%new_tile;

# - Provide the path to the SNE accelerator's source files
$param{'sne_path'} = '/home/lpenatrevino/sne/rtl';
$param{'extra_verilog'} = [
    # Add any extra verilog files if needed, otherwise leave empty
    'sne/.bender/git/checkouts/common_cells-2cc0cf4395a52646/src'
];

###########################################
# 2. Define System Architecture
###########################################
# - Define a 2x2 tile grid
$param{'r'} = 2;
$param{'c'} = 2;
$param{'mem_sz'} = 65536;  # 64kB memory size

# - Specify the type of each tile in the grid (row by row)
#   (0,0): PicoRV32 processor to run our C code
#   (0,1): A scratchpad memory (unused in this test, but good practice)
#   (1,0): Another scratchpad
#   (1,1): Our SNE accelerator tile
my @tile_array = (
    ['pico', 'spad'],
    ['spad', 'sne' ]
);
$param{'tile_array'} = \@tile_array;

###########################################
# 3. Specify Firmware
###########################################
# - Set the path to the directory containing the firmware hex files.
# $param{'firmware_path'} = "$ENV{PWD}/../picorv_c/c_sne";
$path = "$ENV{PWD}";
$fw_path = "$path/../picorv_c/c_sne";
$param{'firmware_path'} = $fw_path;
$c_file = "sne_complex_tb";  # C code to run on PicoRV32
# - Tell MoSAIC which hex file to load onto which PicoRV32 tile.
#   The order corresponds to the 'pico' tiles found in the tile_array.
#   Here, we only have one pico at (0,0).
# Update the pico_program array to match the new addressing:
my @pico_program = (
    "${c_file}32_0.hex",  # (0,0) - ID 0
    'l2_stim_sne.hex',    # (0,1) - ID 1 (spad)
    '',                   # (1,0) - ID 2 (spad)  
    'fd_APB.hex'          # (1,1) - ID 3 (sne)
);
$param{'pico_program'} = \@pico_program;

###########################################
# 4. Simulation Settings
###########################################
# - Disable AXI writes from testbench file, as firmware will handle it.
$param{'axi_writes'} = 0;

# - This loads the memory with the initial values from the hex file instead of the testbench. (Like a ROM)
$param{'init_mem_tile_axi'} = 1;

# - Use an empty stimulus file since the C code provides the stimulus
$param{'packet_file'}  = "Packet_in_empty.axi";

# - (Optional) Use Vivado instead of Icarus.
$param{'vivado'} = 1;
$param{'vivado_project'} = 1; # Set to 1 to create a Vivado project, note: if already exists, it will overwrite it.
# - Set to 1 to automatically run the simulation after generation
$param{'run_sim'} = 1;

# Increase simulation time to ensure completion
$param{'sim_loop'} = 5000;  # Adjust based on processing time needed

#- Generate hex code
chdir $fw_path or die "$!. $fw_path\n";
%param_h;
$param_h{'c_code'} = $c_file;
$param_h{'r'}   = $param{'r'};
$param_h{'c'}   = $param{'c'};
$param_h{'keep'}  = 1;
$param_h{'clean'} = 1;
$param_h{'tile_array'} = \@tile_array;
gen_code(\%param_h);
chdir $path or die "$!. $path\n";
#############################
#- Generate: Do not modify  
gen_all(\%param);