#!/usr/bin/env bash
# Regression: clock-ratio matrix x seeds, metastability model on, 100% coverage required.
# --bug: binary-pointer CDC build; succeeds only if the testbench catches every run.
set -euo pipefail
cd "$(dirname "$0")/.."

SEEDS=${SEEDS:-20}
DEFINES="+define+METASTABILITY"
BUG=0
if [[ ${1:-} == --bug ]]; then BUG=1; DEFINES+=" +define+BUG_BINARY_SYNC"; fi

make -s build DEFINES="$DEFINES"
SIM=$(make -s sim-path DEFINES="$DEFINES")
LOGS=logs/$([[ $BUG == 1 ]] && echo bug || echo regress)
rm -rf "$LOGS"; mkdir -p "$LOGS"

#        name      wclk_ps rclk_ps   (empty periods = seed-random 3..37 ns)
RATIOS=("1:1       10000   10000"
        "1:1.07    10000   10700"
        "2:1       5000    10000"
        "1:2       10000   5000"
        "7:1       3000    21000"
        "1:7       21000   3000"
        "3:5       6000    10000"
        "random    -       -")

printf '%-8s %8s %8s %8s %10s\n' ratio wclk_ps rclk_ps passed coverage
fail=0
for row in "${RATIOS[@]}"; do
  read -r name w r <<<"$row"
  tag=${name//:/to}
  for s in $(seq 1 "$SEEDS"); do
    args=(+SEED="$s" +COV_STRICT)
    [[ $w != - ]] && args+=(+WCLK_PS="$w" +RCLK_PS="$r")
    "$SIM" "${args[@]}" >"$LOGS/${tag}_$s.log" 2>&1 &
  done
  wait || true
  passed=$( (grep -lx PASS "$LOGS/${tag}"_*.log 2>/dev/null || true) | wc -l | tr -d ' ')
  cov=$( (grep -h '^COVERAGE' "$LOGS/${tag}"_*.log 2>/dev/null || true) | awk '{print $2}' | sort -n | head -1)
  printf '%-8s %8s %8s %5s/%-3s %9s\n' "$name" "$w" "$r" "$passed" "$SEEDS" "${cov:-n/a}"
  if [[ $BUG == 0 && $passed != "$SEEDS" ]]; then fail=1; fi
  if [[ $BUG == 1 && $passed != 0 ]]; then fail=1; fi
done

total=$(ls "$LOGS"/*.log | wc -l | tr -d ' ')
if [[ $BUG == 1 ]]; then
  echo "Failure modes detected:"
  grep -ohE 'INCOHERENT CDC|OVERFLOW|UNDERFLOW|MISMATCH|STUCK [A-Z]+|TIMEOUT' "$LOGS"/*.log | sort | uniq -c
  [[ $fail == 0 ]] && echo "BUG DETECTED in $total/$total runs" || { echo "BUG ESCAPED in some runs"; exit 1; }
else
  [[ $fail == 0 ]] && echo "REGRESSION PASS ($total runs)" || { echo "REGRESSION FAIL, see $LOGS/"; grep -L -x PASS "$LOGS"/*.log | head; exit 1; }
fi
