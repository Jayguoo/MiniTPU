// Self-checking testbench: random int8 matmuls (variable K) vs. a software reference, raw and requantized.
// Phase 0: K=N back-to-back, no stalls (measures utilization). Phases 1-4: random K up to KMAX, input
// stalls, output backpressure, random q_*. Then: reset mid-job, reset with results in flight,
// a 1000-cycle pause inside a job, the KMAX overflow err flag, no spurious output, and K=1 throughput.
`timescale 1ns/1ps
module tb_tpu;
    parameter N = 4, KMAX = 256, TRIALS = 100, RAW = 1;
    localparam MEM = 1 << 21, MAXJ = 1024;
    localparam FIFO_JOBS = (1 << $clog2(6*N + 8)) / N;

    reg clk = 0, rst = 1, in_valid = 0, in_last = 0, out_ready = 1, q_relu = 0;
    reg  [N*8-1:0]  a_col = 0, b_row = 0;
    reg  [15:0]     q_mult = 1;
    reg  [4:0]      q_shift = 0;
    wire            in_ready, out_valid, out_last, err;
    wire [N*32-1:0] out_raw;
    wire [N*8-1:0]  out_q;

    tpu #(.N(N), .KMAX(KMAX), .RAW(RAW)) dut (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in_ready(in_ready), .in_last(in_last),
        .a_col(a_col), .b_row(b_row), .q_mult(q_mult), .q_shift(q_shift), .q_relu(q_relu),
        .out_valid(out_valid), .out_ready(out_ready), .out_last(out_last),
        .out_raw(out_raw), .out_q(out_q), .err(err));
    always #5 clk = ~clk;

    // Job j: A[i][k] = M[off+i*K+k], B[k][c] = M[off+N*K+k*N+c]. Jobs are numbered in commit order.
    reg [7:0] M [0:MEM-1];
    integer K [0:MAXJ-1], off [0:MAXJ-1];
    integer nj = 0, rx_job = 0, rx_row = 0, stall = 0, bp = 100, err_ok = 0;
    integer ph, t, kk, t0, t_end, cycles;
    integer backpressure_cycles = 0;
    reg held = 0;
    reg [N*40:0] held_row;

    always @(posedge clk) begin
        if (!rst && in_valid && !in_ready) backpressure_cycles <= backpressure_cycles + 1;
        if (held && !rst && (!out_valid || {out_last, out_raw, out_q} !== held_row))
            $fatal(1, "output changed while stalled");
        held <= !rst && out_valid && !out_ready;
        if (out_valid && !out_ready) held_row <= {out_last, out_raw, out_q};
    end

    always @(posedge clk) out_ready <= ($urandom % 100) < bp;

    task gen(input integer k, input integer mode);   // mode 1: 127 * -128, mode 2: -128 * -128
        integer x;
        begin
            K[nj]   = k;
            off[nj] = (nj == 0) ? 0 : off[nj-1] + 2*N*K[nj-1];
            for (x = 0; x < 2*N*k; x = x + 1)
                M[off[nj] + x] = (mode == 0) ? $urandom : (mode == 1 && x < N*k) ? 8'h7f : 8'h80;
        end
    endtask

    task beats(input integer k0, input integer k1);   // send beats k0..k1-1 of job nj
        integer k, i;
        begin
            for (k = k0; k < k1; k = k + 1) begin
                while (($urandom % 100) < stall) begin in_valid = 0; @(negedge clk); end
                in_valid = 1;
                in_last  = (k == K[nj] - 1);
                for (i = 0; i < N; i = i + 1) begin
                    a_col[i*8 +: 8] = M[off[nj] + i*K[nj] + k];
                    b_row[i*8 +: 8] = M[off[nj] + N*K[nj] + k*N + i];
                end
                #1;
                while (in_ready !== 1'b1) begin
                    if (in_ready === 1'bx) $fatal(1, "X on in_ready");
                    @(negedge clk); #1;
                end
                @(negedge clk);                       // accepted on the posedge in between
            end
            in_valid = 0;
            in_last  = 0;
        end
    endtask

    task job(input integer k, input integer mode);
        begin gen(k, mode); beats(0, k); nj = nj + 1; end
    endtask

    task reset_tpu;
        begin rst = 1; repeat (2) @(negedge clk); rst = 0; end
    endtask

    function signed [63:0] cref(input integer jb, input integer r, input integer c);
        integer k;
        begin
            cref = 0;
            for (k = 0; k < K[jb]; k = k + 1)
                cref = cref + $signed(M[off[jb] + r*K[jb] + k]) * $signed(M[off[jb] + N*K[jb] + k*N + c]);
        end
    endfunction

    function [7:0] qref(input signed [63:0] raw);
        reg signed [63:0] p;
        begin
            p = raw * $signed({48'd0, q_mult});
            if (q_shift != 0) p = p + (64'sd1 <<< (q_shift - 1));
            p = p >>> q_shift;
            if (q_relu && p < 0) p = 0;
            qref = (p > 127) ? 8'h7f : (p < -128) ? 8'h80 : p[7:0];
        end
    endfunction

    // Everything is stable on the falling edge; a pop happens on the next rising edge.
    integer c;
    reg signed [63:0] ev;
    always @(negedge clk) if (!rst) begin
        if (out_valid === 1'bx || err === 1'bx) $fatal(1, "X on out_valid/err");
        if (err === 1'b1 && !err_ok)            $fatal(1, "unexpected err");
        if (out_valid && out_ready) begin
            if (rx_job >= nj) $fatal(1, "spurious output row at %0t", $time);
            if (out_last !== (rx_row == N-1))
                $fatal(1, "job %0d row %0d: out_last=%b", rx_job, rx_row, out_last);
            if (!RAW && out_raw !== {N*32{1'b0}})
                $fatal(1, "RAW=0 job %0d row %0d: expected zero out_raw, got %h", rx_job, rx_row, out_raw);
            for (c = 0; c < N; c = c + 1) begin
                ev = cref(rx_job, rx_row, c);
                if (out_q[c*8 +: 8] !== qref(ev))
                    $fatal(1, "out_q mismatch job %0d C[%0d][%0d]: got %0d, expected %0d",
                           rx_job, rx_row, c, $signed(out_q[c*8 +: 8]), $signed(qref(ev)));
                if (RAW && $signed(out_raw[c*32 +: 32]) !== ev)
                    $fatal(1, "out_raw mismatch job %0d C[%0d][%0d]: got %0d, expected %0d",
                           rx_job, rx_row, c, $signed(out_raw[c*32 +: 32]), ev);
            end
            rx_row = rx_row + 1;
            if (rx_row == N) begin
                rx_row = 0;
                rx_job = rx_job + 1;
                if (rx_job == TRIALS) t_end = $time;
            end
        end
    end

    initial begin
        repeat (3) @(negedge clk);
        rst = 0;

        // Phase 0: full-rate stream, K = N.
        t0 = $time;
        for (t = 0; t < TRIALS; t = t + 1) job(N, t == 0);
        wait (rx_job == nj); @(negedge clk);
        cycles = (t_end - t0) / 10;

        // Phases 1-4: variable K, stalls, backpressure, requantization.
        for (ph = 1; ph <= 4; ph = ph + 1) begin
            q_mult  = (ph == 1) ? 16'd1 : $urandom;
            q_shift = (ph == 1) ? 5'd0  : (ph == 4) ? 5'd31 : 8 + $urandom % 16;
            q_relu  = ph[0];
            stall   = 25;
            bp      = (ph % 2) ? 50 : 90;
            job(KMAX, (ph == 1) ? 2 : (ph == 2) ? 1 : 0);
            for (t = 0; t < TRIALS/2; t = t + 1) begin
                kk = ($urandom % 10 == 0) ? 1 + $urandom % KMAX : 1 + $urandom % (3*N);
                job(kk, 0);
            end
            wait (rx_job == nj && !out_valid); @(negedge clk);
        end
        $display("Random stalls: %0d input backpressure cycles", backpressure_cycles);
        stall = 0;
        bp    = 0;
        @(negedge clk);

        // Fill all job slots with the output stopped, then release one row at a time.
        for (t = 0; t < FIFO_JOBS; t = t + 1) job(N, 0);
        gen(1, 0);
        in_valid = 1;
        in_last  = 1;
        for (t = 0; t < N; t = t + 1) begin
            a_col[t*8 +: 8] = M[off[nj] + t];
            b_row[t*8 +: 8] = M[off[nj] + N + t];
        end
        repeat (4*N + 8) begin
            @(posedge clk);
            if (in_ready !== 1'b0) $fatal(1, "accepted a job with all slots reserved");
        end
        @(negedge clk);
        bp = 100;
        for (t = 0; t < N; t = t + 1) begin
            @(posedge clk);
            while (!out_ready) @(posedge clk);
            if (out_valid !== 1'b1 || in_ready !== 1'b0)
                $fatal(1, "credit returned before the final row was consumed (row %0d)", t);
        end
        @(posedge clk);
        if (in_ready !== 1'b1) $fatal(1, "credit not returned after the final row");
        @(negedge clk);
        in_valid = 0;
        in_last  = 0;
        nj = nj + 1;
        wait (rx_job == nj); @(negedge clk);

        // Reset mid-job: the partial job must vanish.
        gen(2*N, 0); beats(0, N); reset_tpu;
        job(N, 0);
        wait (rx_job == nj); @(negedge clk);

        // Reset while results are draining: they must vanish too.
        job(N, 0);
        repeat (N + 2) @(negedge clk);
        reset_tpu;
        nj = rx_job; rx_row = 0;
        job(N, 0);

        // Long pause in the middle of a job.
        gen(2*N, 0); beats(0, N); repeat (1000) @(negedge clk); beats(N, 2*N); nj = nj + 1;
        wait (rx_job == nj); @(negedge clk);

        // A job longer than KMAX sets err; reset clears it.
        err_ok = 1;
        gen(KMAX + 1, 0); beats(0, KMAX + 1);
        if (err !== 1'b1) $fatal(1, "err not set after %0d beats", KMAX + 1);
        reset_tpu;
        err_ok = 0;
        if (err !== 1'b0) $fatal(1, "err not cleared by rst");

        repeat (10*N + 50) @(negedge clk);           // anything popping now is spurious

        $display("N=%0d streaming K=N: %0d jobs in %0d cycles -> %0.1f%% MAC utilization",
                 N, TRIALS, cycles, 100.0*TRIALS*N/cycles);

        // K=1 only, no external stalls. Count from first input through the last output pop.
        q_mult = 1; q_shift = 7; q_relu = 0;
        t0 = $time;
        for (t = 0; t < TRIALS; t = t + 1) job(1, 0);
        wait (rx_job == nj); @(negedge clk);
        cycles = ($time - t0) / 10;
        $display("N=%0d RAW=%0d streaming K=1: %0d jobs in %0d cycles -> %0.1f%% MAC utilization",
                 N, RAW, TRIALS, cycles, 100.0*TRIALS/cycles);
        repeat (10*N + 50) @(negedge clk);           // catch any extra rows after the benchmark
        $display("PASS: %0d %0dx%0d matmuls (RAW=%0d)", rx_job, N, N, RAW);
        $finish;
    end

    initial begin #200000000; $fatal(1, "FAIL: timeout (%0d/%0d jobs)", rx_job, nj); end
endmodule
