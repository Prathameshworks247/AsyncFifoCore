# AsyncFifoCore

An asynchronous FIFO for passing data safely between two unrelated clock domains, with a self-checking SystemVerilog testbench that **proves the CDC scheme works, and proves the testbench would notice if it didn't.**

- Gray-coded read/write pointers crossing domains through 2-flop synchronizers
- Registered `wfull` (write domain) and `rempty` (read domain), first-word-fall-through read
- Randomized traffic at 8 clock ratios × 20 seeds, scoreboard checks every word
- SVA, CDC coherence checks and liveness checks, plus 16 functional coverage bins at 100%
- A **metastability model** plus a **bug-injection build** that the testbench catches in 160/160 runs

## Architecture

```
            write clock domain                 │                read clock domain
                                               │
 wdata ──►┌──────────────────────────────────┐ │
 winc  ──►│  dual-port RAM  (2^ADDR_W words) │─┼──────────────────────────────► rdata
          └──────────────────────────────────┘ │
             ▲ waddr                           │                       ▲ raddr
 ┌───────────┴───────────┐                     │           ┌───────────┴───────────┐
 │ wbin ─► bin2gray ─► wptr ═══════════════════╪══► sync_2ff ══► rq2_wptr          │
 │                       │                     │           │   rempty = (rgray_next│
 │ wfull = (wgray_next ==│                     │           │      == rq2_wptr)     │──► rempty
 │   {~wq2_rptr[MSB:MSB-1],                    │           │                       │◄── rinc
 │     wq2_rptr[rest]})  │                     │           │ rbin ─► bin2gray ─► rptr
 │       wq2_rptr ◄══ sync_2ff ◄═══════════════╪═══════════════════════════════╝   │
 └───────────────────────┘                     │           └───────────────────────┘
 wfull ◄──┘                                    │
```

Pointers are `ADDR_W+1` bits wide. The extra MSB tells *full* (same address, opposite wrap) apart from *empty* (identical pointers). In Gray code, "opposite wrap, same address" means the top two bits are inverted.

| File | Purpose |
|---|---|
| `rtl/async_fifo.sv` | FIFO top: memory, write-domain pointer/full, read-domain pointer/empty |
| `rtl/sync_2ff.sv` | 2-flop synchronizer (`ASYNC_REG`), with an optional sim-only metastability model |
| `tb/tb_async_fifo.sv` | Testbench: clocks, drivers, scoreboard, assertions, coverage |
| `scripts/regress.sh` | Ratio × seed regression and bug-injection run |

## Why Gray code

A 2-flop synchronizer only stops metastability from *propagating*. It cannot stop a flop from resolving to the wrong value. If several bits of a bus change near the sampling edge, each bit resolves independently, and the captured word can be one the source **never held**.

Gray-coded pointers change exactly one bit per increment. So the only uncertain bit picks between the old and the new pointer, and both are legitimate values. A late value only makes a flag *pessimistic*:

- **`rempty` may deassert late:** the reader waits an extra cycle or two. That's safe.
- **`wfull` may deassert late:** the writer waits. That's safe.

Neither flag can ever claim data or space that doesn't exist.

## The metastability model

By default, simulation is perfectly deterministic. A flop captures exactly what is on its input, so a FIFO that syncs **binary** pointers passes every test. That's a real hazard: the bug ships.

`+define+METASTABILITY` swaps in a model inside `sync_2ff`. When the input changed since the last sampling edge, every bit of that transition resolves randomly to its old or its new value. A signal that has been stable for a full period is captured cleanly.

`+define+BUG_BINARY_SYNC` sends binary pointers across instead of Gray. Results:

| Build | Metastability model | Result |
|---|---|---|
| Gray pointers | on | **160/160 PASS**, 100% coverage |
| Binary pointers | off | passes. The bug is invisible to a normal simulation |
| Binary pointers | on | **160/160 caught** |

```
CONFIG seed=4 wclk=3000ps rclk=21000ps ratio=7.000 words=5000
%Fatal: INCOHERENT CDC t=254257: read ptr synced as 7 (prev 3, source 4)
```

That's binary `011 → 100` captured as `111`, a pointer value that never existed.

**Finding: the scoreboard alone does not catch this bug.** Because both flags are *registered* equality compares, an incoherent value lives in the synchronizer for only one cycle. So it can trigger at most one extra read or write. The pointer transition that produced the bad value always freed a slot or added a word, so that extra operation is backed by real space or real data. What catches the bug is the **CDC coherence check**: a synchronized pointer must move forward monotonically and never run ahead of its source. That's exactly the property Gray coding provides. (A design that derived occupancy counts or almost-full thresholds from the synced pointer would fail functionally as well.)

## Verification

| Check | How |
|---|---|
| Data integrity | Queue scoreboard; every read is compared; the FIFO is drained and checked empty at end of test |
| Overflow / underflow | Fatal if the model holds more than DEPTH words, or a read happens with none written |
| Gray property | SVA: `$onehot0(wptr ^ $past(wptr))`, and the same for `rptr` |
| CDC coherence | Synced pointer is monotonic and never ahead of its source pointer |
| Liveness | `rempty`/`wfull` may lag the true state only by the synchronizer latency, or the run fails as stuck |
| Reset | `rempty=1`, `wfull=0` after independent per-domain resets |
| Sanity mutation | Removing `!wfull` from the write enable trips `OVERFLOW` |

**Coverage bins** (all must be hit with `+COV_STRICT`): full, empty, write while full, read while empty, full→not-full, empty→not-empty, concurrent read and write, occupancy 0 / 1 / low / mid / high / DEPTH-1 / DEPTH, and ≥ 2 wraparounds of each pointer. Verilator does not implement covergroups, so these are explicit bin counters.

**Regression** (`make regress`, metastability model on):

```
ratio     wclk_ps  rclk_ps   passed   coverage
1:1         10000    10000    20/20     100.0%
1:1.07      10000    10700    20/20     100.0%
2:1          5000    10000    20/20     100.0%
1:2         10000     5000    20/20     100.0%
7:1          3000    21000    20/20     100.0%
1:7         21000     3000    20/20     100.0%
3:5          6000    10000    20/20     100.0%
random          -        -    20/20     100.0%
REGRESSION PASS (160 runs)
```

Each run starts the clocks at random phases with independent resets. Traffic switches between burst, sparse, balanced and idle phases in each domain, so full and empty are reached at every ratio. The 1:1.07 ratio sweeps the clock edges through every relative phase.

## Usage

Requires Verilator 5 (`brew install verilator` or `apt install verilator`).

```sh
make lint                                       # verilator -Wall on the RTL, zero warnings
make sim SEED=3 WCLK_PS=5000 RCLK_PS=13000      # one run (omit periods for random ones)
make sim DEFINES=                               # without the metastability model
make waves SEED=3 N=200                         # dumps waves.vcd, opens GTKWave
make regress                                    # 8 ratios x 20 seeds (SEEDS=n to change)
make bug                                        # binary-pointer build; succeeds only if caught
```

## Implementation notes

- **Synthesis constraints:** sync flops carry `ASYNC_REG`. For an FPGA/ASIC flow, also constrain the Gray buses with `set_max_delay -datapath_only` of about one destination period, so bus skew can't exceed one Gray step.
- **Pointers enter synchronizers straight from flops.** There is no combinational logic in front of a synchronizer, because glitches there defeat the Gray guarantee.
- **Not included yet:** almost-full/almost-empty, non-power-of-2 depth, UVM. Add them when a consumer needs them.
