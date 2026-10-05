`timescale 1ps/1ps
// Self-checking testbench for async_fifo.
// Plusargs: +SEED=n +WCLK_PS=n +RCLK_PS=n +N=words +COV_STRICT
module tb_async_fifo;
  localparam int DATA_W = 8;
  localparam int ADDR_W = 4;
  localparam int DEPTH  = 1 << ADDR_W;
  localparam logic [ADDR_W:0] PTR_DEPTH = (ADDR_W+1)'(DEPTH);  // pointer-width DEPTH for wraparound math

  logic              wclk = 0, rclk = 0, wrst_n = 0, rrst_n = 0;
  logic              winc = 0, rinc = 0, wfull, rempty;
  logic [DATA_W-1:0] wdata = 0, rdata;

  async_fifo #(.DATA_W(DATA_W), .ADDR_W(ADDR_W)) dut (.*);

  // ---------------- configuration ----------------
  int unsigned seed, wper, rper, n_words;
  initial begin
    if (!$value$plusargs("SEED=%d", seed))    seed    = 1;
    if (!$value$plusargs("N=%d", n_words))    n_words = 5000;
    process::self().srandom(seed);
    if (!$value$plusargs("WCLK_PS=%d", wper)) wper = $urandom_range(3000, 37000);
    if (!$value$plusargs("RCLK_PS=%d", rper)) rper = $urandom_range(3000, 37000);
    wper &= ~32'd1; rper &= ~32'd1;   // even, so half-periods are exact
    $display("CONFIG seed=%0d wclk=%0dps rclk=%0dps ratio=%.3f words=%0d",
             seed, wper, rper, real'(rper) / real'(wper), n_words);
  end

  // Clocks: random start phase; non-integer ratios drift through every phase.
  initial begin #1; #($urandom_range(0, wper)); forever #(wper/2) wclk = ~wclk; end
  initial begin #1; #($urandom_range(0, rper)); forever #(rper/2) rclk = ~rclk; end

  // Resets: released independently, each at its own negedge.
  initial begin #1; repeat (3 + $urandom_range(0, 4)) @(negedge wclk); wrst_n = 1; end
  initial begin #1; repeat (3 + $urandom_range(0, 4)) @(negedge rclk); rrst_n = 1; end

`ifdef TRACE
  initial begin $dumpfile("waves.vcd"); $dumpvars(0, tb_async_fifo); end
`endif

  // Watchdog: generous bound on total runtime.
  initial begin
    #2;
    #(64'(n_words + 100) * 64'(wper + rper) * 64'd20);
    $fatal(1, "TIMEOUT pushes=%0d pops=%0d", pushes, pops);
  end

  // ---------------- drivers ----------------
  // Each domain switches traffic mode every 20..200 cycles: burst / sparse /
  // balanced / idle duty, so full and empty are reached at every clock ratio.
  function automatic int unsigned pick_duty();
    case ($urandom_range(0, 3))
      0: return 90;
      1: return 10;
      2: return 50;
      default: return 0;
    endcase
  endfunction

  int unsigned pushes = 0, pops = 0;

  initial begin : wr_driver
    automatic int unsigned duty = 0, left = 0;
    @(posedge wrst_n);
    forever begin
      @(negedge wclk);
      if (pushes >= n_words) begin winc = 0; break; end
      if (left == 0) begin duty = pick_duty(); left = $urandom_range(20, 200); end
      left--;
      winc  = $urandom_range(0, 99) < duty;
      wdata = DATA_W'($urandom);
    end
  end

  initial begin : rd_driver
    automatic int unsigned duty = 0, left = 0;
    @(posedge rrst_n);
    forever begin
      @(negedge rclk);
      if (pops >= n_words) begin rinc = 0; break; end
      if (left == 0) begin duty = pick_duty(); left = $urandom_range(20, 200); end
      left--;
      rinc = $urandom_range(0, 99) < duty;
    end
  end

  // ---------------- scoreboard ----------------
  logic [DATA_W-1:0] model[$];

  always @(posedge wclk) if (wrst_n && winc && !wfull) begin
    model.push_back(wdata);
    pushes++;
    if (model.size() > DEPTH)
      $fatal(1, "OVERFLOW t=%0t: %0d words held, DEPTH=%0d", $time, model.size(), DEPTH);
  end

  always @(posedge rclk) if (rrst_n && rinc && !rempty) begin
    logic [DATA_W-1:0] exp;
    if (model.size() == 0)
      $fatal(1, "UNDERFLOW t=%0t: read 0x%0h from FIFO that holds nothing", $time, rdata);
    exp = model.pop_front();
    if (rdata !== exp)
      $fatal(1, "MISMATCH t=%0t word#%0d: expected 0x%0h got 0x%0h", $time, pops, exp, rdata);
    pops++;
  end

  // ---------------- assertions ----------------
  // Gray pointers that cross the CDC boundary change at most one bit per edge.
  a_wptr_gray: assert property (@(posedge wclk) disable iff (!wrst_n)
    $onehot0(dut.wptr ^ $past(dut.wptr))) else $fatal(1, "wptr changed >1 bit");
  a_rptr_gray: assert property (@(posedge rclk) disable iff (!rrst_n)
    $onehot0(dut.rptr ^ $past(dut.rptr))) else $fatal(1, "rptr changed >1 bit");

  // CDC coherence: a synchronized pointer must be a value its source actually
  // held, so it only moves forward and never runs ahead of the source.
  // Gray coding guarantees this under metastability; binary pointers do not.
  function automatic logic [ADDR_W:0] g2b(logic [ADDR_W:0] g);
    for (int i = ADDR_W - 1; i >= 0; i--) g[i] ^= g[i+1];
    return g;
  endfunction

  logic [ADDR_W:0] rq2_wbin_q = '0, wq2_rbin_q = '0;
  always @(posedge rclk) if (rrst_n) begin
    automatic logic [ADDR_W:0] s    = g2b(dut.rq2_wptr);
    automatic logic [ADDR_W:0] step = s - rq2_wbin_q;       // forward motion since last edge
    automatic logic [ADDR_W:0] lead = dut.wbin - s;  // how far the source is ahead
    if (step > PTR_DEPTH || lead > PTR_DEPTH)
      $fatal(1, "INCOHERENT CDC t=%0t: write ptr synced as %0d (prev %0d, source %0d)",
             $time, s, rq2_wbin_q, dut.wbin);
    rq2_wbin_q <= s;
  end
  always @(posedge wclk) if (wrst_n) begin
    automatic logic [ADDR_W:0] s    = g2b(dut.wq2_rptr);
    automatic logic [ADDR_W:0] step = s - wq2_rbin_q;       // forward motion since last edge
    automatic logic [ADDR_W:0] lead = dut.rbin - s;  // how far the source is ahead
    if (step > PTR_DEPTH || lead > PTR_DEPTH)
      $fatal(1, "INCOHERENT CDC t=%0t: read ptr synced as %0d (prev %0d, source %0d)",
             $time, s, wq2_rbin_q, dut.rbin);
    wq2_rbin_q <= s;
  end

  // Flags out of reset.
  initial begin
    @(posedge wrst_n); if (wfull)   $fatal(1, "wfull set out of reset");
    @(posedge rrst_n); if (!rempty) $fatal(1, "rempty clear out of reset");
  end

  // Liveness: a flag may lag the true state by the synchronizer latency, but
  // must not stay pessimistic longer (stuck-empty / stuck-full detection).
  int unsigned empty_lag = 0, full_lag = 0;
  always @(posedge rclk) if (rrst_n) begin
    empty_lag = (rempty && model.size() > 0) ? empty_lag + 1 : 0;
    if (empty_lag > 4 + wper / rper + 1) $fatal(1, "STUCK EMPTY t=%0t: %0d words held", $time, model.size());
  end
  always @(posedge wclk) if (wrst_n) begin
    full_lag = (wfull && model.size() < DEPTH) ? full_lag + 1 : 0;
    if (full_lag > 4 + rper / wper + 1) $fatal(1, "STUCK FULL t=%0t: %0d words held", $time, model.size());
  end

  // ---------------- functional coverage ----------------
  // Explicit bin counters (Verilator does not implement covergroups).
  typedef enum int {
    C_FULL, C_EMPTY, C_WR_WHILE_FULL, C_RD_WHILE_EMPTY, C_FULL_EXIT, C_EMPTY_EXIT,
    C_CONCURRENT, C_OCC_0, C_OCC_1, C_OCC_LOW, C_OCC_MID, C_OCC_HIGH, C_OCC_DM1,
    C_OCC_D, C_WPTR_WRAP2, C_RPTR_WRAP2, C_NUM
  } cov_e;
  int unsigned cov[C_NUM];
  logic wfull_q = 0, rempty_q = 1;

  function automatic void sample_occ(int unsigned n);
    if      (n == 0)              cov[C_OCC_0]++;
    else if (n == 1)              cov[C_OCC_1]++;
    else if (n <= DEPTH/4)        cov[C_OCC_LOW]++;
    else if (n <  3*DEPTH/4)      cov[C_OCC_MID]++;
    else if (n <= DEPTH-2)        cov[C_OCC_HIGH]++;
    else if (n == DEPTH-1)        cov[C_OCC_DM1]++;
    else                          cov[C_OCC_D]++;
  endfunction

  always @(posedge wclk) if (wrst_n) begin
    if (wfull)                      cov[C_FULL]++;
    if (wfull && winc)              cov[C_WR_WHILE_FULL]++;
    if (wfull_q && !wfull)          cov[C_FULL_EXIT]++;
    if (pushes >= 4 * DEPTH)        cov[C_WPTR_WRAP2]++;   // pointer MSB toggled twice
    wfull_q <= wfull;
    sample_occ(model.size());
  end

  always @(posedge rclk) if (rrst_n) begin
    if (rempty && pops > 0)         cov[C_EMPTY]++;
    if (rempty && rinc && pops > 0) cov[C_RD_WHILE_EMPTY]++;
    if (rempty_q && !rempty)        cov[C_EMPTY_EXIT]++;
    if (!rempty && rinc && winc && !wfull) cov[C_CONCURRENT]++;
    if (pops >= 4 * DEPTH)          cov[C_RPTR_WRAP2]++;
    rempty_q <= rempty;
    sample_occ(model.size());
  end

  function automatic real report_coverage();
    int unsigned hit = 0;
    for (int i = 0; i < C_NUM; i++) begin
      cov_e c = cov_e'(i);
      $display("  %-18s %8d  %s", c.name(), cov[i], cov[i] > 0 ? "HIT" : "MISS");
      if (cov[i] > 0) hit++;
    end
    $display("COVERAGE %.1f%% (%0d/%0d bins)", 100.0 * hit / C_NUM, hit, C_NUM);
    return 100.0 * hit / C_NUM;
  endfunction

  // ---------------- end of test ----------------
  initial begin
    real pct;
    #2;
    wait (pops == n_words);
    repeat (10) @(posedge rclk);
    if (model.size() != 0) $fatal(1, "LEFTOVER %0d words in model", model.size());
    if (!rempty)           $fatal(1, "FIFO not empty after draining");
    if (pushes != pops)    $fatal(1, "COUNT pushes=%0d pops=%0d", pushes, pops);
    $display("SCOREBOARD %0d words written, %0d read and matched", pushes, pops);
    pct = report_coverage();
    if ($test$plusargs("COV_STRICT") && pct < 100.0) $fatal(1, "coverage below 100%%");
    $display("PASS");
    $finish;
  end
endmodule
