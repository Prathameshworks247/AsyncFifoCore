// 2-flop synchronizer for a multi-bit bus. Only safe for buses where at most
// one bit changes per source clock (e.g. Gray-coded pointers).
module sync_2ff #(
  parameter int W = 1
) (
  input  logic         clk,
  input  logic         rst_n,
  input  logic [W-1:0] d,
  output logic [W-1:0] q
);
  (* ASYNC_REG = "TRUE" *) logic [W-1:0] meta;
  (* ASYNC_REG = "TRUE" *) logic [W-1:0] sync;

`ifdef METASTABILITY
  // Sim-only metastability model: every bit that changes this edge may violate
  // setup/hold, so it independently resolves to either the old or the new value.
  logic [W-1:0] flip;
  always_comb flip = W'($urandom) & (d ^ meta);
  wire  [W-1:0] meta_next = d ^ flip;
`else
  wire  [W-1:0] meta_next = d;
`endif

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) {sync, meta} <= '0;
    else        {sync, meta} <= {meta, meta_next};

  assign q = sync;
endmodule
