`timescale 1ns/1ps
`default_nettype none

module tb_tpu_b_cache;
    parameter RAW = 1;
    reg clk = 0;
    always #5 clk = ~clk;

    reg rst = 1;
    reg load_valid = 0, b_valid = 0, a_valid = 0, out_ready = 1;
    reg [8:0] load_k = 0;
    reg [31:0] b_row = 0, a_col = 0;
    wire load_ready, b_ready, a_ready, out_valid, out_last, err;
    wire [127:0] out_raw;
    wire [31:0] out_q;
    tpu_b_cache #(.RAW(RAW)) dut (
        .clk(clk), .rst(rst), .load_valid(load_valid), .load_ready(load_ready), .load_k(load_k),
        .b_valid(b_valid), .b_ready(b_ready), .b_row(b_row),
        .a_valid(a_valid), .a_ready(a_ready), .a_col(a_col),
        .q_mult(16'd1), .q_shift(5'd2), .q_relu(1'b0),
        .out_valid(out_valid), .out_ready(out_ready), .out_last(out_last),
        .out_raw(out_raw), .out_q(out_q), .err(err)
    );

    reg base_valid = 0, base_last = 0;
    reg [31:0] base_a = 0, base_b = 0;
    wire base_ready, base_out_valid, base_out_last, base_err;
    wire [127:0] base_raw;
    wire [31:0] base_q;
    tpu #(.N(4), .KMAX(256), .RAW(RAW)) baseline (
        .clk(clk), .rst(rst), .in_valid(base_valid), .in_ready(base_ready), .in_last(base_last),
        .a_col(base_a), .b_row(base_b), .q_mult(16'd1), .q_shift(5'd2), .q_relu(1'b0),
        .out_valid(base_out_valid), .out_ready(1'b1), .out_last(base_out_last),
        .out_raw(base_raw), .out_q(base_q), .err(base_err)
    );

    function integer a_value(input integer row, k);
        a_value = (row == 7) ? (k == 255 ? 4 : 0) : (row*37 + k*53 + row*k*3) % 256 - 128;
    endfunction

    function integer b_value(input integer k, col);
        b_value = (k == 255) ? col + 1 : (k*43 + col*29 + k*col*7) % 251 - 125;
    endfunction

    function [31:0] a_word(input integer row, k);
        integer i, lane;
        begin
            for (i = 0; i < 4; i = i + 1) begin
                lane = a_value(row+i, k);
                a_word[i*8 +: 8] = lane[7:0];
            end
        end
    endfunction

    function [31:0] b_word(input integer k, col);
        integer i, lane;
        begin
            for (i = 0; i < 4; i = i + 1) begin
                lane = b_value(k, col+i);
                b_word[i*8 +: 8] = lane[7:0];
            end
        end
    endfunction

    integer expected [0:511];
    integer queued = 0, rows = 0, base_rows = 0, cycles = 0;
    integer base_bytes = 0, a_bytes = 0, b_bytes = 0, loads = 0;
    integer core_stalls = 0, a_stalls = 0, out_stalls = 0;
    integer first_base = 0, last_base = 0, first_cache = 0, last_cache = 0;
    reg check_bench = 0, allow_err = 0;
    reg held_core = 0, held_out = 0;
    reg [64:0] core_payload;
    reg [160:0] out_payload;

    task expect_job(input integer row, col, depth);
        integer i, j, k, sum;
        begin
            for (i = 0; i < 4; i = i + 1)
                for (j = 0; j < 4; j = j + 1) begin
                    sum = 0;
                    for (k = 0; k < depth; k = k + 1)
                        sum = sum + a_value(row+i, k)*b_value(k, col+j);
                    expected[queued*4 + i*4 + j] = sum;
                end
            queued = queued + 4;
        end
    endtask

    task check_row(input integer ix, input last, input [127:0] raw, input [31:0] quant);
        integer j, want, q;
        begin
            if (ix >= queued || last !== (ix % 4 == 3))
                $fatal(1, "unexpected row %0d or last=%b (queued %0d)", ix, last, queued);
            for (j = 0; j < 4; j = j + 1) begin
                want = expected[ix*4+j];
                q = (want + 2) >>> 2;
                q = (q > 127) ? 127 : (q < -128) ? -128 : q;
                if ($signed(raw[j*32 +: 32]) !== (RAW ? want : 0) || quant[j*8 +: 8] !== q[7:0])
                    $fatal(1, "row %0d lane %0d: raw=%0d want=%0d, quant=%0d want=%0d", ix, j,
                           $signed(raw[j*32 +: 32]), RAW ? want : 0, $signed(quant[j*8 +: 8]), q);
            end
        end
    endtask

    always @(posedge clk) begin
        cycles = cycles + 1;
        if (rst) begin
            rows = 0;
            base_rows = 0;
            held_core = 0;
            held_out = 0;
            if ({load_ready, b_ready, a_ready, out_valid} !== 4'b0)
                $fatal(1, "handshake enabled during reset");
        end else begin
            if ((!allow_err && err !== 1'b0) || base_err !== 1'b0)
                $fatal(1, "unexpected err (wrapper %b, baseline %b)", err, base_err);
            if (held_core && (dut.core_valid !== 1'b1 ||
                {dut.p_last, dut.p_a, dut.p_b} !== core_payload))
                $fatal(1, "staged A/B/last changed while core stalled");
            if (held_out && (out_valid !== 1'b1 || {out_last, out_raw, out_q} !== out_payload))
                $fatal(1, "output changed under backpressure");
            held_core = dut.core_valid && !dut.core_ready;
            held_out = out_valid && !out_ready;
            if (held_core) begin
                core_payload = {dut.p_last, dut.p_a, dut.p_b};
                core_stalls = core_stalls + 1;
            end
            if (held_out) begin
                out_payload = {out_last, out_raw, out_q};
                out_stalls = out_stalls + 1;
            end
            if (a_valid && !a_ready) a_stalls = a_stalls + 1;
            if (check_bench) begin
                if (base_valid && base_ready) begin
                    if (!base_bytes) first_base = cycles;
                    base_bytes = base_bytes + 8;
                end
                if (load_valid && load_ready) begin
                    if (!loads) first_cache = cycles;
                    loads = loads + 1;
                end
                if (b_valid && b_ready) b_bytes = b_bytes + 4;
                if (a_valid && a_ready) a_bytes = a_bytes + 4;
            end
            if (base_out_valid) begin
                check_row(base_rows, base_out_last, base_raw, base_q);
                base_rows = base_rows + 1;
                last_base = cycles;
            end
            if (out_valid && out_ready) begin
                check_row(rows, out_last, out_raw, out_q);
                rows = rows + 1;
                last_cache = cycles;
            end
        end
    end

    // Drive inputs on falling edges; return on the edge after the acceptance.
    task command_load(input [8:0] depth);
        begin
            load_k = depth;
            load_valid = 1;
            @(posedge clk); while (!load_ready) @(posedge clk);
            @(negedge clk); load_valid = 0;
        end
    endtask

    task send_b(input integer depth, col, gaps);
        integer k;
        begin
            for (k = 0; k < depth; k = k + 1) begin
                if (gaps && k % 7 == 3) @(negedge clk);
                b_row = b_word(k, col);
                b_valid = 1;
                @(posedge clk); while (!b_ready) @(posedge clk);
                @(negedge clk); b_valid = 0;
            end
        end
    endtask

    task send_a(input integer depth, row, gaps);
        integer k;
        begin
            for (k = 0; k < depth; k = k + 1) begin
                if (gaps && k % 5 == 2) @(negedge clk);
                a_col = a_word(row, k);
                a_valid = 1;
                @(posedge clk); while (!a_ready) @(posedge clk);
                @(negedge clk); a_valid = 0;
                if (gaps && depth > 1 && k == 0) begin
                    load_valid = 1;
                    @(posedge clk);
                    if (load_ready !== 1'b0) $fatal(1, "accepted reload during partial A job");
                    @(negedge clk); load_valid = 0;
                end
            end
        end
    endtask

    task reset_tpu;
        begin
            rst = 1;
            repeat (2) @(negedge clk);
            queued = 0;
            rst = 0;
            #1;
            if ({a_ready, b_ready, out_valid, err} !== 4'b0 || load_ready !== 1'b1)
                $fatal(1, "reset exposed stale cache, result, or error");
            @(negedge clk);
        end
    endtask

    integer m, n, k, saved_a_stalls, saved_out_stalls;
    initial begin
        @(negedge clk); reset_tpu;
        // An incomplete load must not make B usable, even after reset.
        command_load(9'd5);
        send_b(2, 0, 0);
        if (a_ready !== 1'b0 || load_ready !== 1'b0) $fatal(1, "incomplete B load opened a job/reload");
        reset_tpu;
        repeat (20) @(negedge clk);

        check_bench = 1;
        for (n = 0; n < 8; n = n + 4)
            for (m = 0; m < 32; m = m + 4) begin
                expect_job(m, n, 64);
                for (k = 0; k < 64; k = k + 1) begin
                    base_a = a_word(m, k);
                    base_b = b_word(k, n);
                    base_last = (k == 63);
                    base_valid = 1;
                    @(posedge clk); while (!base_ready) @(posedge clk);
                    @(negedge clk); base_valid = 0;
                end
            end
        while (base_rows != 64) @(negedge clk);
        for (n = 0; n < 8; n = n + 4) begin
            command_load(9'd64);
            send_b(64, n, 0);
            for (m = 0; m < 32; m = m + 4) send_a(64, m, 0);
        end
        while (rows != 64) @(negedge clk);
        check_bench = 0;
        if (base_bytes != 8192 || a_bytes != 4096 || b_bytes != 512 || loads != 2)
            $fatal(1, "operand bytes baseline=%0d cached A=%0d B=%0d; loads=%0d", base_bytes, a_bytes, b_bytes, loads);
        $display("32x64 * 64x8: 256 results checked per design (RAW=%0d)", RAW);
        $display("Operand bytes: %0d -> %0d (A=%0d B=%0d); cycles: %0d -> %0d (includes B loads and drain)",
                 base_bytes, a_bytes+b_bytes, a_bytes, b_bytes, last_base-first_base+1, last_cache-first_cache+1);

        reset_tpu;
        allow_err = 1;
        command_load(9'd0);
        if ({err, a_ready, b_ready, load_ready} !== 4'b1001) $fatal(1, "accepted K=0");
        reset_tpu;
        command_load(9'd257);
        if ({err, a_ready, b_ready, load_ready} !== 4'b1001) $fatal(1, "accepted K=257");
        reset_tpu;
        allow_err = 0;
        command_load(9'd256);
        send_b(256, 4, 1);
        expect_job(0, 4, 256);
        send_a(256, 0, 1);
        expect_job(4, 4, 256);
        fork
            send_a(256, 4, 0);
            begin
                @(posedge clk);
                while (!(out_valid && out_ready && out_last)) begin
                    if ({a_ready, load_ready} !== 2'b00) $fatal(1, "wrapper opened a job before retirement");
                    @(posedge clk);
                end
                if ({a_ready, load_ready} !== 2'b00) $fatal(1, "wrapper opened a job on retirement edge");
            end
            begin
                while (rows != 3) @(negedge clk);
                out_ready = 0;
                saved_a_stalls = a_stalls;
                saved_out_stalls = out_stalls;
                repeat (4) @(negedge clk);
                if (!held_out || !out_last || !a_valid || a_ready || load_ready ||
                    a_stalls <= saved_a_stalls || out_stalls <= saved_out_stalls)
                    $fatal(1, "wrapper accepted work before the stalled last row retired");
                out_ready = 1;
            end
        join
        while (rows != queued) @(negedge clk);
        command_load(9'd1);
        send_b(1, 0, 0);

        out_ready = 0;
        expect_job(0, 0, 1);
        send_a(1, 0, 0);
        while (!out_valid) @(negedge clk);
        out_ready = 1;
        while (rows != queued - 1) @(negedge clk);
        out_ready = 0;
        expect_job(0, 4, 1);
        load_k = 9'd1;
        load_valid = 1;
        a_valid = 1;
        a_col = a_word(0, 0);
        @(posedge clk);
        if ({out_valid, out_last, a_ready, load_ready} !== 4'b1100)
            $fatal(1, "failed to hold reload and A behind the final row");
        @(negedge clk); out_ready = 1;
        @(posedge clk);
        if ({a_ready, load_ready} !== 2'b00) $fatal(1, "work accepted on retirement edge");
        @(posedge clk);
        if ({a_ready, load_ready} !== 2'b01) $fatal(1, "reload did not win over pending A");
        @(negedge clk); load_valid = 0;
        send_b(1, 4, 0);
        @(posedge clk);
        if (a_ready !== 1'b1) $fatal(1, "pending A did not start after reload");
        @(negedge clk); a_valid = 0;
        while (rows != queued) @(negedge clk);

        out_ready = 0;
        expect_job(0, 4, 1);
        send_a(1, 0, 0);
        wait (held_out);
        @(negedge clk); reset_tpu;
        out_ready = 1;
        repeat (20) @(negedge clk);
        command_load(9'd1);
        send_b(1, 4, 0);
        expect_job(0, 4, 1);
        send_a(1, 0, 0);
        while (rows != queued) @(negedge clk);
        repeat (20) @(negedge clk);
        $display("PASS: B-cache bounds, gaps, stalls, reset, reuse and reload");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "timed out (output rows %0d/%0d, baseline %0d)", rows, queued, base_rows);
    end
endmodule

`default_nettype wire
