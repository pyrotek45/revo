const std = @import("std");

const revo = @import("revo");
const diagnostic = revo.lang.diagnostic;
const Span = revo.lang.ast.Span;

pub const NativeError = error{
    StackUnderflow,
    KeyDNE,
    StackOverflow,
    InvalidConstant,
    InvalidLocal,
    ConstantReassignment,
    WrongArity,
    TypeError,
    IncompatibleTypes,
    DivisionByZero,
    UndefinedVariable,
    NotAFunction,
    FrameUnderflow,
    PickedFromVoid,
    FunctionDNE,
    InvalidTable,
    InvalidTuple,
    ProgramEnd,
    Panic,
    AssertionFailed,
    OutOfMemory,
    mystery,
    ModuleNotFound,
    IoError,
    CyclicImport,
    ImportFailed,
    InvalidChannel,
    Parked,
    InvalidBytecode,
};

pub const EvalErrorKind = enum {
    StackUnderflow,
    StackOverflow,
    InvalidConstant,
    InvalidLocal,
    TypeError,
    IncompatibleTypes,
    DivisionByZero,
    UndefinedVariable,
    NotAFunction,
    WrongArity,
    FrameUnderflow,
    PickedFromVoid,
    FunctionDNE,
    KeyDNE,
    InvalidTable,
    InvalidTuple,
    Panic,
    OutOfMemory,
    ConstantReassignment,
    ProgramEnd,
    AssertionFailed,
    ModuleNotFound,
    IoError,
    CyclicImport,
    ImportFailed,
    InvalidChannel,
    Parked,
    InvalidBytecode,
    mystery,

    // it would be really cool if i could do this at comptime
    pub fn message(self: EvalErrorKind) []const u8 {
        return switch (self) {
            .StackUnderflow => "stack underflow!",
            .StackOverflow => "stack overflow!",
            .InvalidConstant => "invalid constant!",
            .InvalidLocal => "invalid local!",
            .TypeError => "type error!",
            .IncompatibleTypes => "incompatible types!",
            .DivisionByZero => "division by zero!",
            .UndefinedVariable => "undefined variable!",
            .NotAFunction => "value is not a function!",
            .WrongArity => "wrong arity!",
            .FrameUnderflow => "frame underflow!",
            .PickedFromVoid => "picked from void!",
            .FunctionDNE => "function dne!",
            .InvalidTable => "invalid table!",
            .InvalidTuple => "invalid tuple!",
            .Panic => "panic!!",
            .KeyDNE => "key does not exist!",
            .OutOfMemory => "out of memory!",
            .ConstantReassignment => "reassignment to constant!",
            .ProgramEnd => "program end!",
            .AssertionFailed => "assertion failed!",
            .ModuleNotFound => "module not found!",
            .IoError => "io error!",
            .CyclicImport => "cyclic import!",
            .ImportFailed => "import failed!",
            .InvalidChannel => "invalid channel!",
            .Parked => "fiber parked!",
            .InvalidBytecode => "invalid bytecode!",
            .mystery => "mystery!",
        };
    }
};

pub const EvalFailure = struct {
    pub const max_trace_frames = 64;

    pub const TraceFrame = struct {
        function_name: []const u8,
        source_name: ?[]const u8 = null,
        source: ?[]const u8 = null,
        span: ?Span = null,
        pc: ?usize = null,

        pub fn empty() TraceFrame {
            return .{
                .function_name = "",
                .source_name = null,
                .source = null,
                .span = null,
                .pc = null,
            };
        }
    };

    kind: EvalErrorKind,
    span: ?Span,
    message: []const u8,
    source: ?[]const u8 = null,
    source_name: ?[]const u8 = null,
    trace_len: usize = 0,
    trace: [max_trace_frames]TraceFrame = [_]TraceFrame{TraceFrame.empty()} ** max_trace_frames,

    pub fn render(self: EvalFailure, alloc: std.mem.Allocator, writer: *std.Io.Writer, source: []const u8) !void {
        return self.renderAt(alloc, writer, self.source_name orelse "<source>", self.source orelse source);
    }

    pub fn renderAt(self: EvalFailure, alloc: std.mem.Allocator, writer: *std.Io.Writer, source_name: []const u8, source: []const u8) !void {
        try diagnostic.renderAt(alloc, writer, source_name, source, self.span, self.message, &.{}, &.{});
        if (self.trace_len == 0) return;

        try writer.writeAll("\nstack trace:\n");
        for (self.trace[0..self.trace_len], 0..) |frame, idx| {
            const frame_source = frame.source_name orelse "<source>";
            try writer.print("  {d}: {s}", .{ idx, frame.function_name });
            if (frame.span) |span| {
                try writer.print(" at {s}:{d}:{d}", .{ frame_source, span.line, span.column });
            } else if (frame.pc) |pc| {
                try writer.print(" at {s}:pc={d}", .{ frame_source, pc });
            } else {
                try writer.print(" at {s}", .{frame_source});
            }
            try writer.writeByte('\n');
        }
    }
};

pub const EvalResult = union(enum) {
    ok,
    err: EvalFailure,
};

pub fn printDisassembly(artifact: revo.lang.Artifact, source: []const u8) void {
    std.debug.print(
        \\ pc  op                a  b  c    bx    src
        \\ --  ----------------  -  -  ---  ---  ---------
        \\
    , .{});

    for (artifact.instructions, 0..) |instr, pc| {
        const span = if (pc < artifact.spans.len)
            artifact.spans[pc]
        else
            revo.lang.Span{ .start = 0, .end = 0, .line = 0, .column = 0 };

        const op_name = @tagName(instr.op);

        var span_buf: [80]u8 = undefined;
        const span_text = blk: {
            if (source.len == 0 or span.start >= source.len) break :blk "";
            const end = @min(span.end, source.len);
            if (end <= span.start) break :blk "";
            const raw = source[span.start..end];
            var out_idx: usize = 0;
            var in_ws = false;
            for (raw) |ch| {
                const is_ws = ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
                if (out_idx >= span_buf.len - 1) break;
                if (is_ws) {
                    if (!in_ws) {
                        span_buf[out_idx] = ' ';
                        out_idx += 1;
                        in_ws = true;
                    }
                } else {
                    span_buf[out_idx] = ch;
                    out_idx += 1;
                    in_ws = false;
                }
            }
            if (out_idx > 30) break :blk span_buf[0..30];
            break :blk span_buf[0..out_idx];
        };

        std.debug.print("{d: >2}  {s: <16}  {d}  {d}  {d: >3}  {d: >3}  {s}\n", .{
            pc, op_name, instr.a, instr.b, instr.c, instr.bx, span_text,
        });

        const raw_line = blk: {
            var s = span.start;
            while (s > 0 and source[s - 1] != '\n') : (s -= 1) {}
            var e = if (span.end <= source.len) span.end else source.len;
            while (e < source.len and source[e] != '\n') : (e += 1) {}
            break :blk source[s..e];
        };

        if (raw_line.len > 0) {
            var line_buf: [1024]u8 = undefined;
            const line_display = line_buf[0..@min(raw_line.len, line_buf.len)];
            @memcpy(line_display, raw_line[0..line_display.len]);
            for (line_display) |*c| if (c.* == '\n' or c.* == '\r' or c.* == '\t') {
                c.* = ' ';
            };

            const offset_in_line = span.start - blk: {
                var s = span.start;
                while (s > 0 and source[s - 1] != '\n') : (s -= 1) {}
                break :blk s;
            };
            const highlight_len = @max(1, @min(30, span.end -| span.start));

            std.debug.print("         | {s}\n", .{line_display});
            std.debug.print("         | ", .{});
            for (0..offset_in_line) |_| std.debug.print(" ", .{});
            for (0..highlight_len) |_| std.debug.print("^", .{});
            std.debug.print(" [{d}:{d}]\n", .{ span.line, span.column });
        }
    }
}

pub fn printBenchStats(times: []std.Io.Duration) void {
    std.mem.sort(std.Io.Duration, times, {}, struct {
        pub fn lessThan(_: void, a: std.Io.Duration, b: std.Io.Duration) bool {
            return a.nanoseconds < b.nanoseconds;
        }
    }.lessThan);

    const best = if (times.len > 0) times[0].nanoseconds else @as(i96, 0);
    const worst = if (times.len > 0) times[times.len - 1].nanoseconds else @as(i96, 0);
    const median = if (times.len > 0) times[times.len / 2].nanoseconds else @as(i96, 0);
    const p95_idx = if (times.len > 0) @min(times.len - 1, (times.len * 95) / 100) else 0;
    const p95 = if (times.len > 0) times[p95_idx].nanoseconds else @as(i96, 0);

    const best_ms = @as(f64, @floatFromInt(best)) / 1_000_000.0;
    const worst_ms = @as(f64, @floatFromInt(worst)) / 1_000_000.0;
    const median_ms = @as(f64, @floatFromInt(median)) / 1_000_000.0;
    const p95_ms = @as(f64, @floatFromInt(p95)) / 1_000_000.0;

    std.debug.print("+=========================\n", .{});
    std.debug.print("| best    {d:.3}ms / {d}ns\n", .{ best_ms, best });
    std.debug.print("| median  {d:.3}ms / {d}ns\n", .{ median_ms, median });
    std.debug.print("| p95     {d:.3}ms / {d}ns\n", .{ p95_ms, p95 });
    std.debug.print("| worst   {d:.3}ms / {d}ns\n", .{ worst_ms, worst });
}

test "eval error messages and failure rendering include source name" {
    if (true) return error.SkipZigTest;
    try std.testing.expectEqualStrings("stack underflow!", EvalErrorKind.StackUnderflow.message());
    try std.testing.expectEqualStrings("import failed!", EvalErrorKind.ImportFailed.message());

    const failure = EvalFailure{
        .kind = .TypeError,
        .span = null,
        .message = "boom",
        .source_name = "file.rv",
    };

    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();
    try failure.render(std.testing.allocator, &buf.writer, "ignored");
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "error: boom") != null);
}

test "failure rendering includes stack trace frames" {
    var failure = EvalFailure{
        .kind = .TypeError,
        .span = null,
        .message = "boom",
        .source_name = "file.rv",
        .source = "ignored",
        .trace_len = 2,
    };
    failure.trace[0] = .{
        .function_name = "inner",
        .source_name = "file.rv",
        .span = .{
            .line = 2,
            .column = 4,
            .start = 0,
            .end = 1,
        },
    };
    failure.trace[1] = .{
        .function_name = "<module>",
        .source_name = "file.rv",
        .pc = 7,
    };

    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();
    try failure.render(std.testing.allocator, &buf.writer, "unused");

    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "stack trace:") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "0: inner at file.rv:2:4") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "1: <module> at file.rv:pc=7") != null);
}
