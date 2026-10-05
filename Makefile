# AsyncFifoCore: Verilator 5 flow
SEED    ?= 1
WCLK_PS ?=
RCLK_PS ?=
N       ?= 5000
DEFINES ?= +define+METASTABILITY

RTL  := rtl/sync_2ff.sv rtl/async_fifo.sv
TB   := tb/tb_async_fifo.sv
VFLAGS := --binary --timing --assert --timescale 1ps/1ps -j 0 \
          -Wno-fatal -Wno-ZERODLY -Wno-UNUSEDSIGNAL --top-module tb_async_fifo \
          -CFLAGS -Wno-unknown-warning-option
space := $() $()
BUILD = obj_dir/build$(subst +define+,_,$(subst $(space),,$(DEFINES)))$(TRACE)
SIM   = $(BUILD)/Vtb_async_fifo
ARGS  = +SEED=$(SEED) +N=$(N) $(if $(WCLK_PS),+WCLK_PS=$(WCLK_PS)) $(if $(RCLK_PS),+RCLK_PS=$(RCLK_PS))

.PHONY: lint build sim sim-path waves regress bug clean

lint:
	verilator --lint-only -Wall $(RTL) --top-module async_fifo
	verilator --lint-only -Wall +define+METASTABILITY $(RTL) --top-module async_fifo

build:
	@mkdir -p $(BUILD)
	verilator $(VFLAGS) $(DEFINES) $(if $(TRACE),--trace +define+TRACE) -Mdir $(BUILD) $(RTL) $(TB) >/dev/null

sim: build
	$(SIM) $(ARGS) $(PLUSARGS)

sim-path:
	@echo $(SIM)

waves:
	$(MAKE) sim TRACE=_trace
	gtkwave waves.vcd &

regress:
	./scripts/regress.sh

# Bug injection: binary pointers across the CDC boundary. Passes only if the TB catches it.
bug:
	./scripts/regress.sh --bug

clean:
	rm -rf obj_dir logs waves.vcd
