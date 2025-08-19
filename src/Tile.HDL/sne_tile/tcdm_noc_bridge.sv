module tcdm_noc_bridge #(
    parameter BW = 32,
    parameter BWB = BW/8,
    parameter XY_SZ = 3,
    parameter STREAMERS = 2,  // Number of SNE streamers
    parameter SCRATCHPAD_TILE_X = 3'h0,  // X-coordinate of scratchpad tile
    parameter SCRATCHPAD_TILE_Y = 3'h1,  // Y-coordinate of scratchpad tile
    parameter MAX_OUTSTANDING = 4,       // Max outstanding transactions per streamer
    parameter TIMEOUT_CYCLES = 1000      // Timeout counter for safety
) (
    // Clock and reset
    input  logic       clk_i,
    input  logic       rst_ni,
    input  logic [(XY_SZ*2)-1:0] HsrcId,  // Own tile ID

    // TCDM Interface (SNE side)
    input  logic [STREAMERS-1:0]         tcdm_req_i,
    output logic [STREAMERS-1:0]         tcdm_gnt_o,
    input  logic [STREAMERS-1:0] [31:0]  tcdm_add_i,
    input  logic [STREAMERS-1:0]         tcdm_wen_i,
    input  logic [STREAMERS-1:0] [3:0]   tcdm_be_i,
    input  logic [STREAMERS-1:0] [31:0]  tcdm_data_i,
    output logic [STREAMERS-1:0] [31:0]  tcdm_r_data_o,
    output logic [STREAMERS-1:0]         tcdm_r_valid_o,

    // NoC Interface
    output logic        stream_out_TVALID,
    output logic [BW-1:0] stream_out_TDATA,
    output logic [BWB-1:0] stream_out_TKEEP,
    output logic        stream_out_TLAST,
    input  logic        stream_out_TREADY,
    
    input  logic        stream_in_TVALID,
    input  logic [BW-1:0] stream_in_TDATA,
    input  logic [BWB-1:0] stream_in_TKEEP,
    input  logic        stream_in_TLAST,
    output logic        stream_in_TREADY
);

    // Replace the transaction tracking structure with this improved version
    typedef struct packed {
        logic [$clog2(STREAMERS)-1:0] streamer_id;  // Which streamer owns this transaction
        logic [31:0] addr;                         // Full address for better matching
        logic is_read;                             // Track if it's a read transaction
        logic valid;                               // Is this entry valid?
    } tx_record_t;
    
    // Use a dedicated record per transaction rather than a FIFO
    tx_record_t active_transactions [MAX_OUTSTANDING*STREAMERS];

    // Add a FIFO to track outstanding transactions
    tx_record_t tx_records_q [MAX_OUTSTANDING*STREAMERS];
    logic [$clog2(MAX_OUTSTANDING*STREAMERS)-1:0] tx_write_ptr_q, tx_write_ptr_d;
    logic [$clog2(MAX_OUTSTANDING*STREAMERS)-1:0] tx_read_ptr_q, tx_read_ptr_d;

    // Track last address accessed by each streamer for debug
    logic [STREAMERS-1:0][31:0] last_tcdm_addr;

    // States for the transaction state machine
    typedef enum logic [2:0] {
    IDLE,
    SEND_HEADER,
    SEND_DATA,
    WAIT_RESPONSE
    } state_t;

    // States for the RX state machine
    typedef enum logic [1:0] {
        RX_IDLE,
        RX_WAIT_DATA,
        RX_WAIT_LAST
    } rx_state_t;

    // State registers
    state_t tx_state_q, tx_state_d;
    rx_state_t rx_state_q, rx_state_d;
    
    // Currently serviced streamer
    logic [$clog2(STREAMERS)-1:0] active_streamer_q, active_streamer_d;
    
    // Transaction tracking
    logic [31:0] tx_addr_q, tx_addr_d;
    logic tx_write_q, tx_write_d;
    logic [3:0] tx_be_q, tx_be_d;
    logic [31:0] tx_data_q, tx_data_d;
    
    // Transaction ID tracking (to match responses with requests)
    logic [STREAMERS-1:0][$clog2(MAX_OUTSTANDING)-1:0] tx_id_q, tx_id_d;
    logic [$clog2(MAX_OUTSTANDING)-1:0] active_tx_id;
    
    // Response tracking
    logic [$clog2(STREAMERS)-1:0] rx_streamer_q, rx_streamer_d;
    logic [$clog2(MAX_OUTSTANDING)-1:0] rx_id_q, rx_id_d;
    logic [31:0] rx_data_q, rx_data_d;
    
    // Timeout counter for safety
    logic [15:0] timeout_counter_q, timeout_counter_d;
    logic timeout_occurred;
    logic [STREAMERS-1:0] timeout_req;
    
    // NoC packet construction constants
    localparam [2:0] MPUT = 3'd4;  // Write to remote memory
    localparam [2:0] MGET = 3'd5;  // Read from remote memory
    localparam [2:0] MDATA = 3'd2; // Response data
    
    // Round-robin arbiter for TCDM requests
    logic [STREAMERS-1:0] req_valid;
    logic [STREAMERS-1:0] req_grant;
    logic [STREAMERS-1:0] streamer_ready;
    logic [$clog2(STREAMERS)-1:0] selected_streamer;
    logic grant_valid;
    logic response_complete;
    
    // Track outstanding transactions per streamer
    logic [STREAMERS-1:0][$clog2(MAX_OUTSTANDING):0] outstanding_count_q, outstanding_count_d;
    logic [STREAMERS-1:0] inc_req, dec_req;
    // Fair round-robin arbiter with priority rotation
    logic [$clog2(STREAMERS)-1:0] priority_q, priority_d;
    

    // Variables for RX header processing
    logic [11:0] rx_addr;  // For storing extracted address from header
    logic found_match;     // Flag for transaction matching logic

    logic [STREAMERS-1:0] write_complete;  // Signal when write transaction completes
    logic [STREAMERS-1:0] read_complete;   // Signal when read transaction completes

    // Requests are valid if the streamer is requesting and has room for responses
    assign req_valid = tcdm_req_i & streamer_ready;
    
    // A streamer is ready if it has fewer than MAX_OUTSTANDING transactions
    genvar i;
    generate
        for (i = 0; i < STREAMERS; i++) begin : gen_streamer_ready
            assign streamer_ready[i] = (outstanding_count_q[i] < MAX_OUTSTANDING);
        end
    endgenerate
    
    // Fair round-robin arbitration
    always_comb begin
        selected_streamer = '0;
        grant_valid = 1'b0;
        
        // First try to grant to the highest priority
        for (int i = 0; i < STREAMERS; i++) begin
            automatic logic [$clog2(STREAMERS)-1:0] idx = (priority_q + i) % STREAMERS;
            if (req_valid[idx]) begin
                // Only grant if NoC is ready to accept new transactions
                if (tx_state_q == IDLE && stream_out_TREADY) begin
                    selected_streamer = idx;
                    grant_valid = 1'b1;
                    break;
                end
            end
        end
        
        // Add backpressure tracking
        for (int i = 0; i < STREAMERS; i++) begin
            if (outstanding_count_q[i] >= MAX_OUTSTANDING-1) begin
                // $display("[%t] TCDM_NOC_BRIDGE: Streamer %0d approaching backpressure limit (%0d/%0d)",
                //          $time, i, outstanding_count_q[i], MAX_OUTSTANDING);
            end
        end
    end
    
    // Grant generation logic - only grant when in IDLE state
    always_comb begin
        for (int i = 0; i < STREAMERS; i++) begin
            req_grant[i] = (tx_state_q == IDLE) && (selected_streamer == i) && grant_valid;
        end
    end
    
    // Grant signals to TCDM interface
    assign tcdm_gnt_o = req_grant;
    
    // Priority update for fair arbitration
    always_comb begin
        priority_d = priority_q;
        if (tx_state_q == IDLE && grant_valid) begin
            // Rotate priority for next cycle
            priority_d = (selected_streamer + 1) % STREAMERS;
        end
    end
    
    // NoC packet building - Header format for memory access
    logic [BW-1:0] tx_header;
    logic [BW-1:0] rx_header;
    logic [5:0] dest_tile_id;
    
    // Destination is the scratchpad tile
    assign dest_tile_id = {SCRATCHPAD_TILE_Y, SCRATCHPAD_TILE_X};
    
    // Create the header packet - add address translation ONLY for TCDM memory
    always_comb begin
        // Calculate translated address for TCDM memory access
        // Convert from byte-addressing to word-addressing
        logic [31:0] translated_addr;
        
        // Right shift by 2 to convert from byte to word addressing (divide by 4)
        // This converts addresses like 0x0, 0x4, 0x8 to 0x0, 0x1, 0x2
        translated_addr = {2'b00, tx_addr_q[31:2]};
        
        tx_header = {
            3'b0,                   // Reserved
            1'b0,                   // HL bit (short header)
            tx_write_q ? MPUT : MGET, // Instruction type
            1'b0,                   // PT bit
            HsrcId,                 // Source ID
            translated_addr[11:0],  // Use translated address (lowest 12 bits)
            dest_tile_id            // Destination tile
        };
        
        // Debug output
        // $display("[%t] TCDM_NOC_BRIDGE: Address translation: 0x%h -> 0x%h", 
        //          $time, tx_addr_q, translated_addr);
    end
    
    // Transaction state machine
    always_comb begin
        // Default: maintain state
        tx_state_d = tx_state_q;
        active_streamer_d = active_streamer_q;
        tx_addr_d = tx_addr_q;
        tx_write_d = tx_write_q;
        tx_be_d = tx_be_q;
        tx_data_d = tx_data_q;
        tx_id_d = tx_id_q;
        timeout_counter_d = timeout_counter_q;
        
        // Default: no NoC output
        stream_out_TVALID = 1'b0;
        stream_out_TDATA = '0;
        stream_out_TKEEP = '1;
        stream_out_TLAST = 1'b0;
        
        inc_req = '0;

        // Check for timeout
        timeout_occurred = 1'b0;
        if (tx_state_q != IDLE && timeout_counter_q == TIMEOUT_CYCLES-1) begin
            timeout_occurred = 1'b1;
            tx_state_d = IDLE;
            // Reduce outstanding counter for the active streamer
            if (timeout_occurred)
                timeout_req[active_streamer_q] = 1'b1;
            else
                timeout_req = '0;
        end else if (tx_state_q != IDLE) begin
            timeout_counter_d = timeout_counter_q + 1;
        end
        
        case (tx_state_q)
            // Add more detailed debug for both streamers in IDLE state
            IDLE: begin
                timeout_counter_d = '0;
                
                if (grant_valid) begin
                    // Find an available transaction slot
                    automatic int free_slot = -1;  // Add 'automatic' keyword here
                    for (int i = 0; i < MAX_OUTSTANDING*STREAMERS; i++) begin
                        if (!active_transactions[i].valid) begin
                            free_slot = i;
                            break;
                        end
                    end
                    
                    if (free_slot >= 0) begin
                        // Record transaction details
                        active_transactions[free_slot].streamer_id = selected_streamer;
                        active_transactions[free_slot].addr = tcdm_add_i[selected_streamer];
                        active_transactions[free_slot].is_read = tcdm_wen_i[selected_streamer]; // 1=read in TCDM
                        active_transactions[free_slot].valid = 1'b1;

                        // Track last address for debug
                        last_tcdm_addr[selected_streamer] = tcdm_add_i[selected_streamer];  // Add this line

                        // Start a new transaction
                        tx_state_d = SEND_HEADER;
                        active_streamer_d = selected_streamer;
                        tx_addr_d = tcdm_add_i[selected_streamer];
                        tx_write_d = ~tcdm_wen_i[selected_streamer]; // TCDM: 0=write, 1=read; NoC: opposite
                        tx_be_d = tcdm_be_i[selected_streamer];
                        tx_data_d = tcdm_data_i[selected_streamer];
                        
                        // Assign transaction ID and increment for next time
                        active_tx_id = tx_id_q[selected_streamer];
                        tx_id_d[selected_streamer] = (tx_id_q[selected_streamer] + 1) % MAX_OUTSTANDING;
                        
                        // Increment outstanding transaction counter
                        inc_req[selected_streamer] = 1'b1;
                        
                        $display("[%t] TCDM_NOC_BRIDGE: Recorded %s transaction for streamer %0d at addr 0x%h (slot %0d)",
                                $time, tcdm_wen_i[selected_streamer] ? "READ" : "WRITE", 
                                selected_streamer, tcdm_add_i[selected_streamer], free_slot);
                    end else begin
                        $display("[%t] TCDM_NOC_BRIDGE: ERROR - No free transaction slots!",
                                $time);
                    end
                end
            end
            
            SEND_HEADER: begin
                // Send header packet
                stream_out_TVALID = 1'b1;
                stream_out_TDATA = tx_header;
                stream_out_TLAST = 1'b0; // Always false for header packets
                
                if (stream_out_TREADY) begin
                    if (tx_write_q) begin
                        tx_state_d = SEND_DATA;
                    end else begin
                        // For reads, send a dummy data packet to indicate readiness with TLAST=1 like how it's done in the other AXI transactions
                        tx_state_d = SEND_DATA;
                        tx_data_d = 32'h0; // Dummy data for read
                    end
                end
            end
            
            // In the SEND_DATA state, add code to clear write transaction slots (around line 340)
            SEND_DATA: begin
                // Send data packet for write operations
                stream_out_TVALID = 1'b1;
                stream_out_TDATA = tx_data_q;
                stream_out_TLAST = 1'b1;
                
                if (tx_write_q) begin
                    // Find and invalidate the write transaction
                    for (int i = 0; i < MAX_OUTSTANDING*STREAMERS; i++) begin
                        if (active_transactions[i].valid && 
                            !active_transactions[i].is_read &&
                            active_transactions[i].streamer_id == active_streamer_q &&
                            active_transactions[i].addr == tx_addr_q) begin
                            
                            // Clear this slot
                            active_transactions[i].valid = 1'b0;
                            $display("[%t] TCDM_NOC_BRIDGE: Cleared write transaction slot %0d for streamer %0d", 
                                    $time, i, active_streamer_q);
                            break;
                        end
                    end
                    
                    // Set write_complete flag instead of directly driving dec_req
                    write_complete[active_streamer_q] = 1'b1;
                end
                    
                tx_state_d = IDLE;
                
            end

            WAIT_RESPONSE: begin
                // Wait for the response state machine to handle the response
                // The rx state machine will signal completion via the response_complete signal
                
                // Go back to idle when rx state machine signals completion for our transaction
                if (response_complete && rx_streamer_q == active_streamer_q) begin
                    tx_state_d = IDLE;
                end
            end
            
            default: tx_state_d = IDLE;
        endcase
        
        // If timeout occurred, go back to IDLE
        if (timeout_occurred) begin
            tx_state_d = IDLE;
            $display("[%t] TCDM_NOC_BRIDGE: ERROR - Transaction timeout for streamer %0d", 
                     $time, active_streamer_q);
        end
    end
    
    // RX state machine improved version
    always_comb begin
        // Default: maintain state
        rx_state_d = rx_state_q;
        rx_streamer_d = rx_streamer_q;
        rx_data_d = rx_data_q;
        
        // Default ready signal
        stream_in_TREADY = (rx_state_q == RX_IDLE || 
                       (rx_state_q == RX_WAIT_DATA && !stream_in_TVALID));
        
        // Default: no response, no completion signal
        for (int i = 0; i < STREAMERS; i++) begin
            tcdm_r_valid_o[i] = 1'b0;
            tcdm_r_data_o[i] = 32'h0;
        end
        response_complete = 1'b0;
        
        case (rx_state_q)
            RX_IDLE: begin
                // Capture header when valid
                if (stream_in_TVALID) begin
                    // Store the header
                    rx_header = stream_in_TDATA;
                    rx_state_d = RX_WAIT_DATA;
                        
                    // Extract full address (use all available bits)
                    rx_addr = rx_header[17:6];
                    
                    // Find the matching transaction with relaxed matching
                    found_match = 0;
                    
                    for (int i = 0; i < MAX_OUTSTANDING*STREAMERS; i++) begin
                        // First try exact address match
                        if (active_transactions[i].valid && 
                            active_transactions[i].is_read &&
                            (active_transactions[i].addr[13:2] == rx_addr)) begin
                            
                            rx_streamer_d = active_transactions[i].streamer_id;
                            found_match = 1;
                            active_transactions[i].valid = 0;
                            
                            $display("[%t] TCDM_NOC_BRIDGE: MATCH - Response for addr=0x%h routed to streamer %0d (exact match)",
                                    $time, rx_addr, active_transactions[i].streamer_id);
                            break;
                            end
                    end
                    
                    // If no exact match, try matching by streamer and oldest transaction
                    if (!found_match) begin
                        for (int s = 0; s < STREAMERS; s++) begin
                            // Find oldest valid read transaction for this streamer
                            for (int i = 0; i < MAX_OUTSTANDING*STREAMERS; i++) begin
                                if (active_transactions[i].valid && 
                                    active_transactions[i].is_read &&
                                    active_transactions[i].streamer_id == s) begin

                                    rx_streamer_d = s;
                                    found_match = 1;
                                    active_transactions[i].valid = 0;
                                    
                                    $display("[%t] TCDM_NOC_BRIDGE: MATCH - Response routed to streamer %0d (fallback match)",
                                            $time, s);
                                    break;
                                end
                            end
                            if (found_match) break;
                        end
                    end
                end
            end
            
            RX_WAIT_DATA: begin
                // Wait for the data packet
                if (stream_in_TVALID && stream_in_TLAST) begin
                    // Forward data ONLY to the correct streamer
                    tcdm_r_data_o[rx_streamer_q] = stream_in_TDATA;
                    tcdm_r_valid_o[rx_streamer_q] = 1'b1;
                    
                    // Signal completion
                    response_complete = 1'b1;
                    
                    // Return to IDLE for next transaction
                    rx_state_d = RX_IDLE;
                    
                    $display("[%t] TCDM_NOC_BRIDGE: Response data 0x%h delivered to streamer %0d",
                            $time, stream_in_TDATA, rx_streamer_q);
                end
            end
            
            default: rx_state_d = RX_IDLE;
        endcase
    end
    
    // Outstanding transaction counter management
    always_comb begin
        // Default: maintain counters
        outstanding_count_d = outstanding_count_q;
        
        // Initialize dec_req based on active transactions
        dec_req = '0;
        
        // Set dec_req for timeout cases
        for (int i = 0; i < STREAMERS; i++) begin
            if (timeout_req[i]) begin
                dec_req[i] = 1'b1;
            end
        end
        
        // Set dec_req for completed responses
        if (response_complete) begin
            dec_req[rx_streamer_q] = 1'b1;
        end
        
        // Process increment and decrement requests
        for (int i = 0; i < STREAMERS; i++) begin
            if (inc_req[i]) begin
                outstanding_count_d[i] = outstanding_count_q[i] + 1;
            end else if (dec_req[i] && outstanding_count_q[i] > 0) begin
                outstanding_count_d[i] = outstanding_count_q[i] - 1;
            end
        end
    end

        // State update
        always_ff @(posedge clk_i or negedge rst_ni) begin
            if (~rst_ni) begin
                // Reset all state registers
                tx_state_q <= IDLE;
                rx_state_q <= RX_IDLE;
                active_streamer_q <= '0;
                tx_addr_q <= '0;
                tx_write_q <= 1'b0;
                tx_be_q <= '0;
                tx_data_q <= '0;
                rx_streamer_q <= '0;
                rx_id_q <= '0;
                rx_data_q <= '0;
                timeout_counter_q <= '0;
                priority_q <= '0;
                timeout_req <= '0;
                
                // Reset transaction IDs and outstanding counters
                for (int i = 0; i < STREAMERS; i++) begin
                    tx_id_q[i] <= '0;
                    outstanding_count_q[i] <= '0;
                end
                
                // Initialize all transaction slots to invalid
                for (int i = 0; i < MAX_OUTSTANDING*STREAMERS; i++) begin
                    active_transactions[i].valid = 1'b0;
                end
            end else begin
            // Update all state registers
            tx_state_q <= tx_state_d;
            rx_state_q <= rx_state_d;
            active_streamer_q <= active_streamer_d;
            tx_addr_q <= tx_addr_d;
            tx_write_q <= tx_write_d;
            tx_be_q <= tx_be_d;
            tx_data_q <= tx_data_d;
            tx_id_q <= tx_id_d;
            rx_streamer_q <= rx_streamer_d;
            rx_id_q <= rx_id_d;
            rx_data_q <= rx_data_d;
            timeout_counter_q <= timeout_counter_d;
            priority_q <= priority_d;
            outstanding_count_q <= outstanding_count_d;
        end
    end

    // Debug monitor for transaction tracking
    always @(posedge clk_i) begin
      if (stream_in_TVALID && stream_in_TREADY) begin
        $display("[%t] TCDM_NOC_BRIDGE: Received NoC response: data=0x%08x", 
                 $time, stream_in_TDATA);
      end
      
      for (int i = 0; i < STREAMERS; i++) begin
        if (tcdm_r_valid_o[i]) begin
            $display("[%t] TCDM_NOC_BRIDGE: TRANSACTION COMPLETE - Streamer %0d, addr=0x%h, data=0x%h, outstanding=%0d", 
                    $time, i, last_tcdm_addr[i], tcdm_r_data_o[i], outstanding_count_q[i]-1);
        end
      end
    end
    
    // Add this monitor to help troubleshoot routing issues
    always @(posedge clk_i) begin
        // Track request signals from both streamers
        for (int i = 0; i < STREAMERS; i++) begin
            if (tcdm_req_i[i]) begin
                $display("[%t] TCDM_NOC_BRIDGE: Streamer %0d requesting %s to addr 0x%h",
                        $time, i, tcdm_wen_i[i] ? "READ" : "WRITE", tcdm_add_i[i]);
            end
        end
        
        // Monitor which responses are being received
        for (int i = 0; i < STREAMERS; i++) begin
            if (tcdm_r_valid_o[i]) begin
                $display("[%t] TCDM_NOC_BRIDGE: Streamer %0d received data 0x%h",
                        $time, i, tcdm_r_data_o[i]);
            end
        end
    end

    // Active transaction slot monitoring
    always_comb begin
        // Count active transaction slots
        int active_slots = 0;
        for (int i = 0; i < MAX_OUTSTANDING*STREAMERS; i++) begin
            if (active_transactions[i].valid) active_slots++;
        end
        
        // Warning if too many slots are in use
        if (active_slots > (MAX_OUTSTANDING*STREAMERS/2)) begin
            $display("[%t] TCDM_NOC_BRIDGE: Warning - %0d/%0d transaction slots in use",
                    $time, active_slots, MAX_OUTSTANDING*STREAMERS);
        end
    end

endmodule