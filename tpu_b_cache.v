// Opt-in N=4 TPU wrapper. A load command (K=1..256) is followed by K B rows;
// then each group of K A columns is one job using that B tile. No A-side last is needed.
// A load or the next job can start after the previous job's last output handshakes.
// Reload has priority at that boundary. Keep q_* fixed until the job retires.
// Invalid K sets sticky err and leaves the cache unchanged. Reset discards all work and B.
`timescale 1ns/1ps
`default_nettype none

module tpu_b_cache #(parameter RAW = 1) (
    input  wire         clk,
    input  wire         rst,
    input  wire         load_valid,
    output wire         load_ready,
    input  wire [8:0]   load_k,
    input  wire         b_valid,
    output wire         b_ready,
    input  wire [31:0]  b_row,
    input  wire         a_valid,
    output wire         a_ready,
    input  wire [31:0]  a_col,
    input  wire [15:0]  q_mult,
    input  wire [4:0]   q_shift,
    input  wire         q_relu,
    output wire         out_valid,
    input  wire         out_ready,
    output wire         out_last,
    output wire [127:0] out_raw,
    output wire [31:0]  out_q,
    output wire         err
);
    reg [31:0] b_mem [0:255];
    reg [7:0] addr, last_addr;
    reg loading, loaded, load_err, drain_pending;
    reg stage_valid, core_last;
    reg [31:0] core_a, core_b;
    // Fabric stage after the RAM read register keeps BRAM clk-to-q off the PE multiplier path.
    reg p_valid, p_last;
    reg [31:0] p_a, p_b;
    wire core_valid = !rst && p_valid;
    wire core_ready, core_err;
    wire p_ready = !p_valid || core_ready;
    wire stage_ready = !stage_valid || p_ready;
    wire at_last = addr == last_addr;
    wire take_load = load_valid && load_ready;
    wire take_b = b_valid && b_ready;
    wire take_a = a_valid && a_ready;

    assign load_ready = !rst && !loading && !drain_pending && addr == 8'd0;
    assign b_ready = !rst && loading;
    assign a_ready = !rst && loaded && !drain_pending && stage_ready && !take_load;
    assign err = load_err || core_err;

    // The enabled synchronous read is the B half of the elastic A/B stage.
    // Read and write cannot coincide; reset invalidates metadata, not the RAM.
    always @(posedge clk) begin
        if (take_b) b_mem[addr] <= b_row;
        if (take_a) core_b <= b_mem[addr];
    end

    always @(posedge clk) begin
        if (rst) begin
            addr        <= 8'd0;
            loading     <= 1'b0;
            loaded      <= 1'b0;
            load_err    <= 1'b0;
            drain_pending <= 1'b0;
            stage_valid <= 1'b0;
            p_valid     <= 1'b0;
        end else begin
            if (out_valid && out_ready && out_last) drain_pending <= 1'b0;
            if (take_a && at_last) drain_pending <= 1'b1;
            if (p_ready) p_valid <= stage_valid;
            if (p_ready && stage_valid) {p_last, p_a, p_b} <= {core_last, core_a, core_b};
            if (stage_ready) stage_valid <= take_a;
            if (take_a) {core_last, core_a} <= {at_last, a_col};
            if (take_load) begin
                if (load_k == 9'd0 || load_k > 9'd256) begin
                    load_err <= 1'b1;
                end else begin
                    last_addr <= load_k[7:0] - 8'd1; // K=256 maps to address 255.
                    loading   <= 1'b1;
                    loaded    <= 1'b0;
                end
            end else if (take_b || take_a) begin
                addr <= at_last ? 8'd0 : addr + 8'd1;
                if (take_b && at_last) begin
                    loading <= 1'b0;
                    loaded  <= 1'b1;
                end
            end
        end
    end

    tpu #(.N(4), .KMAX(256), .RAW(RAW)) core (
        .clk(clk), .rst(rst), .in_valid(core_valid), .in_ready(core_ready), .in_last(p_last),
        .a_col(p_a), .b_row(p_b), .q_mult(q_mult), .q_shift(q_shift), .q_relu(q_relu),
        .out_valid(out_valid), .out_ready(out_ready), .out_last(out_last),
        .out_raw(out_raw), .out_q(out_q), .err(core_err)
    );
endmodule

`default_nettype wire
