// Asynchronous FIFO (Cummings style). Gray-coded pointers cross clock domains
// through 2-flop synchronizers; full is computed in the write domain and empty
// in the read domain, both registered and both pessimistic (never wrong-unsafe).
// rdata is first-word-fall-through: valid whenever !rempty.
module async_fifo #(
  parameter int DATA_W = 8,
  parameter int ADDR_W = 4            // DEPTH = 2**ADDR_W, ADDR_W >= 2
) (
  input  logic              wclk,
  input  logic              wrst_n,
  input  logic              winc,
  input  logic [DATA_W-1:0] wdata,
  output logic              wfull,

  input  logic              rclk,
  input  logic              rrst_n,
  input  logic              rinc,
  output logic [DATA_W-1:0] rdata,
  output logic              rempty
);
  localparam int DEPTH = 1 << ADDR_W;

  logic [DATA_W-1:0] mem [DEPTH];

  // ADDR_W+1 bit pointers: the extra MSB distinguishes full from empty.
  logic [ADDR_W:0] wbin, wptr, rbin, rptr;   // wptr/rptr are Gray
  logic [ADDR_W:0] wq2_rraw, rq2_wraw;       // values after synchronizers
  logic [ADDR_W:0] wq2_rptr, rq2_wptr;       // synced pointers, Gray

`ifdef BUG_BINARY_SYNC
  // Bug injection: send binary pointers across the CDC boundary. Several bits
  // change at once, so a synchronizer can capture a value that never existed.
  sync_2ff #(.W(ADDR_W+1)) u_sync_r2w (.clk(wclk), .rst_n(wrst_n), .d(rbin), .q(wq2_rraw));
  sync_2ff #(.W(ADDR_W+1)) u_sync_w2r (.clk(rclk), .rst_n(rrst_n), .d(wbin), .q(rq2_wraw));
  assign wq2_rptr = (wq2_rraw >> 1) ^ wq2_rraw;
  assign rq2_wptr = (rq2_wraw >> 1) ^ rq2_wraw;
`else
  sync_2ff #(.W(ADDR_W+1)) u_sync_r2w (.clk(wclk), .rst_n(wrst_n), .d(rptr), .q(wq2_rraw));
  sync_2ff #(.W(ADDR_W+1)) u_sync_w2r (.clk(rclk), .rst_n(rrst_n), .d(wptr), .q(rq2_wraw));
  assign wq2_rptr = wq2_rraw;
  assign rq2_wptr = rq2_wraw;
`endif

  // ---------------- write domain ----------------
  wire             wen        = winc && !wfull;
  wire [ADDR_W:0]  wbin_next  = wbin + (ADDR_W+1)'(wen);
  wire [ADDR_W:0]  wgray_next = (wbin_next >> 1) ^ wbin_next;
  // Full: Gray pointers equal except the two MSBs, which are inverted.
  wire             wfull_next = wgray_next == {~wq2_rptr[ADDR_W -: 2], wq2_rptr[ADDR_W-2:0]};

  always_ff @(posedge wclk or negedge wrst_n)
    if (!wrst_n) {wbin, wptr, wfull} <= '0;
    else         {wbin, wptr, wfull} <= {wbin_next, wgray_next, wfull_next};

  always_ff @(posedge wclk)
    if (wen) mem[wbin[ADDR_W-1:0]] <= wdata;

  // ---------------- read domain ----------------
  wire             ren         = rinc && !rempty;
  wire [ADDR_W:0]  rbin_next   = rbin + (ADDR_W+1)'(ren);
  wire [ADDR_W:0]  rgray_next  = (rbin_next >> 1) ^ rbin_next;
  wire             rempty_next = rgray_next == rq2_wptr;

  always_ff @(posedge rclk or negedge rrst_n)
    if (!rrst_n) {rbin, rptr, rempty} <= {{2*(ADDR_W+1){1'b0}}, 1'b1};
    else         {rbin, rptr, rempty} <= {rbin_next, rgray_next, rempty_next};

  assign rdata = mem[rbin[ADDR_W-1:0]];
endmodule
