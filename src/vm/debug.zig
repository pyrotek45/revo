const std = @import("std");

const revo = @import("revo");
const diagnostic = revo.lang.diagnostic;
const Span = revo.lang.ast.Span;

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
