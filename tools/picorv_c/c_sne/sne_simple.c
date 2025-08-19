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

int main(int argc, char *argv[]) {
    // Parse tile ID
    int tidh = 0;
    if (argc > 1) tidh = atoi(argv[1]);


    uint32_t dest_spad1 = 1;
    uint32_t dest_spad2 = 8;
    uint32_t dest_sne = 9;

    dest_spad1 = dest_spad1 << 12;
    dest_spad2 = dest_spad2 << 12;
    dest_sne   = dest_sne << 12;

    mPut(0xCAFECAF1,dest_spad1);
    mPut(0xCAFECAF8,dest_spad2);
    mPut(0xCAFECAF9,dest_sne);
    return 0;
}