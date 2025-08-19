// This module wraps the SNE core logic, presenting a standard interface
// to the MoSAIC tile infrastructure (axi_control and tile_noc).

function automatic logic [31:0] correct_apb_addr(logic [31:0] addr);
    // Check if this is a streamer control register (0x2000-0x2FFF range)
    if ((addr & 32'hFF000) == 32'h2000) begin
        // Special handling for cfg_main_ctrl_i registers
        if ((addr & 32'h00FFC) == 32'h0000) begin  // Streamer 0 main control
            return 32'h2004;  // Redirect to Streamer 1's address
        end else if ((addr & 32'h00FFC) == 32'h0004) begin  // Streamer 1 main control
            return 32'h2000;  // Redirect to Streamer 0's address
        end
    end
    return addr;  // No correction needed
endfunction

module acc_sne #(
   parameter OFFSET_SZ         = 12,
   parameter XY_SZ             =  3,
   parameter BW                = 32,
   parameter BWB               = BW/8,
   parameter NOC_BUFFER_ADDR_W =  8,
   parameter STREAMERS          = 2
) (
  //---Clock and Reset---//
   input  logic       clk_ctrl,
   input  logic       clk_line,
   input  logic       clk_ctrl_rst_low,
   input  logic       clk_line_rst_low,
   input  logic       clk_ctrl_rst_high,
   input  logic       clk_line_rst_high,
   input  logic [(XY_SZ*2)-1:0] HsrcId,     //- Tile identification

   //---NOC interface ---//
   input  logic           stream_in_TVALID,
   input  logic  [BW-1:0] stream_in_TDATA,
   input  logic [BWB-1:0] stream_in_TKEEP,
   input  logic           stream_in_TLAST,
   output logic           stream_in_TREADY,
   input  logic           stream_out_TREADY,
   output logic           stream_out_TVALID,
   output logic  [BW-1:0] stream_out_TDATA,
   output logic [BWB-1:0] stream_out_TKEEP,
   output logic           stream_out_TLAST,
  //- AXI memory interface -//
   input  logic        mem_valid_axi,
   input  logic [31:0] mem_addr_axi,
   input  logic [31:0] mem_wdata_axi,
   input  logic        mem_wstrb_axi,
   output logic [31:0] mem_rdata_axi,
   input  logic  [7:0] rvControl,

   // Configuration Window Interface -//
   input  logic [31:0] config_addr_i,
   input  logic [31:0] config_wdata_i,
   input  logic        config_we_i,

   // TCDM port list
   output logic [STREAMERS-1:0]         tcdm_req_o,
   input  logic [STREAMERS-1:0]         tcdm_gnt_i,
   output logic [STREAMERS-1:0] [31:0]  tcdm_add_o,
   output logic [STREAMERS-1:0]         tcdm_wen_o,
   output logic [STREAMERS-1:0] [3:0]   tcdm_be_o,
   output logic [STREAMERS-1:0] [31:0]  tcdm_data_o,
   input  logic [STREAMERS-1:0] [31:0]  tcdm_r_data_i,
   input  logic [STREAMERS-1:0]         tcdm_r_valid_i
);

   // Internal stream, memory, and NOC decoder signals
   logic           stream_in_TVALID_int;
   logic  [BW-1:0] stream_in_TDATA_int;
   logic [BWB-1:0] stream_in_TKEEP_int;
   logic           stream_in_TLAST_int;
   logic           stream_in_TREADY_int;
   (*mark_debug = "true" *) logic [BW-1:0] mm_mem_rdata;
   (*mark_debug = "true" *) logic [BW-1:0] mm_mem_wdata;
   (*mark_debug = "true" *) logic [31:0] mm_mem_addr;
   (*mark_debug = "true" *) logic          mm_mem_wstrb;
   (*mark_debug = "true" *) logic          mm_mem_valid;
   logic           stream_out_TVALID_int;
   logic  [BW-1:0] stream_out_TDATA_int;
   logic [BWB-1:0] stream_out_TKEEP_int;
   logic           stream_out_TLAST_int;
   logic           stream_out_TREADY_int;
   logic        fifo_queue_en;
   logic [31:0] fifo_queue_addr;

   // SNE clock and reset mapping 
   logic sne_system_clk;
   logic sne_system_rst_n;
   logic sne_interco_clk;
   logic sne_interco_rst_n;
   logic sne_engine_clk;
   logic sne_engine_rst_n;
   assign sne_system_clk    = clk_ctrl;
   assign sne_system_rst_n  = ~clk_ctrl_rst_high;
   assign sne_interco_clk   = clk_ctrl;
   assign sne_interco_rst_n = ~clk_ctrl_rst_high;
   assign sne_engine_clk    = clk_line;
   assign sne_engine_rst_n  = ~clk_line_rst_high;

   // TCDM interface signals 
   logic [STREAMERS-1:0]        tcdm_req;
   logic [STREAMERS-1:0]        tcdm_gnt;
   logic [STREAMERS-1:0][31:0]  tcdm_add;
   logic [STREAMERS-1:0]        tcdm_wen;
   logic [STREAMERS-1:0][3:0]   tcdm_be;
   logic [STREAMERS-1:0][31:0]  tcdm_wdata;
   logic [STREAMERS-1:0][31:0]  tcdm_rdata;
   logic [STREAMERS-1:0]        tcdm_r_valid;

   // DEBUG SIGNALS 
   logic [31:0] sne_main_ctrl_reg;
   logic [31:0] sne_status_reg;
   logic        sne_processing_active;
   logic [31:0] output_write_count;
   logic [31:0] config_write_count;
   logic        sne_started;
   logic pending_read;
   logic [31:0] captured_read_data;
   logic read_data_valid;

   ////////////////////////////////////////////////////////////////
   // APB master FSM to convert memory signals to APB protocol
   ////////////////////////////////////////////////////////////////
   typedef enum logic [1:0] {IDLE, SETUP, ACCESS} apb_fsm_state_t;
   apb_fsm_state_t apb_state, apb_next_state;
   
   // APB interface signals
   logic        sne_apb_psel;
   logic        sne_apb_penable;
   logic        sne_apb_pwrite;
   logic [31:0] sne_apb_paddr;
   logic [31:0] sne_apb_pwdata;
   logic [31:0] sne_apb_prdata;
   logic        sne_apb_pready;
   logic        sne_apb_pslverr;

   // Latched transaction signals
   logic [31:0] latched_addr;
   logic [31:0] latched_wdata;
   logic        latched_is_write;
   logic        transaction_pending;

   logic [31:0] prev_addr;
   logic [31:0] prev_data;
   logic prev_is_write;
   logic new_transaction;

   // Latch a new transaction from the AXI control module
   always_ff @(posedge clk_ctrl or posedge clk_ctrl_rst_high) begin
      if (clk_ctrl_rst_high) begin
         transaction_pending <= 1'b0;
         prev_addr <= 32'hFFFFFFFF; // Invalid address to ensure first transaction is detected
         prev_data <= 32'h0;
         prev_is_write <= 1'b0;
      end else begin
         // Detect a new transaction when mem_valid_axi is high AND something changed
         new_transaction = mem_valid_axi && (
            (mem_addr_axi != prev_addr) ||
            (mem_wdata_axi != prev_data && mem_wstrb_axi) || // Only check data on writes
            (mem_wstrb_axi != prev_is_write)
         );
         
         // Latch a new transaction only when we detect a change and aren't busy
         if (new_transaction && !transaction_pending) begin
            transaction_pending <= 1'b1;
            latched_addr <= mem_addr_axi;
            latched_wdata <= mem_wdata_axi;
            latched_is_write <= mem_wstrb_axi;
            
            // Update previous values for next change detection
            prev_addr <= mem_addr_axi;
            prev_data <= mem_wdata_axi;
            prev_is_write <= mem_wstrb_axi;
            
            // $display("[%t] ACC_SNE: New transaction detected: addr=0x%08x, data=0x%08x, is_write=%0d",
            //          $time, mem_addr_axi, mem_wdata_axi, mem_wstrb_axi);
         end
         
         // Clear pending flag when transaction starts processing
         if (transaction_pending && apb_state == SETUP) begin
            transaction_pending <= 1'b0;
         end
      end
   end

   // APB Master FSM (Combinational Logic)
   always_comb begin
      // Default assignments
      apb_next_state = apb_state;
      sne_apb_psel   = 1'b0;
      sne_apb_penable= 1'b0;
      sne_apb_pwrite = 1'b0;
      sne_apb_paddr  = 32'b0;
      sne_apb_pwdata = 32'b0;
      mem_rdata_axi  = 32'b0; // Default read data output

      case (apb_state)
         IDLE: begin
            // If a transaction has been latched, start the APB sequence
            if (transaction_pending) begin
               apb_next_state = SETUP;
            end
         end

         SETUP: begin
            // Assert select and drive address/control
            // Apply address correction when accessing streamer registers
            logic [31:0] corrected_addr = correct_apb_addr(latched_addr);
            
            sne_apb_psel   = 1'b1;
            sne_apb_paddr  = corrected_addr;  // Use corrected address
            sne_apb_pwrite = latched_is_write;
            if (latched_is_write) begin
               sne_apb_pwdata = latched_wdata;
            end
            apb_next_state = ACCESS;
         end

         ACCESS: begin
            // Keep signals asserted and assert enable
            // Apply address correction when accessing streamer registers
            logic [31:0] corrected_addr = correct_apb_addr(latched_addr);
            
            sne_apb_psel   = 1'b1;
            sne_apb_penable= 1'b1;
            sne_apb_paddr  = corrected_addr;  // Use corrected address
            sne_apb_pwrite = latched_is_write;
            if (latched_is_write) begin
               sne_apb_pwdata = latched_wdata;
            end

            // Wait for the slave to be ready
            if (sne_apb_pready) begin
               // If it was a read, capture the data
               if (!latched_is_write) begin
                  mem_rdata_axi = sne_apb_prdata;
               end
               // Transaction is complete, return to IDLE
               apb_next_state = IDLE;
            end else begin
               // Stay in ACCESS state if slave is not ready
               apb_next_state = ACCESS;
            end
         end
      endcase
   end

   // APB Master FSM (Sequential Logic)
   always_ff @(posedge clk_ctrl or posedge clk_ctrl_rst_high) begin
      if (clk_ctrl_rst_high) begin
         apb_state <= IDLE;
      end else begin
         apb_state <= apb_next_state;
      end
   end

   // NOC Buffer for clock domain crossing
   noc_buffer_in#(
      .BW (BW),
      .ADDR_W (NOC_BUFFER_ADDR_W)
   ) noc_buffer(
      .clk_in            (clk_line),
      .clk_in_rst_high   (clk_line_rst_high),
      .clk_in_rst_low    (clk_line_rst_low),
      .clk_out           (clk_ctrl),
      .clk_out_rst_low   (clk_ctrl_rst_low),
      .stream_in_TVALID  (stream_in_TVALID),
      .stream_in_TDATA   (stream_in_TDATA),
      .stream_in_TKEEP   (stream_in_TKEEP),
      .stream_in_TLAST   (stream_in_TLAST),
      .stream_in_TREADY  (stream_in_TREADY),
      .stream_out_TVALID (stream_in_TVALID_int),
      .stream_out_TDATA  (stream_in_TDATA_int),
      .stream_out_TKEEP  (stream_in_TKEEP_int),
      .stream_out_TLAST  (stream_in_TLAST_int),
      .stream_out_TREADY (stream_in_TREADY_int)
   );

   // NOC decoder instance to handle responses
   noc_decoder #(
      .BW(BW),
      .BWB(BWB),
      .XY_SZ(XY_SZ)
   ) noc_decoder_inst (
      //- Clock and reset
      .clk_ctrl         (clk_ctrl),
      //.clk_ctrl_rst_low (clk_ctrl_rst_low && rvRstN), 
      .clk_ctrl_rst_low (clk_ctrl_rst_low), 
      .clk_line         (clk_line),
      .clk_line_rst_low (clk_line_rst_low), 
      //- Tile identification
      .HsrcId           (HsrcId),
      //- NOC interface
      //- Input Interface: Switch writing to the memory manager 
      .stream_in_TVALID  (stream_in_TVALID_int),
      .stream_in_TDATA   (stream_in_TDATA_int),
      .stream_in_TKEEP   (stream_in_TKEEP_int), 
      .stream_in_TLAST   (stream_in_TLAST_int),
      .stream_in_TREADY  (stream_in_TREADY_int),
      //- Output Interface: Switch reading from memory manager
      .stream_out_TREADY (stream_out_TREADY_int),
      .stream_out_TVALID (stream_out_TVALID_int),
      .stream_out_TDATA  (stream_out_TDATA_int),
      .stream_out_TKEEP  (stream_out_TKEEP_int),
      .stream_out_TLAST  (stream_out_TLAST_int),
      .unblock           (),
      .spy_idle          (1'b1),
      .pcpi_idle         (1'b1),
      .fifo_0A_en        (),
      .fifo_0A_addr      (),
      .mem_rdata_a       (mm_mem_rdata),
      .mem_addr_a        (mm_mem_addr),
      .mem_wdata_a       (mm_mem_wdata),
      .mem_wstrb_a       (mm_mem_wstrb),
      .mem_valid_a       (mm_mem_valid),
      .mem_rdata_rv      ()
   );
   
   // Track which address came from which streamer
   logic [STREAMERS-1:0][31:0] last_tcdm_addr;

   logic [STREAMERS-1:0][31:0] tcdm_rdata_proc;
   logic [STREAMERS-1:0]       tcdm_r_valid_proc;

   always_ff @(posedge sne_system_clk) begin
      // Track last address per streamer
      for (int i = 0; i < STREAMERS; i++) begin
         if (tcdm_req[i]) begin
               last_tcdm_addr[i] <= tcdm_add[i];
         end
      end
   end

   // Response routing for both streamers
   always_ff @(posedge clk_line) begin
       if (clk_line_rst_high) begin
           // Drive the intermediate signals, not the final output.
           tcdm_r_valid_proc <= '0;
           tcdm_rdata_proc <= '0;
       end else begin
           // Default: no response
           tcdm_r_valid_proc <= '0;
           
           // When mm_mem_valid is asserted (response from scratchpad via NoC)
           if (mm_mem_valid) begin
               // Match response to streamer using address pattern matching
               logic found_match = 0;
               for (int i = 0; i < STREAMERS; i++) begin
                   // Match response to request using word-aligned address (ignore lowest 2 bits)
                   if ((mm_mem_addr & 32'hFFFFFFFC) == (last_tcdm_addr[i] & 32'hFFFFFFFC)) begin
                       tcdm_r_valid_proc[i] <= 1'b1;
                       tcdm_rdata_proc[i] <= mm_mem_wdata;
                       found_match = 1;
                     //   $display("[%t] ACC_SNE: Matched NoC response to Streamer %0d, addr=0x%08x, data=0x%08x",
                     //            $time, i, mm_mem_addr, mm_mem_wdata);
                       break;
                   end
               end
               
               // Fallback if no match found
               if (!found_match) begin
                   // If no pattern match, use address bit 2 to determine streamer
                   // This is a better heuristic than bit 0 since we're working with word addresses
                   int fallback_streamer = (mm_mem_addr >> 2) & 1;
                   tcdm_r_valid_proc[fallback_streamer] <= 1'b1;
                   tcdm_rdata_proc[fallback_streamer] <= mm_mem_wdata;
                  //  $display("[%t] ACC_SNE: Fallback NoC response to Streamer %0d, addr=0x%08x, data=0x%08x",
                  //           $time, fallback_streamer, mm_mem_addr, mm_mem_wdata);
               end
           end
       end
   end
   
   // Assign processed read data and valid signals to TCDM interface
   assign tcdm_rdata = tcdm_rdata_proc;
   assign tcdm_r_valid = tcdm_r_valid_proc;

   // SNE Complex instantiation
   sne_complex i_sne_complex (
      .system_clk_i(sne_system_clk),
      .system_rst_ni(sne_system_rst_n),
      .sne_interco_clk_i(sne_interco_clk),
      .sne_interco_rst_ni(sne_interco_rst_n),
      .sne_engine_clk_i(sne_engine_clk),
      .sne_engine_rst_ni(sne_engine_rst_n),
      .interrupt_o(),
      .power_gate(1'b0),
      .power_sleep(1'b0),
      .evt_i(2'b00),
      // TCDM connections 
      .tcdm_req_o(tcdm_req),
      .tcdm_add_o(tcdm_add),
      .tcdm_wen_o(tcdm_wen),
      .tcdm_be_o(tcdm_be),
      .tcdm_data_o(tcdm_wdata),
      .tcdm_gnt_i(tcdm_gnt),
      .tcdm_r_data_i(tcdm_rdata),
      .tcdm_r_valid_i(tcdm_r_valid),
      // APB interface - DRIVEN BY OUR FSM
      .apb_slave_pwrite(sne_apb_pwrite),
      .apb_slave_psel(sne_apb_psel),
      .apb_slave_penable(sne_apb_penable),
      .apb_slave_paddr(sne_apb_paddr),
      .apb_slave_pwdata(sne_apb_pwdata),
      .apb_slave_prdata(sne_apb_prdata),
      .apb_slave_pready(sne_apb_pready),
      .apb_slave_pslverr(sne_apb_pslverr)
   );

   // TCDM port connections
   assign tcdm_req_o    = tcdm_req;
   assign tcdm_add_o    = tcdm_add;
   assign tcdm_wen_o    = tcdm_wen;
   assign tcdm_be_o     = tcdm_be;
   assign tcdm_data_o   = tcdm_wdata;

   assign tcdm_gnt = tcdm_gnt_i;
   
   // // Consolidated debug monitoring
   // always @(posedge sne_system_clk) begin
   //    // Monitor APB transactions
   //    if (sne_apb_psel && sne_apb_penable) begin
   //       if (sne_apb_pwrite) begin
   //          // Special handling for different register types
   //          case (sne_apb_paddr[15:12])
   //             4'h0: $display("[%t] SNE_TILE: SYSTEM CONFIG: addr=0x%h, data=0x%h", 
   //                         $time, sne_apb_paddr, sne_apb_pwdata);
   //             4'h1: begin 
   //                if ((sne_apb_paddr & 32'hFF00) == 32'h1000)
   //                   $display("[%t] SNE_TILE: CROSSBAR CONFIG: addr=0x%h, data=0x%h", 
   //                         $time, sne_apb_paddr, sne_apb_pwdata);
   //                else if ((sne_apb_paddr & 32'hFF00) == 32'h1500)
   //                   $display("[%t] SNE_TILE: BARRIER/SYNC CONFIG: addr=0x%h, data=0x%h", 
   //                         $time, sne_apb_paddr, sne_apb_pwdata);
   //                else
   //                   $display("[%t] SNE_TILE: BUS CONFIG: addr=0x%h, data=0x%h", 
   //                         $time, sne_apb_paddr, sne_apb_pwdata);
   //             end
   //             4'h2: begin
   //                $display("[%t] SNE_TILE: MAIN CONTROL: addr=0x%h, data=0x%h", 
   //                      $time, sne_apb_paddr, sne_apb_pwdata);
                  
   //                // Monitor main control register for operation mode
   //                if ((sne_apb_paddr & 32'hF000) == 32'h2000) begin
   //                   case (sne_apb_pwdata)
   //                      32'h07:  $display("[%t] SNE_TILE: *** INITIAL CONFIGURATION MODE ***", $time);
   //                      32'h04:  $display("[%t] SNE_TILE: *** RESET/PREPARE MODE ***", $time);
   //                      32'hE07: $display("[%t] SNE_TILE: *** START PROCESSING MODE ***", $time);
   //                      32'hCC7: $display("[%t] SNE_TILE: *** FC LAYER PROCESSING MODE ***", $time);
   //                      32'hC47: $display("[%t] SNE_TILE: *** FINAL PROCESSING MODE ***", $time);
   //                      default: $display("[%t] SNE_TILE: *** CUSTOM CONTROL: 0x%08x ***", $time, sne_apb_pwdata);
   //                   endcase
   //                end
   //             end
   //             4'h3: $display("[%t] SNE_TILE: STREAMER CONFIG: addr=0x%h, data=0x%h", 
   //                         $time, sne_apb_paddr, sne_apb_pwdata);
   //             4'h4: $display("[%t] SNE_TILE: ENGINE CONFIG: addr=0x%h, data=0x%h", 
   //                         $time, sne_apb_paddr, sne_apb_pwdata);
   //             default: $display("[%t] SNE_TILE: OTHER CONFIG: addr=0x%h, data=0x%h", 
   //                            $time, sne_apb_paddr, sne_apb_pwdata);
   //          endcase
   //       end else begin
   //          $display("[%t] SNE_TILE: APB READ: addr=0x%h, data=0x%h", 
   //                $time, sne_apb_paddr, sne_apb_prdata);
   //       end
   //    end
   // end

   // // Monitor TCDM transactions for both streamers
   // always @(posedge sne_system_clk) begin
   //     for (int i = 0; i < STREAMERS; i++) begin
   //         if (tcdm_req[i]) begin
   //             $display("[%t] SNE_TILE: TCDM REQ[%0d]: addr=0x%08x, wen=%0d, be=0x%h, wdata=0x%08x", 
   //                      $time, i, tcdm_add[i], tcdm_wen[i], tcdm_be[i], tcdm_wdata[i]);
   //         end
           
   //         if (tcdm_r_valid[i]) begin
   //             $display("[%t] SNE_TILE: TCDM RESP[%0d]: data=0x%08x", 
   //                      $time, i, tcdm_rdata[i]);
   //         end
   //     end
   // end

   // // Add after NoC reads to verify data is correct
   // always @(posedge clk_line) begin
   //   if (tcdm_r_valid_i[0] || tcdm_r_valid_i[1]) begin
   //     $display("[%t] TCDM DATA CHECK: streamer=%d, addr=0x%h, data=0x%h", 
   //              $time, 
   //              tcdm_r_valid_i[1] ? 1 : 0,
   //              last_tcdm_addr[tcdm_r_valid_i[1] ? 1 : 0], 
   //              tcdm_r_data_i[tcdm_r_valid_i[1] ? 1 : 0]);
   //   end
   // end

   
endmodule