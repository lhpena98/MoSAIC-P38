////////////////////////////////////////////////
// Author      : Luis Humberto Pena Trevino
// Date        : July 16, 2025
// Description : SNE Tile for MoSAIC
// File        : Tile_sne.sv
////////////////////////////////////////////////

`timescale 1 ps / 1 ps

// Include the AXI definitions required by axi_control_sne.sv
`include "global_defines.sv"
// Use relative paths for portability
`include "../../../sne/.bender/git/checkouts/axi-53d497d3fc7877da/src/axi_pkg.sv"
`include "../../../sne/.bender/git/checkouts/axi-53d497d3fc7877da/src/axi_intf.sv"

module Tile_sne#(
   parameter BW                = 32,
   parameter BWB               = BW/8,
   parameter BW_AXI            = 32,
   parameter BWB_AXI           = BW_AXI/8,
   parameter AXI_ADDR          =  8,
   parameter OFFSET_SZ         = 12,
   parameter XY_SZ             =  3,
   parameter NOC_BUFFER_ADDR_W =  8,
   // Scratchpad tile coordinates
   parameter SCRATCHPAD_TILE_X = 3'h0,  // X-coordinate of scratchpad tile
   parameter SCRATCHPAD_TILE_Y = 3'h1,   // Y-coordinate of scratchpad tile
   parameter STREAMERS         = 2
)(
   input  logic clk_control,
   input  logic clk_line,
   input  logic clk_line_rst_high,
   input  logic clk_line_rst_low,
   input  logic clk_control_rst_low,
   input  logic clk_control_rst_high,
   input  logic       [3:0] stream_in_TVALID,
   input  logic  [4*BW-1:0] stream_in_TDATA,
   input  logic [4*BWB-1:0] stream_in_TKEEP,
   input  logic       [3:0] stream_in_TLAST,
   output logic       [3:0] stream_in_TREADY,
   input  logic       [3:0] stream_out_TREADY,
   output logic       [3:0] stream_out_TVALID,
   output logic  [4*BW-1:0] stream_out_TDATA,
   output logic [4*BWB-1:0] stream_out_TKEEP,
   output logic       [3:0] stream_out_TLAST,
   input  logic plain_start_of_processing,
   (* dont_touch = "true" *) input  logic [AXI_ADDR-1:0] control_S_AXI_AWADDR,
   (* dont_touch = "true" *) input  logic                control_S_AXI_AWVALID,
   (* dont_touch = "true" *) output logic                control_S_AXI_AWREADY,
   (* dont_touch = "true" *) input  logic   [BW_AXI-1:0] control_S_AXI_WDATA,
   (* dont_touch = "true" *) input  logic  [BWB_AXI-1:0] control_S_AXI_WSTRB,
   (* dont_touch = "true" *) input  logic                control_S_AXI_WVALID,
   (* dont_touch = "true" *) output logic                control_S_AXI_WREADY,
   (* dont_touch = "true" *) input  logic                control_S_AXI_BREADY,
   (* dont_touch = "true" *) output logic          [1:0] control_S_AXI_BRESP,
   (* dont_touch = "true" *) output logic                control_S_AXI_BVALID,
   (* dont_touch = "true" *) input  logic [AXI_ADDR-1:0] control_S_AXI_ARADDR,
   (* dont_touch = "true" *) input  logic                control_S_AXI_ARVALID,
   (* dont_touch = "true" *) output logic                control_S_AXI_ARREADY,
   (* dont_touch = "true" *) input  logic                control_S_AXI_RREADY,
   (* dont_touch = "true" *) output logic   [BW_AXI-1:0] control_S_AXI_RDATA,
   (* dont_touch = "true" *) output logic          [1:0] control_S_AXI_RRESP,
   (* dont_touch = "true" *) output logic                control_S_AXI_RVALID
);

   //- Switch LOCAL signals
   logic           stream_out_local_out_TVALID;
   logic           stream_out_local_out_TLAST;
   logic  [BW-1:0] stream_out_local_out_TDATA;
   logic [BWB-1:0] stream_out_local_out_TKEEP;
   logic           stream_out_local_out_TREADY;
   logic           stream_in_local_in_TVALID;
   logic           stream_in_local_in_TLAST;
   logic  [BW-1:0] stream_in_local_in_TDATA;
   logic [BWB-1:0] stream_in_local_in_TKEEP;
   logic           stream_in_local_in_TREADY;

   //- Between AXI and memory manager signals
   logic mem_valid_axi;
   logic mem_wstrb_axi;
   logic [BW_AXI-1:0] mem_addr_axi;
   logic [BW_AXI-1:0] mem_wdata_axi;
   logic [BW_AXI-1:0] mem_rdata_axi;

   //- Registers
   logic       [7:0] rvControl;
   logic  [BW_AXI-1:0] tile_coordinates_line;
   logic [BW_AXI-1:0] tile_coordinates_ctrl;
   logic [XY_SZ-1:0] myX_line;
   logic [XY_SZ-1:0] myY_line;
   logic [XY_SZ-1:0] myX_ctrl;
   logic [XY_SZ-1:0] myY_ctrl;

   //- TCDM signals for SNE
   logic [STREAMERS-1:0]         tcdm_req;
   logic [STREAMERS-1:0]         tcdm_gnt;
   logic [STREAMERS-1:0] [31:0]  tcdm_add;
   logic [STREAMERS-1:0]         tcdm_wen;
   logic [STREAMERS-1:0] [3:0]   tcdm_be;
   logic [STREAMERS-1:0] [31:0]  tcdm_wdata;
   logic [STREAMERS-1:0] [31:0]  tcdm_rdata;
   logic [STREAMERS-1:0]         tcdm_r_valid;

   //- Wires for Configuration Window interface
   logic [31:0] config_addr;
   logic [31:0] config_wdata;
   logic        config_we;

   ///////////////////////////////////
   // AXI & TCDM 
   ///////////////////////////////////

   // Define separate signals for AXI and TCDM NoC interfaces
   logic           tcdm_stream_out_TVALID;
   logic [BW-1:0]  tcdm_stream_out_TDATA;
   logic [BWB-1:0] tcdm_stream_out_TKEEP;
   logic           tcdm_stream_out_TLAST;
   logic           tcdm_stream_out_TREADY;

   logic           tcdm_stream_in_TVALID;
   logic [BW-1:0]  tcdm_stream_in_TDATA;
   logic [BWB-1:0] tcdm_stream_in_TKEEP;
   logic           tcdm_stream_in_TLAST;
   logic           tcdm_stream_in_TREADY;

   logic           axi_stream_in_TVALID;
   logic [BW-1:0]  axi_stream_in_TDATA;
   logic [BWB-1:0] axi_stream_in_TKEEP;
   logic           axi_stream_in_TLAST;
   logic           axi_stream_in_TREADY;

   logic           acc_stream_out_TVALID;
   logic [BW-1:0]  acc_stream_out_TDATA;
   logic [BWB-1:0] acc_stream_out_TKEEP;
   logic           acc_stream_out_TLAST;
   logic           acc_stream_out_TREADY;

   assign myX_line = tile_coordinates_line[XY_SZ-1:0];
   assign myY_line = tile_coordinates_line[(2*XY_SZ)-1:XY_SZ];
   assign myX_ctrl = tile_coordinates_ctrl[XY_SZ-1:0];
   assign myY_ctrl = tile_coordinates_ctrl[(2*XY_SZ)-1:XY_SZ];

   // SNE Clock domains
   logic sne_system_clk;
   logic sne_system_rst_n;
   logic sne_interco_clk;
   logic sne_interco_rst_n;
   logic sne_engine_clk;
   logic sne_engine_rst_n;
   
   // Map MoSAIC clocks to SNE clocks
   assign sne_system_clk = clk_control;
   assign sne_system_rst_n = clk_control_rst_low;
   assign sne_interco_clk = clk_control; // Using control clock for both
   assign sne_interco_rst_n = clk_control_rst_low;
   assign sne_engine_clk = clk_line;
   assign sne_engine_rst_n = clk_line_rst_low;

   //- AXI Control Interface
   axi_control_sne#(
      .AXI_ADDR (AXI_ADDR)
   ) axi_control_inst (
      //- Clock and reset
      .clk_control          (clk_control),
      .clk_line             (clk_line),
      .clk_control_rst_low  (clk_control_rst_low),
      .clk_control_rst_high (clk_control_rst_high),
      .clk_line_rst_low     (clk_line_rst_low),
      .clk_line_rst_high    (clk_line_rst_high),
      //- Output Interface
      .stream_out_TREADY    (axi_stream_in_TREADY),
      .stream_out_TVALID    (axi_stream_in_TVALID),
      .stream_out_TLAST     (axi_stream_in_TLAST),
      //- AXI bus
      .control_S_AXI_AWADDR  (control_S_AXI_AWADDR),
      .control_S_AXI_AWVALID (control_S_AXI_AWVALID),
      .control_S_AXI_AWREADY (control_S_AXI_AWREADY),
      .control_S_AXI_WDATA   (control_S_AXI_WDATA),
      .control_S_AXI_WSTRB   (control_S_AXI_WSTRB),
      .control_S_AXI_WVALID  (control_S_AXI_WVALID),
      .control_S_AXI_WREADY  (control_S_AXI_WREADY),
      .control_S_AXI_BRESP   (control_S_AXI_BRESP),
      .control_S_AXI_BVALID  (control_S_AXI_BVALID),
      .control_S_AXI_BREADY  (control_S_AXI_BREADY),
      .control_S_AXI_ARADDR  (control_S_AXI_ARADDR),
      .control_S_AXI_ARVALID (control_S_AXI_ARVALID),
      .control_S_AXI_ARREADY (control_S_AXI_ARREADY),
      .control_S_AXI_RDATA   (control_S_AXI_RDATA),
      .control_S_AXI_RRESP   (control_S_AXI_RRESP),
      .control_S_AXI_RVALID  (control_S_AXI_RVALID),
      .control_S_AXI_RREADY  (control_S_AXI_RREADY),

      //- ADDED: Configuration Window Interface
      .config_addr_o         (config_addr),
      .config_wdata_o        (config_wdata),
      .config_we_o           (config_we),

      //- AXI memory interface
      .mem_valid_axi         (mem_valid_axi),
      .mem_addr_axi          (mem_addr_axi),
      .mem_wdata_axi         (mem_wdata_axi),
      .mem_wstrb_axi         (mem_wstrb_axi),
      .mem_rdata_axi         (mem_rdata_axi),
      .rvControl             (rvControl),
      .tile_coordinates_line (tile_coordinates_line),
      .tile_coordinates_ctrl (tile_coordinates_ctrl));

   
   // // Add a debug print to verify coordinates
   // always @(posedge clk_control) begin
   //    if (control_S_AXI_ARVALID && control_S_AXI_ARADDR == 8'h10) begin
   //       $display("[%t] SNE_TILE: Coords read detected. ctrl_coords=%h, line_coords=%h",
   //                $time, tile_coordinates_ctrl, tile_coordinates_line);
   //    end
   // end

   ///////////////////////////////////
   // Switch
   ///////////////////////////////////

   tile_noc#(
      .BW (BW)
   ) tile_noc (
      .HsrcId                      ({myY_line,myX_line}), 
      .stream_in_TVALID            (stream_in_TVALID),
      .stream_in_TREADY            (stream_in_TREADY),
      .stream_in_TDATA             (stream_in_TDATA),
      .stream_in_TKEEP             (stream_in_TKEEP),
      .stream_in_TLAST             (stream_in_TLAST),
      .stream_out_TVALID           (stream_out_TVALID),
      .stream_out_TREADY           (stream_out_TREADY),
      .stream_out_TDATA            (stream_out_TDATA),
      .stream_out_TKEEP            (stream_out_TKEEP),
      .stream_out_TLAST            (stream_out_TLAST),
      .stream_out_local_out_TVALID (stream_out_local_out_TVALID),
      .stream_out_local_out_TREADY (stream_out_local_out_TREADY),
      .stream_out_local_out_TDATA  (stream_out_local_out_TDATA),
      .stream_out_local_out_TKEEP  (stream_out_local_out_TKEEP),
      .stream_out_local_out_TLAST  (stream_out_local_out_TLAST),
      .stream_in_local_in_TVALID   (stream_in_local_in_TVALID),
      .stream_in_local_in_TREADY   (stream_in_local_in_TREADY),
      .stream_in_local_in_TDATA    (stream_in_local_in_TDATA),
      .stream_in_local_in_TKEEP    (stream_in_local_in_TKEEP),
      .stream_in_local_in_TLAST    (stream_in_local_in_TLAST),
      .clk_line                    (clk_line ),
      .clk_line_rst_high           (clk_line_rst_high ),
      .clk_line_rst_low            (clk_line_rst_low)
   );

   // Connect NoC responses directly to TCDM bridge AND acc_sne
   // The ready signal must be a combination of both consumers' ready signals.
   logic acc_sne_stream_in_TREADY;
   assign stream_out_local_out_TREADY = acc_sne_stream_in_TREADY & tcdm_stream_in_TREADY;
   
   // This completes the response path for TCDM transactions
   assign tcdm_stream_in_TVALID = stream_out_local_out_TVALID;
   assign tcdm_stream_in_TDATA  = stream_out_local_out_TDATA;
   assign tcdm_stream_in_TKEEP  = stream_out_local_out_TKEEP;
   assign tcdm_stream_in_TLAST  = stream_out_local_out_TLAST;
   // assign stream_out_local_out_TREADY = tcdm_stream_in_TREADY;
   
   // // Optionally add debugging
   // always @(posedge clk_line) begin
   //    if (tcdm_stream_in_TVALID && tcdm_stream_in_TREADY) begin
   //       $display("[%t] SNE_TILE: TCDM NoC response received: data=0x%08x, last=%b",
   //                $time, tcdm_stream_in_TDATA, tcdm_stream_in_TLAST);
   //    end
   // end


   // TCDM to NoC bridge
   tcdm_noc_bridge #(
      .BW(BW),
      .BWB(BWB),
      .XY_SZ(XY_SZ),
      .STREAMERS(STREAMERS),
      .SCRATCHPAD_TILE_X(SCRATCHPAD_TILE_X),
      .SCRATCHPAD_TILE_Y(SCRATCHPAD_TILE_Y),
      .MAX_OUTSTANDING(4),
      .TIMEOUT_CYCLES(1000)
   ) i_tcdm_noc_bridge (
      .clk_i(sne_system_clk),
      .rst_ni(sne_system_rst_n),
      .HsrcId({myY_ctrl, myX_ctrl}),
      
      // TCDM Interface (connect to SNE)
      .tcdm_req_i(tcdm_req),
      .tcdm_gnt_o(tcdm_gnt),
      .tcdm_add_i(tcdm_add),
      .tcdm_wen_i(tcdm_wen),
      .tcdm_be_i(tcdm_be),
      .tcdm_data_i(tcdm_wdata),
      .tcdm_r_data_o(tcdm_rdata),
      .tcdm_r_valid_o(tcdm_r_valid),
      
      // NoC Interface (connect to tile's local ports)
      .stream_out_TVALID(tcdm_stream_out_TVALID),
      .stream_out_TDATA(tcdm_stream_out_TDATA),
      .stream_out_TKEEP(tcdm_stream_out_TKEEP),
      .stream_out_TLAST(tcdm_stream_out_TLAST),
      .stream_out_TREADY(tcdm_stream_out_TREADY),
      
      .stream_in_TVALID(tcdm_stream_in_TVALID),
      .stream_in_TDATA(tcdm_stream_in_TDATA),
      .stream_in_TKEEP(tcdm_stream_in_TKEEP),
      .stream_in_TLAST(tcdm_stream_in_TLAST),
      .stream_in_TREADY(tcdm_stream_in_TREADY)
   );

   ///////////////////////////////////
   // SNE Core
   ///////////////////////////////////
   acc_sne #(
      .OFFSET_SZ         (OFFSET_SZ),
      .XY_SZ             (XY_SZ),
      .BW                (BW),
      .BWB               (BWB),
      .NOC_BUFFER_ADDR_W (NOC_BUFFER_ADDR_W),
      .STREAMERS         (STREAMERS)
   ) acc_sne_inst (
      //---Clock and Reset---//
      .clk_ctrl          (clk_control),
      .clk_line          (clk_line),
      .clk_ctrl_rst_low  (clk_control_rst_low),
      .clk_line_rst_low  (clk_line_rst_low),
      .clk_ctrl_rst_high (clk_control_rst_high),
      .clk_line_rst_high (clk_line_rst_high),
      .HsrcId            ({myY_ctrl, myX_ctrl}),
      
      //---NOC interface---//
      .stream_in_TVALID  (stream_out_local_out_TVALID),
      .stream_in_TDATA   (stream_out_local_out_TDATA),
      .stream_in_TKEEP   (stream_out_local_out_TKEEP),
      .stream_in_TLAST   (stream_out_local_out_TLAST),
      .stream_in_TREADY  (acc_sne_stream_in_TREADY), // Use the new dedicated ready signal
      
      .stream_out_TREADY (acc_stream_out_TREADY),
      .stream_out_TVALID (acc_stream_out_TVALID),
      .stream_out_TDATA  (acc_stream_out_TDATA),
      .stream_out_TKEEP  (acc_stream_out_TKEEP),
      .stream_out_TLAST  (acc_stream_out_TLAST),
      
      //- AXI memory interface
      .mem_valid_axi     (mem_valid_axi),
      .mem_addr_axi      (mem_addr_axi),
      .mem_wdata_axi     (mem_wdata_axi),
      .mem_wstrb_axi     (mem_wstrb_axi),
      .mem_rdata_axi     (mem_rdata_axi),
      .rvControl         (rvControl),
      
      //- Configuration Window Interface
      .config_addr_i     (config_addr),
      .config_wdata_i    (config_wdata),
      .config_we_i       (config_we),
      
      //- TCDM interface
      .tcdm_req_o        (tcdm_req),
      .tcdm_gnt_i        (tcdm_gnt),
      .tcdm_add_o        (tcdm_add),
      .tcdm_wen_o        (tcdm_wen),
      .tcdm_be_o         (tcdm_be),
      .tcdm_data_o       (tcdm_wdata),
      .tcdm_r_data_i     (tcdm_rdata),
      .tcdm_r_valid_i    (tcdm_r_valid)
   );


   ///////////////////////////////////
   // Arbiter
   ///////////////////////////////////
   noc_out_arbiter tile_output_arbiter (
   .clk_line(clk_control),
   .clk_line_rst_low(clk_control_rst_low),
   
   // AXI control connection
   .stream_in_pcpi_TREADY(axi_stream_in_TREADY),
   .stream_in_pcpi_TVALID(axi_stream_in_TVALID),
   .stream_in_pcpi_TDATA(axi_stream_in_TDATA),
   .stream_in_pcpi_TKEEP(axi_stream_in_TKEEP),
   .stream_in_pcpi_TLAST(axi_stream_in_TLAST),
   
   // ACC_SNE connection - use the new signals
   .stream_in_mem_TREADY(acc_stream_out_TREADY),
   .stream_in_mem_TVALID(acc_stream_out_TVALID),
   .stream_in_mem_TDATA(acc_stream_out_TDATA),
   .stream_in_mem_TKEEP(acc_stream_out_TKEEP),
   .stream_in_mem_TLAST(acc_stream_out_TLAST),
   
   // TCDM bridge connection
   .stream_in_spy_TREADY(tcdm_stream_out_TREADY),
   .stream_in_spy_TVALID(tcdm_stream_out_TVALID),
   .stream_in_spy_TDATA(tcdm_stream_out_TDATA),
   .stream_in_spy_TKEEP(tcdm_stream_out_TKEEP),
   .stream_in_spy_TLAST(tcdm_stream_out_TLAST),
   
   // Unused inputs
   .stream_in_noc_TREADY(),
   .stream_in_noc_TVALID(1'b0),
   .stream_in_noc_TDATA(32'h0),
   .stream_in_noc_TKEEP(4'h0),
   .stream_in_noc_TLAST(1'b0),
   
   // Output to NoC
   .stream_out_TREADY(stream_in_local_in_TREADY),
   .stream_out_TVALID(stream_in_local_in_TVALID),
   .stream_out_TDATA(stream_in_local_in_TDATA),
   .stream_out_TKEEP(stream_in_local_in_TKEEP),
   .stream_out_TLAST(stream_in_local_in_TLAST)
   );

   // // Add debug monitoring for TCDM interface
   // always @(posedge clk_control) begin
   //    if (|tcdm_req) begin
   //       $display("[%t] SNE_TILE: TCDM REQUEST: req=0x%h, addr=0x%h, wen=0x%h, be=0x%h, wdata=0x%h", 
   //                $time, tcdm_req, tcdm_add, tcdm_wen, tcdm_be, tcdm_wdata);
   //    end
   // end
endmodule


