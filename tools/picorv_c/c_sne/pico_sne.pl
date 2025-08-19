#!/usr/bin/perl
# *************************************************************************
# 
# *** Copyright Notice ***
#
# P38 heterogeneous multi-tiled system with support for message queues 
# (MoSAIC) Copyright (c) 2024, The Regents of the University of California, 
# through Lawrence Berkeley National Laboratory (subject to receipt of
# any required approvals from the U.S. Dept. of Energy). All rights reserved.
# 
# If you have questions about your rights to use or distribute this software,
# please contact Berkeley Lab's Intellectual Property Office at
# IPO@lbl.gov.
#
# NOTICE.  This Software was developed under funding from the U.S. Department
# of Energy and the U.S. Government consequently retains certain rights.  As
# such, the U.S. Government has been granted for itself and others acting on
# its behalf a paid-up, nonexclusive, irrevocable, worldwide license in the
# Software to reproduce, distribute copies to the public, prepare derivative 
# works, and perform publicly and display publicly, and to permit others 
# to do so.
#
# *************************************************************************



##########################
# Do not modify
##########################
use lib "$ENV{PWD}";
use gen_hex;
use POSIX;
my %param;

##########################
# Modify
##########################

$param{'c_code'} = "sne_simple"; #- C code
$param{'keep'}   = 1;            
$param{'clean'}  = 1;

$param{'r'} = 2;
$param{'c'} = 2;

my @tile_array = (
    ['pico', 'spad'],
    ['spad', 'sne' ]
);

##########################
# Do not modify
##########################
$param{'tile_array'} = \@tile_array;
gen_code(\%param);




