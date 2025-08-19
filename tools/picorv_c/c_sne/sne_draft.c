#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "mq.h"
#include "mosaic_defines.h"
#include "remote_wr.h"
#include "wrapper_mq.h"

#define DEBUG_OUTPUT_ADDR (PICO0 + 0x1000) // Base address for debug output
#define SNE_TILE_ID 9 // Tile ID for SNE (1,1) in the MoSAIC architecture
// --- SNE Configuration ---
// Base address for the SNE tile (1,1) APB interface
#define SNE_TILE_BASE_ADDR SNE3
#define SNE_APB_BASE_ADDR (SNE_TILE_BASE_ADDR + 0x80)

// Register offsets from sne_complex_tb.sv and imported packages
#define ENGINE_CLOCK_CFG_PARAMETER_I_OFFSET   0x4000
#define ENGINE_CLOCK_CFG_CID_I_0_OFFSET       0x4010
#define ENGINE_CLOCK_CFG_SLICE_I_0_OFFSET     0x4020
#define ENGINE_CLOCK_CFG_ERROR_I_0_OFFSET     0x4030

// MISSING: Sequencer offsets from hal_sne_init_sequencer
#define ENGINE_CLOCK_CFG_ADDR_STEP_I_0_OFFSET  0x4040
#define ENGINE_CLOCK_CFG_ADDR_START_I_0_OFFSET 0x4050
#define ENGINE_CLOCK_CFG_ADDR_END_I_0_OFFSET   0x4060

// MISSING: Filter offsets from hal_sne_set_filter
#define ENGINE_CLOCK_CFG_FILTER_MAIN_I_0_OFFSET   0x4070
#define ENGINE_CLOCK_CFG_FILTER_LBOUND_I_0_OFFSET 0x4080
#define ENGINE_CLOCK_CFG_FILTER_UBOUND_I_0_OFFSET 0x4090

#define BUS_CLOCK_CFG_XBAR_STAGE_0_0_OFFSET   0x1000
#define BUS_CLOCK_CFG_XBAR_STAGE_0_1_OFFSET   0x1004
#define BUS_CLOCK_CFG_XBAR_STAGE_0_2_OFFSET   0x1008
#define BUS_CLOCK_CFG_XBAR_STAGE_0_3_OFFSET   0x100C
#define BUS_CLOCK_CFG_XBAR_STAGE_0_4_OFFSET   0x1010
#define BUS_CLOCK_CFG_XBAR_STAGE_0_5_OFFSET   0x1014
#define BUS_CLOCK_CFG_XBAR_STAGE_0_6_OFFSET   0x1018
#define BUS_CLOCK_CFG_XBAR_STAGE_0_7_OFFSET   0x101C

#define BUS_CLOCK_CFG_XBAR_STAGE_1_0_OFFSET   0x1080
#define BUS_CLOCK_CFG_XBAR_STAGE_1_1_OFFSET   0x1084
#define BUS_CLOCK_CFG_XBAR_STAGE_1_2_OFFSET   0x1088
#define BUS_CLOCK_CFG_XBAR_STAGE_1_3_OFFSET   0x108C
#define BUS_CLOCK_CFG_XBAR_STAGE_1_4_OFFSET   0x1090
#define BUS_CLOCK_CFG_XBAR_STAGE_1_5_OFFSET   0x1094

#define BUS_CLOCK_CFG_XBAR_BARRIER_I_OFFSET   0x1500
#define BUS_CLOCK_CFG_XBAR_SYNCH_I_OFFSET     0x1504
#define BUS_CLOCK_CFG_COMPLEX_I_OFFSET        0x1400

#define SYSTEM_CLOCK_CFG_MAIN_CTRL_I_0_OFFSET 0x0020
#define SYSTEM_CLOCK_CFG_TCDM_START_ADDR_I_0_OFFSET  0x0040
#define SYSTEM_CLOCK_CFG_TCDM_ADDR_STEP_I_0_OFFSET   0x0044
#define SYSTEM_CLOCK_CFG_TCDM_END_ADDR_I_0_OFFSET    0x0048
#define SYSTEM_CLOCK_CFG_TCDM_TRAN_SIZE_I_0_OFFSET   0x004C
#define SYSTEM_CLOCK_CFG_SRAM_START_ADDR_I_0_OFFSET  0x0060
#define SYSTEM_CLOCK_CFG_SRAM_ADDR_STEP_I_0_OFFSET   0x0064
#define SYSTEM_CLOCK_CFG_SRAM_END_ADDR_I_0_OFFSET    0x0068

#define SNE_MEM_WRITE_BASE_OFFSET 0x40 // ADDED: Base for the new direct memory write path
#define SNE_CONFIG_ADDR_OFFSET  0x80
#define SNE_CONFIG_WDATA_OFFSET 0x84

// Constants from testbench
#define CLUSTERS 1
#define ENGINES 1

static inline void debug_out(uint32_t val) {
    *((volatile uint32_t*)DEBUG_OUTPUT_ADDR) = val;
}

static inline uint32_t encode_sne_addr(uint32_t x, uint32_t y, uint32_t offset) {
    return (offset << 6) | ((y & 0x7) << 3) | ((x & 0x7) << 0);
}

// Helper function to calculate remote address for mPut/mGet
static inline uint32_t sne_remote_addr(uint32_t tile_id, uint32_t offset) {
    return (tile_id << 12) | offset;
}

// Read from SNE register
static inline uint32_t read_sne_reg(uint32_t reg_offset) {
    uint32_t addr = sne_remote_addr(SNE_TILE_ID, reg_offset);
    uint32_t value;
    mLoad(value, addr);
    return value;
}

// Simple delay function
static inline void delay_cycles(uint32_t cycles) {
    for (volatile uint32_t i = 0; i < cycles; i++) {
        // Simple delay loop
    }
}

// // FIXED: Implement hal_sne_set_filter equivalent
// void hal_sne_set_filter_c(int slice, int group, int left, int right, int filter, 
//                          int bottom, int top, int xoffset, int yoffset) {
//     debug_out(0xF1170000);  // "FILTER" configuration marker
    
//     uint32_t lbound = left | (bottom << 16);
//     uint32_t ubound = right | (top << 16);
//     uint32_t offsets = (xoffset << 1) | (yoffset << 4) | filter;
//     int address_offset = 4 * (slice * CLUSTERS + group);
    
//     write_sne_reg(ENGINE_CLOCK_CFG_FILTER_MAIN_I_0_OFFSET + address_offset, offsets);
//     write_sne_reg(ENGINE_CLOCK_CFG_FILTER_LBOUND_I_0_OFFSET + address_offset, lbound);
//     write_sne_reg(ENGINE_CLOCK_CFG_FILTER_UBOUND_I_0_OFFSET + address_offset, ubound);
    
//     debug_out(0xF1170001);  // Filter configuration done
// }

// // FIXED: Implement hal_sne_init_sequencer equivalent
// void hal_sne_init_sequencer_c(int slice, int saddr, int eaddr) {
//     debug_out(0x5EC00000);  // "SEQ" - Sequencer configuration marker
    
//     write_sne_reg(ENGINE_CLOCK_CFG_ADDR_STEP_I_0_OFFSET + slice * 4, 0x00000001);
//     write_sne_reg(ENGINE_CLOCK_CFG_ADDR_START_I_0_OFFSET + slice * 4, saddr);
//     write_sne_reg(ENGINE_CLOCK_CFG_ADDR_END_I_0_OFFSET + slice * 4, eaddr);
    
//     debug_out(0x5EC00001);  // Sequencer configuration done
// }

// // FIXED: Implement hal_sne_init_streamer equivalent
// void hal_sne_init_streamer_c(int slice, int streamer, int l2saddr, int l2step, 
//                             int l0saddr, int l0step, int transize) {
//     debug_out(0x57520000);  // "STR" - Streamer configuration marker
    
//     write_sne_reg(SYSTEM_CLOCK_CFG_MAIN_CTRL_I_0_OFFSET + streamer * 4, 0);
//     write_sne_reg(SYSTEM_CLOCK_CFG_TCDM_START_ADDR_I_0_OFFSET + streamer * 4, l2saddr);
//     write_sne_reg(SYSTEM_CLOCK_CFG_TCDM_ADDR_STEP_I_0_OFFSET + streamer * 4, l2step);
//     write_sne_reg(SYSTEM_CLOCK_CFG_TCDM_END_ADDR_I_0_OFFSET + streamer * 4, 0x00000000);
//     write_sne_reg(SYSTEM_CLOCK_CFG_TCDM_TRAN_SIZE_I_0_OFFSET + streamer * 4, transize);
//     write_sne_reg(SYSTEM_CLOCK_CFG_SRAM_START_ADDR_I_0_OFFSET + streamer * 4, l0saddr);
//     write_sne_reg(SYSTEM_CLOCK_CFG_SRAM_ADDR_STEP_I_0_OFFSET + streamer * 4, l0step);
//     write_sne_reg(SYSTEM_CLOCK_CFG_SRAM_END_ADDR_I_0_OFFSET + streamer * 4, 0x00000000);
    
//     debug_out(0x57520001);  // Streamer configuration done
// }

// // Configure SNE engines
// void configure_sne_engines() {
//     debug_out(0xE4610000);  // "ENG" - Engine configuration marker
    
//     // Configure engines as in the testbench
//     for (int i = 0; i < ENGINES; i++) {
//         // CID configuration: ((i*4+0)<<24)+((i*4+1)<<16)+((i*4+2)<<8)+((i*4+3)<<0)
//         uint32_t cid_value = ((i*4+0)<<24) + ((i*4+1)<<16) + ((i*4+2)<<8) + (i*4+3);
//         write_sne_reg(ENGINE_CLOCK_CFG_CID_I_0_OFFSET + 4*i, cid_value);
        
//         // Slice configuration: 0x0800 + layer (layer 0 for now)
//         write_sne_reg(ENGINE_CLOCK_CFG_SLICE_I_0_OFFSET + 4*i, 0x0800);
        
//         // Error configuration
//         write_sne_reg(ENGINE_CLOCK_CFG_ERROR_I_0_OFFSET + 4*i, 0x06);
//     }
    
//     debug_out(0xE4610001);  // Engine configuration done
// }

static inline uint32_t mosaic_addr(uint32_t x, uint32_t y, uint32_t offset) {
    return (offset & ~0x3F) | ((y & 0x7) << 3) | ((x & 0x7) << 0);
}


void read_sne_test_data() {
    debug_out(0xDA7A0010);  // "DATA READ" marker

    for (int i = 0; i < 16; i++) {
        uint32_t addr = sne_remote_addr(SNE_TILE_ID, i * 8);
        uint32_t data;
        mGet(addr, data);
        debug_out(0xDA7A0020 | (i & 0xF));      // Index marker
        debug_out(0xDA7A0030 | (data & 0xFFFF)); // Data value (lower 16 bits)
    }

    debug_out(0xDA7A0011);  // "DATA READ DONE" marker
}

static inline void write_sne_reg(uint32_t internal_sne_offset, uint32_t value) {
    // Step 1: Write the SNE's internal register address to the "address window" (at AXI offset 0x80)
    uint32_t addr_window_axi_addr = sne_remote_addr(SNE_TILE_ID, SNE_CONFIG_ADDR_OFFSET);
    mPut(internal_sne_offset, addr_window_axi_addr);

    debug_out(internal_sne_offset); // Debug output for register write
    debug_out(value); // Debug output for value being written
    // Step 2: Write the desired data to the "data window" (at AXI offset 0x84).
    // This is the write that triggers the hardware to generate the APB transaction.
    uint32_t data_window_axi_addr = sne_remote_addr(SNE_TILE_ID, SNE_CONFIG_WDATA_OFFSET);
    mPut(value, data_window_axi_addr);
    debug_out(data_window_axi_addr); // Debug output for data window address
    debug_out(value); // Debug output for value being written

}

// ADDED: New function to write directly to SNE TCDM using the new hardware path
static inline void write_sne_mem_direct(uint32_t tcdm_byte_addr, uint32_t value) {
    // Combine the direct memory path base (0x40) with the target TCDM address.
    // This single write is decoded by axi_control_sne as a direct memory access.
    uint32_t direct_mem_axi_addr = sne_remote_addr(SNE_TILE_ID, SNE_MEM_WRITE_BASE_OFFSET + tcdm_byte_addr);
    mPut(value, direct_mem_axi_addr);
    debug_out(direct_mem_axi_addr); // Debug output for direct write address
    debug_out(value);               // Debug output for value being written
}


// Load test data into SNE memory (simulate $readmemh from testbench)
void load_sne_test_data() {
    debug_out(0xDA7A0000);  // "DATA" - Data loading marker

    uint32_t test_data[] = {
        0x12345678, 0x9ABCDEF0, 0x11111111, 0x22222222,
        0x33333333, 0x44444444, 0x55555555, 0x66666666,
        0x77777777, 0x88888888, 0x99999999, 0xAAAAAAAA,
        0xBBBBBBBB, 0xCCCCCCCC, 0xDDDDDDDD, 0xEEEEEEEE
    };

    for (int i = 0; i < 16; i++) {
        // MODIFIED: Use the new direct memory write function
        // The address is i*8 because the SNE TCDM is 64-bit wide, but we write 32-bit words.
        // The hardware will handle the byte-to-word address translation.
        write_sne_mem_direct(i * 8, test_data[i]);
    }

    debug_out(0xDA7A0001);  // Data loading done
}

int main(int argc, char *argv[]) {
    // Parse tile ID
    int tidh = 0;
    if (argc > 1) tidh = atoi(argv[1]);
    uint32_t tidh_s = tidh << 8;

    // Debug markers
    uint32_t dbg_start = 0xBEEF0000 | tidh_s;
    uint32_t dbg_config_done = 0xC0DE0000 | tidh_s;
    uint32_t dbg_start_sequence = 0x57A50000 | tidh_s;
    uint32_t dbg_end = 0xDEAD0000 | tidh_s;

    debug_out(dbg_start);

    // Debug: Print the addresses we're using
    debug_out(SNE_TILE_BASE_ADDR);  // Will show the full tile base address
    debug_out(SNE_APB_BASE_ADDR);   // Will show the full APB base address

    // --- COMPLETE SNE CONFIGURATION SEQUENCE (FOLLOWING TESTBENCH EXACTLY) ---
    
    // Load test data first (like $readmemh in testbench)
    load_sne_test_data();
    
    delay_cycles(50);  // Wait for data to be ready (simulate testbench delay)

    // Wait
    delay_cycles(1000);  // Wait for data to be ready (simulate testbench delay)
    // // 1. Configure filters for each cluster (MISSING from your original!)
    // for (int i = 0; i < CLUSTERS; i++) {
    //     // Simplified filter config (you'd read from files in real testbench)
    //             uint8_t x0 = 0, y0 = 0, xc = 32, yc = 32;  // Example crop values
    //     uint8_t xo = 0, yo = 0;  // Example offset values
        
    //     for (int j = 0; j < ENGINES; j++) {
    //         if (j == 0) {
    //             hal_sne_set_filter_c(j, i, x0, xc-1, 1, y0, yc-1, xo, yo);
    //         } else {
    //             hal_sne_set_filter_c(j, i, x0, xc-1, 1, y0, yc-1, xo, yo);
    //         }
    //     }
    // }
    
    // // 2. Initialize sequencers (MISSING from your original!)
    // for (int i = 0; i < ENGINES; i++) {
    //     hal_sne_init_sequencer_c(i, 0, 63);
    // }
    
    // // 3. Configure engines
    // configure_sne_engines();
    
    // // 4. Engine parameter configuration
    // write_sne_reg(ENGINE_CLOCK_CFG_PARAMETER_I_OFFSET, 0x44024000);

    // // 5. Configure Crossbar Stage 0 (FIXED VALUES from testbench)
    // // XBAR_CONN(0,1,15,15,15,15) = (0 << 2) | (1 << 7) | (15 << 12) | (15 << 17) | (15 << 22) | (15 << 27)
    // write_sne_reg(BUS_CLOCK_CFG_XBAR_STAGE_0_0_OFFSET, 0x7bdef084);  // FIXED: Calculated XBAR_CONN(0,1,15,15,15,15)
    // // XBAR_CONN(15,15,15,15,15,15) = all 15s
    // write_sne_reg(BUS_CLOCK_CFG_XBAR_STAGE_0_1_OFFSET, 0x7bdef7bc);  // FIXED: Calculated XBAR_CONN(15,15,15,15,15,15)
    // write_sne_reg(BUS_CLOCK_CFG_XBAR_STAGE_0_2_OFFSET, 0x7bdef10c);  // From testbench
    // write_sne_reg(BUS_CLOCK_CFG_XBAR_STAGE_0_3_OFFSET, 0x214c7424);
    // write_sne_reg(BUS_CLOCK_CFG_XBAR_STAGE_0_4_OFFSET, 0x84653a54);
    // write_sne_reg(BUS_CLOCK_CFG_XBAR_STAGE_0_5_OFFSET, 0x7bdef7bc);
    // write_sne_reg(BUS_CLOCK_CFG_XBAR_STAGE_0_6_OFFSET, 0x7bdef7bc);
    // write_sne_reg(BUS_CLOCK_CFG_XBAR_STAGE_0_7_OFFSET, 0x7bdef7bc);

    // // 6. Configure Crossbar Stage 1
    // write_sne_reg(BUS_CLOCK_CFG_XBAR_STAGE_1_0_OFFSET, 0x7d800000);
    // write_sne_reg(BUS_CLOCK_CFG_XBAR_STAGE_1_1_OFFSET, 0x000007bc);
    // write_sne_reg(BUS_CLOCK_CFG_XBAR_STAGE_1_2_OFFSET, 0x7bdef844);
    // write_sne_reg(BUS_CLOCK_CFG_XBAR_STAGE_1_3_OFFSET, 0x94e957bc);
    // write_sne_reg(BUS_CLOCK_CFG_XBAR_STAGE_1_4_OFFSET, 0x7bdef7bc);
    // write_sne_reg(BUS_CLOCK_CFG_XBAR_STAGE_1_5_OFFSET, 0x7bdef7bc);

    // // 7. Configure Barrier and Sync
    // write_sne_reg(BUS_CLOCK_CFG_XBAR_BARRIER_I_OFFSET, 0x00001555);
    // write_sne_reg(BUS_CLOCK_CFG_XBAR_SYNCH_I_OFFSET, 0x00003FFF);

    // // 8. Configure Complex
    // write_sne_reg(BUS_CLOCK_CFG_COMPLEX_I_OFFSET, 0x4);

    // debug_out(dbg_config_done);

    // // --- EXACT START SEQUENCE FROM TESTBENCH ---
    // debug_out(dbg_start_sequence);
    
    // // STEP 1: Configure and start first streamer (like testbench)
    // hal_sne_init_streamer_c(0, 0, 0, 4, 0, 1, 321);
    // write_sne_reg(SYSTEM_CLOCK_CFG_MAIN_CTRL_I_0_OFFSET, 0x07);
    // debug_out(0x57A50001);  // First control sequence
    
    // // STEP 2: Configure second streamer
    // hal_sne_init_streamer_c(0, 1, 0x927C0, 4, 0, 1, 0xFFFF);
    // write_sne_reg(SYSTEM_CLOCK_CFG_MAIN_CTRL_I_0_OFFSET + 4, 0xE03);
    // debug_out(0x57A50002);  // Second control sequence
    
    // // Wait (like #1000us in testbench)
    // debug_out(0xFA170000);  // "WAIT" marker
    // delay_cycles(100000);   // Long delay for processing
    // debug_out(0xFA170001);  // Wait done
    
    // // STEP 3: Continue sequence (like testbench)
    // write_sne_reg(SYSTEM_CLOCK_CFG_MAIN_CTRL_I_0_OFFSET, 0x04);
    // hal_sne_init_streamer_c(0, 0, 322*4, 4, 0, 1, 3);
    // write_sne_reg(SYSTEM_CLOCK_CFG_MAIN_CTRL_I_0_OFFSET, 0xE07);
    // debug_out(0x57A50003);  // START PROCESSING!
    
    // // Wait for processing
    // delay_cycles(50000);
    
    // // STEP 4: Final sequence
    // write_sne_reg(SYSTEM_CLOCK_CFG_MAIN_CTRL_I_0_OFFSET, 0x04);
    // hal_sne_init_streamer_c(0, 0, 331*4, 4, 0, 1, 0xFFFF);
    // write_sne_reg(SYSTEM_CLOCK_CFG_MAIN_CTRL_I_0_OFFSET, 0xC47);
    // debug_out(0x57A50004);  // Final processing command
    
    // // Wait for final processing
    // delay_cycles(200000);   // Long wait like #20000us in testbench
    
    // // --- MONITOR FOR RESULTS ---
    // monitor_sne_output();
    
    // // --- COMPREHENSIVE MEMORY SCAN ---
    // debug_out(0x5CA40000);  // "SCAN" marker
    
    // // Scan the exact output region from testbench
    // uint32_t output_addr = 0x927C0;  // Exact address from testbench
    // uint32_t changes_found = 0;
    
    // for (int i = 0; i < 32; i++) {
    //     uint32_t data;
    //     mGet(data, output_addr + (i * 4));
    //     if (data != 0) {
    //         debug_out(0x5CA40010 | (data & 0xFFFF));
    //         changes_found++;
    //     }
    // }
    
    // debug_out(0x5CA40001 | (changes_found & 0xFF));
    
    // // Also scan SNE tile memory for any changes
    // uint32_t sne_mem_base = SNE_TILE_BASE_ADDR;
    // uint32_t tile_changes = 0;
    
    // for (int i = 16; i < 64; i++) {  // Skip our test data, check beyond
    //     uint32_t current_data;
    //     mGet(current_data, sne_mem_base + (i * 4));
        
    //     if (current_data != 0) {
    //         debug_out(0xDAD40010 | i);  // "DAD" - Data detected at position i
    //         debug_out(0xDAD40011 | (current_data & 0xFFFF));
    //         tile_changes++;
    //     }
    // }
    
    // debug_out(0xF1A10001 | (tile_changes & 0xFF));  // Total tile changes
    
    // // --- FINAL STATUS ---
    // debug_out(0x7E570000);  // "TEST" marker
    
    // // Test basic register connectivity
    // write_sne_reg(0x0000, 0x12345678);
    // uint32_t readback = read_sne_reg(0x0000);
    
    // if (readback == 0x12345678) {
    //     debug_out(0x7E570001);  // Test PASSED
    // } else {
    //     debug_out(0x7E570002);  // Test FAILED
    // }
    
    // // Check main control register
    // uint32_t main_ctrl_readback = read_sne_reg(SYSTEM_CLOCK_CFG_MAIN_CTRL_I_0_OFFSET);
    // debug_out(0x7E570003 | (main_ctrl_readback & 0xFFFF));
    
    // debug_out(dbg_end);
    return 0;
}