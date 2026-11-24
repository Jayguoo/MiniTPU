// MiniTPU: NxN output-stationary systolic array streaming C = A * B (int8 in; int32 and int8 out).
//
// Input stream (valid/ready): one beat carries column k of A (a_col[i] = A[i][k]) and row k of B
// (b_row[j] = B[k][j]). A job is K beats, 1 <= K <= KMAX, ended by in_last; jobs run back-to-back.
// in_ready depends on in_last: a job's last beat waits until N cycles (2 with PACKED=1) after the
// previous job's last beat and until a FIFO job slot is free. The slot is released on out_last pop.
// Other beats are always accepted.
// Output stream (valid/ready): by default one row per beat, rows 0..N-1 in order.
// PACKED=1 (N=4 only) emits (0,2) then (1,3) with the first row in the low bits of both outputs.
// Within a row, column 0 is in the low bits. out_last marks the job's final beat.
// out_raw is the exact result (tied to zero when RAW=0); the FIFO stores only out_q when RAW=0.
// out_q = int8 saturate(ReLU?(round(raw * q_mult / 2^q_shift))).
// Change q_* only while no job is in flight. err is sticky: a job exceeded KMAX beats (its result
// is undefined); cleared by rst. KMAX <= 32768.
`timescale 1ns/1ps
`default_nettype none

module pe #(parameter W = 24) (
    input  wire                clk,
    input  wire                rst,
    input  wire                v_in, f_in, l_in,     // valid, first beat, last beat of a job
    input  wire signed [7:0]   a_in, b_in,
    output reg                 v_out, f_out, l_out,
    output reg  signed [7:0]   a_out, b_out,
    input  wire                dv_in,                // result drain chain, from the PE above
    input  wire        [W-1:0] d_in,
    output reg                 dv_out,
    output reg         [W-1:0] d_out
);
    reg                 v1, f1, l1, dv0;
    reg  signed [15:0]  prod;
    reg  signed [W-1:0] acc;
    reg         [W-1:0] d0;
    wire signed [W-1:0] base = f1 ? {W{1'b0}} : acc;   // first beat restarts the sum
    wire signed [W-1:0] sum  = base + {{(W-16){prod[15]}}, prod};
    wire                cap  = v1 & l1;                // job finished here: move result to drain

    always @(posedge clk) begin
        v_out  <= v_in & ~rst;
        v1     <= v_in & ~rst;
        dv0    <= (cap | dv_in) & ~rst;
        dv_out <= dv0 & ~rst;
        if (v_in) begin                                // data registers hold while idle
            {f_out, l_out, a_out, b_out} <= {f_in, l_in, a_in, b_in};
            {f1, l1} <= {f_in, l_in};
            prod     <= a_in * b_in;                   // stage 1: multiply
        end
        if (v1)          acc   <= sum;                 // stage 2: accumulate
        if (cap | dv_in) d0    <= cap ? sum : d_in;
        if (dv0)         d_out <= d0;
    end

`ifdef FORMAL
    // A result entering the drain never lands on one still passing through.
    always @(posedge clk) if (!rst) assert (!(cap && dv_in));
`endif
endmodule

module tpu #(
    parameter N    = 4,
    parameter KMAX = 256,
    parameter RAW  = 1,
    parameter integer PACKED = 0
) (
    input  wire            clk,
    input  wire            rst,
    input  wire            in_valid,
    output wire            in_ready,
    input  wire            in_last,
    input  wire [N*8-1:0]  a_col,
    input  wire [N*8-1:0]  b_row,
    input  wire [15:0]     q_mult,
    input  wire [4:0]      q_shift,
    input  wire            q_relu,
    output wire            out_valid,
    input  wire            out_ready,
    output wire            out_last,
    output wire [N*(PACKED != 0 ? 2 : 1)*32-1:0] out_raw,
    output wire [N*(PACKED != 0 ? 2 : 1)*8-1:0]  out_q,
    output reg             err
);
    localparam W     = 16 + $clog2(KMAX);      // exact width of a KMAX-term int8 dot product
    localparam LANES = PACKED != 0 ? 2 : 1;
    localparam COLS  = N * LANES;
    localparam NB    = N / LANES;              // output beats per job, also minimum commit spacing
    localparam DEPTH = (1 << $clog2(6*N + 8)) / LANES; // same number of reserved jobs in either mode
    localparam AW    = $clog2(DEPTH);
    localparam KW    = $clog2(KMAX + 1);
    localparam GW    = $clog2(NB + 1);
    localparam RW    = (NB > 1) ? $clog2(NB) : 1;
    localparam JOBS  = DEPTH / NB;
    localparam JW    = $clog2(JOBS + 1);
    /* verilator lint_off WIDTHTRUNC */        // sized copies of constants that fit by construction
    localparam [JW-1:0] CAPACITY = JOBS;
    localparam [KW-1:0] KM   = KMAX;
    localparam [GW-1:0] NG   = NB;
    localparam [RW-1:0] LAST = NB - 1;
    /* verilator lint_on WIDTHTRUNC */

    // synthesis translate_off
    initial if (PACKED != 0 && (PACKED != 1 || N != 4))
        $fatal(1, "PACKED must be 0, or 1 with N=4");
    // synthesis translate_on

    // ---------------- input control ----------------
    reg  [KW-1:0] beats;      // beats accepted in the current job
    reg  [GW-1:0] since;      // cycles since the previous last beat, saturating at NB
    reg  [JW-1:0] jobs_used;
    wire          pop     = out_valid & out_ready;
    wire          retire  = pop & out_last;
    wire          last_ok = (since == NG) && (jobs_used < CAPACITY);
    assign in_ready = ~rst & (~in_last | last_ok);
    wire          go      = in_valid & in_ready;
    wire          commit  = go & in_last;

    always @(posedge clk)
        if (rst) begin
            beats    <= {KW{1'b0}};
            since    <= NG;
            jobs_used <= {JW{1'b0}};
            err      <= 1'b0;
        end else begin
            if (go) begin
                if (beats == KM)      err   <= 1'b1;
                if (in_last)          beats <= {KW{1'b0}};
                else if (beats != KM) beats <= beats + 1'b1;
            end
            if (commit)           since <= {{(GW-1){1'b0}}, 1'b1};
            else if (since != NG) since <= since + 1'b1;
            case ({commit, retire})
                2'b10: jobs_used <= jobs_used + 1'b1;
                2'b01: jobs_used <= jobs_used - 1'b1;
                default: ;
            endcase
        end

    // ---------------- systolic array ----------------
    // a + tags flow right, b flows down. Legacy physical rows compute C rows N-1..0.
    // Packed mode splits the drain into two chains and emits two rows per beat.
    /* verilator lint_off UNUSEDSIGNAL */
    wire         v_h [0:N-1][0:N];
    wire         f_h [0:N-1][0:N];
    wire         l_h [0:N-1][0:N];
    wire [7:0]   a_h [0:N-1][0:N];
    wire [7:0]   b_v [0:N][0:N-1];
    /* verilator lint_on UNUSEDSIGNAL */
    wire         dv  [0:N][0:N-1];
    wire [W-1:0] dd  [0:N][0:N-1];
    wire [2:0]   tag [0:N-1];                  // {valid, first, last} delayed by its index
    assign tag[0] = {go, beats == {KW{1'b0}}, in_last};

    wire [COLS*W-1:0] row_raw;
    wire [COLS-1:0]   row_v;
    wire [COLS*8-1:0] q8;
    wire              aligned_v = row_v[N-1];
    reg            s1v, s2v, s3v, s4v;         // requantizer pipeline valids
    wire [W+17:0]  rnd = (q_shift == 5'd0) ? {(W+18){1'b0}}
                                           : {{(W+17){1'b0}}, 1'b1} << (q_shift - 5'd1);

    genvar r, j, k;
    generate
        for (k = 1; k < N; k = k + 1) begin : tdly
            reg [2:0] t;
            always @(posedge clk) begin
                t[2] <= tag[k-1][2] & ~rst;
                if (tag[k-1][2]) t[1:0] <= tag[k-1][1:0];
            end
            assign tag[k] = t;
        end

        // Input skew: row r and column r are delayed r cycles so operands meet on the wavefront.
        for (r = 0; r < N; r = r + 1) begin : skew
            wire [7:0] as [0:r];
            wire [7:0] bs [0:r];
            localparam C_ROW = N-1-r;
            assign as[0] = a_col[C_ROW*8 +: 8];
            assign bs[0] = b_row[r*8 +: 8];
            for (k = 1; k <= r; k = k + 1) begin : st
                reg [7:0] ar, br;
                always @(posedge clk) if (tag[k-1][2]) begin
                    ar <= as[k-1];
                    br <= bs[k-1];
                end
                assign as[k] = ar;
                assign bs[k] = br;
            end
            assign {v_h[r][0], f_h[r][0], l_h[r][0]} = tag[r];
            assign a_h[r][0] = as[r];
            assign b_v[0][r] = bs[r];
            assign dv[0][r]  = 1'b0;
            assign dd[0][r]  = {W{1'b0}};
        end

        for (r = 0; r < N; r = r + 1) begin : row
            for (j = 0; j < N; j = j + 1) begin : col
                wire         drain_v;
                wire [W-1:0] drain_d;
                if (PACKED != 0 && r == 2) begin : split
                    assign drain_v = 1'b0;
                    assign drain_d = {W{1'b0}};
                end else begin : chain
                    assign drain_v = dv[r][j];
                    assign drain_d = dd[r][j];
                end
                pe #(.W(W)) u_pe (
                    .clk(clk), .rst(rst),
                    .v_in(v_h[r][j]), .f_in(f_h[r][j]), .l_in(l_h[r][j]),
                    .a_in(a_h[r][j]), .b_in(b_v[r][j]),
                    .v_out(v_h[r][j+1]), .f_out(f_h[r][j+1]), .l_out(l_h[r][j+1]),
                    .a_out(a_h[r][j+1]), .b_out(b_v[r+1][j]),
                    .dv_in(drain_v), .d_in(drain_d),
                    .dv_out(dv[r+1][j]), .d_out(dd[r+1][j])
                );
            end
        end

        // Output deskew: column j leaves the array j cycles late; delay it N-1-j more.
        for (j = 0; j < N; j = j + 1) begin : dsk
            wire         sv [0:N-1-j];
            wire [W-1:0] sd [0:N-1-j];
            assign sv[0] = dv[N][j];
            assign sd[0] = dd[N][j];
            for (k = 1; k <= N-1-j; k = k + 1) begin : st
                reg         v;
                reg [W-1:0] d;
                always @(posedge clk) begin
                    v <= sv[k-1] & ~rst;
                    if (sv[k-1]) d <= sd[k-1];
                end
                assign sv[k] = v;
                assign sd[k] = d;
            end
            assign row_v[j]          = sv[N-1-j];
            assign row_raw[j*W +: W] = sd[N-1-j];

            if (PACKED != 0) begin : upper_lane
                // The upper chain ends two physical rows earlier; deskew those cycles as well.
                localparam DELAY = N-1-j + 2;
                wire         uv [0:DELAY];
                wire [W-1:0] ud [0:DELAY];
                assign uv[0] = dv[2][j];
                assign ud[0] = dd[2][j];
                for (k = 1; k <= DELAY; k = k + 1) begin : st
                    reg         v;
                    reg [W-1:0] d;
                    always @(posedge clk) begin
                        v <= uv[k-1] & ~rst;
                        if (uv[k-1]) d <= ud[k-1];
                    end
                    assign uv[k] = v;
                    assign ud[k] = d;
                end
                assign row_v[N+j]          = uv[DELAY];
                assign row_raw[(N+j)*W +: W] = ud[DELAY];
            end
        end

        // Requantize to int8, pipelined: register x | two partial products (x low 12 bits, x high
        // bits) | sum | round + shift | ReLU + saturate (in the FIFO register). Splitting the
        // multiply keeps the partial-product add out of the DSP cycle.
        for (j = 0; j < COLS; j = j + 1) begin : quant
            wire signed [W-1:0]  x = row_raw[j*W +: W];
            reg  signed [W-1:0]  xr;
            reg         [27:0]   pl;               // x[11:0] * q_mult, unsigned
            reg  signed [W+5:0]  ph;               // x[W-1:12] * q_mult, signed
            reg  signed [W+17:0] p, y;
            wire signed [W+17:0] ph_shifted = {ph, 12'b0};
            always @(posedge clk) begin
                if (aligned_v) xr <= x;
                if (s1v) begin
                    pl <= xr[11:0] * q_mult;
                    ph <= $signed(xr[W-1:12]) * $signed({1'b0, q_mult});
                end
                if (s2v)        p <= ph_shifted + $signed({{(W-10){1'b0}}, pl});
                if (s3v)        y <= (p + $signed(rnd)) >>> q_shift;
            end
            wire signed [W+17:0] z = (q_relu && y < 0) ? 0 : y;
            assign q8[j*8 +: 8] = (z > 127) ? 8'h7f : (z < -128) ? 8'h80 : z[7:0];
        end
    endgenerate

    // ---------------- output FIFO ----------------
    localparam EW = COLS * (8 + (RAW ? W : 0));
    reg            qv;
    reg [COLS*8-1:0] qq;
    wire [EW-1:0]  entry;
    always @(posedge clk) begin
        s1v <= aligned_v & ~rst;
        s2v <= s1v & ~rst;
        s3v <= s2v & ~rst;
        s4v <= s3v & ~rst;
        qv  <= s4v & ~rst;
        if (s4v) qq <= q8;
    end

    reg  [EW-1:0] mem [0:DEPTH-1];
    reg  [AW:0]   wp, rp;
    reg  [RW-1:0] orow;
    always @(posedge clk) if (qv) mem[wp[AW-1:0]] <= entry;
    always @(posedge clk)
        if (rst) begin
            wp   <= {(AW+1){1'b0}};
            rp   <= {(AW+1){1'b0}};
            orow <= {RW{1'b0}};
        end else begin
            if (qv) wp <= wp + 1'b1;
            if (pop) begin
                rp   <= rp + 1'b1;
                orow <= out_last ? {RW{1'b0}} : orow + 1'b1;
            end
        end

    wire [EW-1:0] head = mem[rp[AW-1:0]];
    assign out_valid = ~rst & (wp != rp);
    assign out_last  = (orow == LAST);
    assign out_q     = head[EW-1 -: COLS*8];
    generate
        if (RAW) begin : raw
            reg [COLS*W-1:0] qraw, raw1, raw2, raw3, raw4;
            always @(posedge clk) begin
                if (aligned_v) raw1 <= row_raw;
                if (s1v)        raw2 <= raw1;
                if (s2v)        raw3 <= raw2;
                if (s3v)        raw4 <= raw3;
                if (s4v)        qraw <= raw4;
            end
            assign entry = {qq, qraw};
            for (j = 0; j < COLS; j = j + 1) begin : outp
                wire [W-1:0] o = head[j*W +: W];
                assign out_raw[j*32 +: 32] = {{(32-W){o[W-1]}}, o};
            end
        end else begin : q_only
            assign entry   = qq;
            assign out_raw = {COLS*32{1'b0}};
        end
    endgenerate

`ifdef FORMAL
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (rst);

    wire [AW:0] occupancy = wp - rp;
    wire [31:0] slot_rows = jobs_used * NB;
    wire [31:0] queued_rows = {{(31-AW){1'b0}}, occupancy};
    wire [31:0] read_rows = {{(32-RW){1'b0}}, orow};
    reg  [31:0] inflight;
    always @(posedge clk)
        if (rst) inflight <= 0;
        else     inflight <= inflight + (commit ? NB : 0) - (qv ? 32'd1 : 32'd0);

    always @(posedge clk) if (!rst) begin
        assert (row_v == {COLS{row_v[N-1]}});
        assert (jobs_used <= CAPACITY);
        assert (!retire || jobs_used != 0);
        assert (queued_rows + read_rows <= slot_rows);
        assert (inflight <= DEPTH);
        assert (slot_rows == queued_rows + read_rows + inflight);
        assert (!qv || occupancy < DEPTH);
        cover (jobs_used == CAPACITY);
        cover (commit && retire);
        cover (jobs_used == CAPACITY && in_valid && in_last && !in_ready);
    end
`endif
endmodule

`default_nettype wire
