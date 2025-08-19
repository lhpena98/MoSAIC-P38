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

#define SNE_MEM_WRITE_BASE_OFFSET 0x40 // ADDED: Base for the new direct memory write path
#define SNE_CONFIG_ADDR_OFFSET  0x80
#define SNE_CONFIG_WDATA_OFFSET 0x84

// Constants from testbench
#define CLUSTERS 1
#define ENGINES 1

// For packet-based "mPut" access via NoC
#define NOC_CMD_MPUT 0x08000000

static inline void debug_out(uint32_t val) {
    *((volatile uint32_t*)DEBUG_OUTPUT_ADDR) = val;
}

// Helper function to calculate remote address for mPut/mGet
static inline uint32_t sne_remote_addr(uint32_t tile_id, uint32_t offset) {
    return (tile_id << 12) | offset;
}

// Simple delay function
static inline void delay_cycles(uint32_t cycles) {
    for (volatile uint32_t i = 0; i < cycles; i++) {
        // Simple delay loop
    }
}

static inline void write_sne_reg_mstore(uint32_t internal_sne_offset, uint32_t value) {
    // The full global address for the configuration address window
    uint32_t addr_window_full_addr = sne_remote_addr(SNE_TILE_ID, SNE_CONFIG_ADDR_OFFSET);
    // Let's debug the address we're writing to
    debug_out(addr_window_full_addr);
    qPut(9, internal_sne_offset);

    // The full global address for the configuration data window
    uint32_t data_window_full_addr = sne_remote_addr(SNE_TILE_ID, SNE_CONFIG_WDATA_OFFSET);
    // Let's debug the data we're writing
    debug_out(data_window_full_addr);
    qPut(9, value);
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

    for (int i = 0; i < 64; i++) {
        // Load 16 words into 512 bytes of TCDM memory
        mPut(test_data[i % 16], sne_remote_addr(SNE_TILE_ID, i * 8));
    }

    debug_out(0xDA7A0001);  // Data loading done
}

// --- CONFIGURATION VIA MAILBOX ---
// This function uses memory-mapped stores (qPut) to write to the SNE's control registers
// via the AXI mailbox interface.
static inline void write_sne_reg(uint32_t internal_sne_offset, uint32_t value) {
    // Step 1: Write the SNE's internal register address to the "address window".
    // The hardware latches this address.
    uint32_t addr_window_full_addr = SNE_TILE_BASE_ADDR + SNE_CONFIG_ADDR_OFFSET;
    qPut(9, internal_sne_offset);

    // Step 2: Write the desired data to the "data window".
    // This write triggers the hardware to generate the internal APB transaction.
    uint32_t data_window_full_addr = SNE_TILE_BASE_ADDR + SNE_CONFIG_WDATA_OFFSET;
    qPut(9, value);
}

void configure_sne() {
    debug_out(0xC0DEBE61); // "CODE BEGIN"
    
    // --- Test Sequence ---
    // This sequence mimics how you would configure the real SNE core.
    // Each call to write_sne_reg() will result in two AXI transactions
    // and one internal APB transaction.

    // Example 1: Configure SNE's "mode" register
    write_sne_reg(0x00000010, 0x1); // Write 1 to internal addr 0x10
    delay_cycles(10);

    // Example 2: Set a base address pointer
    write_sne_reg(0x00000020, 0x10000000); // Write 0x10000000 to internal addr 0x20
    delay_cycles(10);

    // Example 3: Set a data count
    write_sne_reg(0x00000024, 1024); // Write 1024 to internal addr 0x24
    delay_cycles(10);

    // Example 4: Trigger the "start" bit
    write_sne_reg(0x00000000, 0x1); // Write 1 to internal addr 0x0 (GO register)
    
    debug_out(0xC0DE0001); // "CODE END"
}

int main(int argc, char *argv[]) {
    // Parse tile ID
    int tidh = 0;
    if (argc > 1) tidh = atoi(argv[1]);
    uint32_t tidh_s = tidh << 8;

    // Debug markers
    uint32_t dbg_start = 0xBEEF0000 | tidh_s;
    uint32_t dbg_config_start = 0xBEEF0001 | tidh_s;
    uint32_t dbg_config_done = 0xC0DE0000 | tidh_s;
    uint32_t dbg_start_sequence = 0x57A50000 | tidh_s;
    uint32_t dbg_end = 0xDEAD0000 | tidh_s;

    // debug_out(dbg_start);

    // // Debug: Print the addresses we're using
    // debug_out(SNE_TILE_BASE_ADDR);  // Will show the full tile base address
    // debug_out(SNE_APB_BASE_ADDR);   // Will show the full APB base address

    // // Load test data first (like $readmemh in testbench)
    // load_sne_test_data();
    
    // delay_cycles(50);  // Wait for data to be ready (simulate testbench delay)

    // // Configure the SNE tile
    // debug_out(dbg_config_done);
    // // configure_sne();
    // // Wait
    // delay_cycles(1000);  // Wait for data to be ready (simulate testbench delay)
 
    return 0;
}