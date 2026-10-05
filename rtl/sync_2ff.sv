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
  // Sim-only metastability model. If d changed since the last edge, the bits
  // of that transition may violate setup/hold and each resolves independently
  // to its old or new value. A d stable for a full period is captured cleanly.
  logic [W-1:0] d_cur, d_prev;
  time          t_chg, t_edge;
  initial begin d_cur = '0; d_prev = '0; t_chg = 0; t_edge = 0; end
  always @(d) begin d_prev = d_cur; d_cur = d; t_chg = $time; end
  always @(posedge clk) t_edge <= $time;
  // >=: a change at the same timestep as the last edge landed after it sampled.
  function automatic logic [W-1:0] capture();
    return (t_chg >= t_edge) ? d ^ (W'($urandom) & (d ^ d_prev)) : d;
  endfunction
`else
  function automatic logic [W-1:0] capture();
    return d;
  endfunction
`endif

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) {sync, meta} <= '0;
    else        {sync, meta} <= {meta, capture()};

  assign q = sync;
endmodule
