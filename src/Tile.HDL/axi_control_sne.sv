`timescale 1 ps / 1 ps
`include "global_defines.sv"
// Use relative paths to locate the AXI dependency files
`include "../../../sne/.bender/git/checkouts/axi-53d497d3fc7877da/src/axi_pkg.sv"
`include "../../../sne/.bender/git/checkouts/axi-53d497d3fc7877da/src/axi_intf.sv"
`include "../../../sne/.bender/git/checkouts/axi-53d497d3fc7877da/include/axi/typedef.svh"

module axi_control_sne#(
  parameter BW  = 32,
  parameter BWB = BW/8,
  parameter AXI_ADDR = 8,
  parameter XY_SZ = 3
)(
  input logic clk_control,
  input logic clk_line,
  input logic clk_line_rst_high,
  input logic clk_line_rst_low,
  input logic clk_control_rst_low,
  input logic clk_control_rst_high,
  //---NOC interface---//
  input  logic        stream_out_TREADY,
  input logic         stream_out_TVALID,
  input logic         stream_out_TLAST,
  //- AXI controller (ports are unchanged)
  (* dont_touch = "true" *) input  logic [AXI_ADDR-1:0] control_S_AXI_AWADDR,
  (* dont_touch = "true" *) input  logic                control_S_AXI_AWVALID,
  (* dont_touch = "true" *) output logic                control_S_AXI_AWREADY,
  (* dont_touch = "true" *) input  logic       [BW-1:0] control_S_AXI_WDATA,
  (* dont_touch = "true" *) input  logic      [BWB-1:0] control_S_AXI_WSTRB,
  (* dont_touch = "true" *) input  logic                control_S_AXI_WVALID,
  (* dont_touch = "true" *) output logic                control_S_AXI_WREADY,
  (* dont_touch = "true" *) input  logic                control_S_AXI_BREADY,
  (* dont_touch = "true" *) output logic          [1:0] control_S_AXI_BRESP,
  (* dont_touch = "true" *) output logic                control_S_AXI_BVALID,
  (* dont_touch = "true" *) input  logic [AXI_ADDR-1:0] control_S_AXI_ARADDR,
  (* dont_touch = "true" *) input  logic                control_S_AXI_ARVALID,
  (* dont_touch = "true" *) output logic                control_S_AXI_ARREADY,
  (* dont_touch = "true" *) input  logic                control_S_AXI_RREADY,
  (* dont_touch = "true" *) output logic       [BW-1:0] control_S_AXI_RDATA,
  (* dont_touch = "true" *) output logic          [1:0] control_S_AXI_RRESP,
  (* dont_touch = "true" *) output logic                control_S_AXI_RVALID,
  //- AXI memory interface
	output  logic        mem_valid_axi,
	output  logic [31:0] mem_addr_axi,
	output  logic [31:0] mem_wdata_axi,
	output  logic        mem_wstrb_axi,
	input   logic [31:0] mem_rdata_axi,

  //- Configuration Window Interface to SNE Core -//
  output logic [31:0] config_addr_o,
  output logic [31:0] config_wdata_o,
  output logic        config_we_o,

  //- Tile id.
  output logic [7:0]    rvControl,
  output logic [BW-1:0] tile_coordinates_line,
  output logic [BW-1:0] tile_coordinates_ctrl
);


logic [BW-1:0] rxPacketCount;
logic [BW-1:0] rxByteCount;

logic [BW-1:0] rxPacketCount_sync;
logic [BW-1:0] rxByteCount_sync;

//- synchronization!
xpm_cdc_array_single#(
  .WIDTH(BW),
  .SIM_ASSERT_CHK(`SIM_ASSERT_CHK)
) coord_cdc (
  // Module ports
  .src_clk  (clk_control),
  .src_in   (tile_coordinates_ctrl),
  .dest_clk (clk_line),
  .dest_out (tile_coordinates_line));

xpm_cdc_array_single #(
  .WIDTH(BW),
  .SIM_ASSERT_CHK(`SIM_ASSERT_CHK)
) rxPacketCnt_cdc (  // Module ports
  .src_clk  (clk_line),
  .src_in   (rxPacketCount),
  .dest_clk (clk_control),
  .dest_out (rxPacketCount_sync));

xpm_cdc_array_single #(
  .WIDTH(BW),
  .SIM_ASSERT_CHK(`SIM_ASSERT_CHK)
) rxByteCnt_cdc (
  // Module ports
  .src_clk  (clk_line),
  .src_in   (rxByteCount),
  .dest_clk (clk_control),
  .dest_out (rxByteCount_sync));

localparam AXI_AUX = 8-AXI_ADDR; 

RV_AXIInD rvaxiIndirect_inst (
  .aclk             (clk_control),
  .aresetn          (clk_control_rst_low),
  .axil_awvalid     (control_S_AXI_AWVALID),
  .axil_awaddr      ({{AXI_AUX{1'b0}},control_S_AXI_AWADDR}),
  .axil_awready     (control_S_AXI_AWREADY),
  .axil_wvalid      (control_S_AXI_WVALID),
  .axil_wdata       (control_S_AXI_WDATA),
  .axil_wstrb       (control_S_AXI_WSTRB),
  .axil_wready      (control_S_AXI_WREADY),
  .axil_bvalid      (control_S_AXI_BVALID),
  .axil_bresp       (control_S_AXI_BRESP),
  .axil_bready      (control_S_AXI_BREADY),
  .axil_arvalid     (control_S_AXI_ARVALID),
  .axil_araddr      ({{AXI_AUX{1'b0}},control_S_AXI_ARADDR}),
  .axil_arready     (control_S_AXI_ARREADY),
  .axil_rvalid      (control_S_AXI_RVALID),
  .axil_rdata       (control_S_AXI_RDATA),
  .axil_rresp       (control_S_AXI_RRESP),
  .axil_rready      (control_S_AXI_RREADY),
  //- AXI interface for the memory
  .mem_en           (mem_valid_axi),   //- Output
  .mem_we           (mem_wstrb_axi),   //- Output
  .mem_addr         (mem_addr_axi),    //- Output
  .mem_din          (mem_wdata_axi),   //- Output
  .mem_dout         (mem_rdata_axi),   //- Input
  //- Control registers
  .rv_control       (rvControl),               //- Output
  .tile_coordinates (tile_coordinates_ctrl),   //- Output
  .rxPacketCount    (rxPacketCount_sync),      //- Input
  .rxByteCount      (rxByteCount_sync));       //- Input

///////////////////////////////////
// Packet Counters
///////////////////////////////////

always @( posedge clk_line ) begin 
  if (clk_line_rst_high) begin 
    rxPacketCount <= 'd0;
    rxByteCount   <= 'd0;
  end else if (stream_out_TVALID && stream_out_TREADY) begin 
    rxByteCount <= rxByteCount+'d4;
    if (stream_out_TLAST) rxPacketCount <= rxPacketCount+'d1;
  end
end 


endmodule