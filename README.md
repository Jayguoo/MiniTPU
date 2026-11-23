# MiniTPU

[![CI](https://github.com/Jayguoo/MiniTPU/actions/workflows/ci.yml/badge.svg)](https://github.com/Jayguoo/MiniTPU/actions/workflows/ci.yml)

A small Verilog systolic-array accelerator for streaming INT8 matrix multiplication.
4×4 by default (parameter `N`), with a self-checking testbench and formally verified flow control.

## Overview

- N×N grid of int8 multiply-accumulate units with exact-width accumulators
- Streaming valid/ready interface, back-to-back jobs, any K from 1 to `KMAX`
- Output: one row of C per beat, raw int32 (`out_raw`) and/or requantized int8 (`out_q`)

## Interface

| Signal | Dir | Meaning |
|---|---|---|
| `in_valid` / `in_ready` | in / out | input handshake |
| `a_col`, `b_row` | in | one beat = column k of A + row k of B (N × int8 each) |
| `in_last` | in | marks the last beat (beat K) of a job |
| `q_mult`, `q_shift`, `q_relu` | in | requantizer settings; change only while no job is in flight |
| `out_valid` / `out_ready` | out / in | output handshake |
| `out_raw` / `out_q` | out | one row of C (N × int32 / N × int8) |
| `out_last` | out | last row of a job |
| `err` | out | sticky: a job exceeded `KMAX` beats; cleared by `rst` |

A job is K input beats ending with `in_last` and produces N output rows ending with `out_last`.

`out_q = saturate_int8(relu?(round(out_raw * q_mult / 2^q_shift)))`

## Architecture

- **Systolic array:** A flows right, B flows down, each processing element (PE) accumulates A×B.
- **Drain / requantizer:** results shift out through a drain chain and are scaled to int8.
- **Output FIFO:** depth `2^ceil(log2(6N+8))`. Job-level credits (`DEPTH/N` jobs) mean
  the array never starts a job the FIFO can't hold.

## Parameters

| Param | Default | Effect |
|---|---|---|
| `N` | 4 | grid size |
| `KMAX` | 256 | longest job (≤ 32768); sets accumulator width |
| `RAW` | 1 | 1 = also output int32; 0 = int8 only (smaller) |

## Running

Needs [oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build) (iverilog, verilator, yosys, nextpnr-ecp5, sby).

```sh
./run.sh sim       # self-checking testbench
./run.sh lint
./run.sh synth     # ECP5-85k, out-of-context
./run.sh formal    # sby: prove_n2, prove_n3, cover_n2
N=8 RAW=0 ./run.sh sim
```

## Verification

- Scoreboard checks every output against a reference model, with random stalls on both ports.
- Sim and lint clean at N = 1, 2, 3, 4, 8 with RAW = 0 and 1.
- Formal: credit and FIFO invariants proven with PDR at N=2 and N=3; cover traces reached.

## Results (N=4, RAW=1, ECP5-85k)

| Metric | Value |
|---|---|
| fmax | 111.84 MHz (target 200 MHz) |
| LUT4 / FF / MULT18 | 3858 / 3013 / 24 |
| Peak | 16 MAC/cycle ≈ 1.79 GMAC/s |
| K=1 stress | 100 jobs in 415 cycles |

## Limitations

- The output port limits short jobs (about 24% utilization at K=1)
- The requantizer multiplier stage is still the critical path; the design misses the 200 MHz target
- No A/B reuse, tiling or on-chip memory
- Int8 only; the requant stage has no other NN features
- Not yet run on hardware or connected to a host

## Next Steps

- [ ] Pipeline the requantizer to reach 200 MHz
- [ ] Wider or packed output port
- [ ] Tiling and on-chip buffers
- [ ] Bring-up on an ECP5 board
