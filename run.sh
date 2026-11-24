#!/usr/bin/env bash
# Build + run the testbench. Prefers oss-cad-suite in ~/.local, else system iverilog, else ~/.local/iv.
#   ./run.sh          simulate (Icarus)
#   ./run.sh lint     Verilator lint
#   ./run.sh synth    Yosys synthesis for ECP5 + nextpnr timing
#   ./run.sh formal   SymbiYosys proof of the overflow/collision asserts
# Set N (default 4), RAW=0 or 1 (default 1) and PACKED=0 or 1 (default 0, needs N=4) for sim, lint
# and synth. SEED=n reseeds the simulation (default 1).
set -eo pipefail
cd "$(dirname "$0")"
CAD=~/.local/oss-cad-suite
[ -d "$CAD" ] && export PATH="$CAD/bin:$PATH"
N=${N:-4}
RAW=${RAW-1}
PACKED=${PACKED-0}
SEED=${SEED-1}
if [[ ! $N =~ ^[1-9][0-9]*$ ]]; then echo "N must be a positive integer" >&2; exit 2; fi
if [[ $RAW != 0 && $RAW != 1 ]]; then echo "RAW must be 0 or 1" >&2; exit 2; fi
if [[ $PACKED != 0 && ( $PACKED != 1 || $N != 4 ) ]]; then echo "PACKED must be 0, or 1 with N=4" >&2; exit 2; fi
if [[ ! $SEED =~ ^[0-9]+$ ]]; then echo "SEED must be a non-negative integer" >&2; exit 2; fi
case "${1:-sim}" in
  sim)
    params=(-Ptb_tpu.N="$N" -Ptb_tpu.RAW="$RAW" -Ptb_tpu.PACKED="$PACKED")
    if command -v iverilog >/dev/null; then
        iverilog -Wall "${params[@]}" -o sim tb_tpu.v tpu.v && vvp -n sim +seed="$SEED"
    else
        IV=~/.local/iv/root; LIB=$IV/usr/lib/x86_64-linux-gnu/ivl
        "$IV/usr/bin/iverilog" -B "$LIB" -Wall "${params[@]}" -o sim tb_tpu.v tpu.v && "$IV/usr/bin/vvp" -n -M "$LIB" sim +seed="$SEED"
    fi ;;
  lint)
    verilator --lint-only -Wall -Wno-DECLFILENAME -GN="$N" -GRAW="$RAW" -GPACKED="$PACKED" --top-module tpu tpu.v && echo "lint clean" ;;
  synth)
    yosys -q -p "read_verilog tpu.v; chparam -set N $N -set RAW $RAW -set PACKED $PACKED tpu; synth_ecp5 -top tpu -json tpu.json; tee -o synth.txt stat" >/dev/null
    grep -E 'Number of cells|MULT18X18D|TRELLIS_FF|LUT4|DP16KD|TRELLIS_DPR16X4' synth.txt
    # Benchmark at 200 MHz: report timing misses without treating them as build failures.
    nextpnr-ecp5 --85k --package CABGA381 --json tpu.json --out-of-context --freq 200 --timing-allow-fail >nextpnr.log 2>&1 || {
        status=$?
        tail -30 nextpnr.log >&2
        exit "$status"
    }
    grep 'Max frequency' nextpnr.log | tail -1 ;;
  formal)
    sby -f tpu.sby ;;
esac
