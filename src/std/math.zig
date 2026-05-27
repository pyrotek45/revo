const std = @import("std");
const revo = @import("../root.zig");
const root = @import("root.zig");
const testing = revo.lang.testing;

const Data = revo.Data;
const VM = revo.VM;
const NativeResult = root.NativeResult;
const dataToString = root.dataToString;

// zig fmt: off
const MathOps = struct {
    /// returns absolute value
    /// > math.abs(x: number) -> number
    pub fn abs(x: f64) f64 { return @abs(x); }
    /// returns floor of x
    /// > math.floor(x: number) -> number
    pub fn floor(x: f64) f64 { return @floor(x); }
    /// returns ceiling of x
    /// > math.ceil(x: number) -> number
    pub fn ceil(x: f64) f64 { return @ceil(x); }
    /// returns square root
    /// errors if x is negative
    /// > math.sqrt(x: number) -> number
    pub fn sqrt(x: f64) f64 { return @sqrt(x); }
    /// returns base raised to exponent
    /// > math.pow(base: number, exponent: number) -> number
    pub fn pow(base: f64, exponent: f64) f64 { return std.math.pow(f64, base, exponent); }
    /// returns sine of x (x in radians)
    /// > math.sin(x: number) -> number
    pub fn sin(x: f64) f64 { return @sin(x); }
    /// returns cosine of x (x in radians)
    /// > math.cos(x: number) -> number
    pub fn cos(x: f64) f64 { return @cos(x); }
    /// returns tangent of x (x in radians)
    /// > math.tan(x: number) -> number
    pub fn tan(x: f64) f64 { return @tan(x); }
    /// returns natural logarithm
    /// errors if x <= 0
    /// > math.log(x: number) -> number
    pub fn log(x: f64) f64 { return @log(x); }
    /// returns e raised to x
    /// > math.exp(x: number) -> number
    pub fn exp(x: f64) f64 { return @exp(x); }
};

const Pred = struct {
    pub fn nonNegative(x: f64) bool { return x >= 0; }
    pub fn positive(x: f64) bool { return x > 0; }
    pub fn less(a: f64, b: f64) bool { return a < b; }
    pub fn greater(a: f64, b: f64) bool { return a > b; }
};
// zig fmt: on

//
// generators
//
fn makeUnary(comptime op: fn (f64) f64) type {
    return struct {
        fn apply(args: []const Data, _: *VM) !NativeResult {
            return .{ .ok = Data.new.num(op(toF64(args[0]))) };
        }
    };
}

fn makeUnaryChecked(comptime op: fn (f64) f64, comptime check: fn (f64) bool, comptime expected: []const u8) type {
    return struct {
        fn apply(args: []const Data, _: *VM) !NativeResult {
            const n = toF64(args[0]);
            if (!check(n))
                return .errType(0, expected, dataToString(args[0]));
            return .{ .ok = Data.new.num(op(n)) };
        }
    };
}

fn makeBinary(comptime op: fn (f64, f64) f64) type {
    return struct {
        fn apply(args: []const Data, _: *VM) !NativeResult {
            return .{ .ok = Data.new.num(op(toF64(args[0]), toF64(args[1]))) };
        }
    };
}

fn makeVariadic(comptime cmp: fn (f64, f64) bool) type {
    return struct {
        /// returns min or max of all arguments
        fn apply(args: []const Data, _: *VM) !NativeResult {
            var res = toF64(args[0]);
            for (args[1..]) |arg| {
                const val = toF64(arg);
                if (cmp(val, res)) res = val;
            }
            return .{ .ok = Data.new.num(res) };
        }
    };
}

pub fn register(vm: *VM) !void {
    const funcs = [_]root.FuncDef{
        .{ .name = "abs", .f = root.define(&.{.number}, makeUnary(MathOps.abs).apply) },
        .{ .name = "floor", .f = root.define(&.{.number}, makeUnary(MathOps.floor).apply) },
        .{ .name = "ceil", .f = root.define(&.{.number}, makeUnary(MathOps.ceil).apply) },
        .{ .name = "sqrt", .f = root.define(&.{.number}, makeUnaryChecked(MathOps.sqrt, Pred.nonNegative, "non-negative number").apply) },
        .{ .name = "pow", .f = root.define(&.{ .number, .number }, makeBinary(MathOps.pow).apply) },
        .{ .name = "min", .f = root.defineVariadic(&.{.number}, makeVariadic(Pred.less).apply) }, // > math.min(args: number...) -> number
        .{ .name = "max", .f = root.defineVariadic(&.{.number}, makeVariadic(Pred.greater).apply) }, // > math.max(args: number...) -> number
        .{ .name = "sin", .f = root.define(&.{.number}, makeUnary(MathOps.sin).apply) },
        .{ .name = "cos", .f = root.define(&.{.number}, makeUnary(MathOps.cos).apply) },
        .{ .name = "tan", .f = root.define(&.{.number}, makeUnary(MathOps.tan).apply) },
        .{ .name = "log", .f = root.define(&.{.number}, makeUnaryChecked(MathOps.log, Pred.positive, "positive number").apply) },
        .{ .name = "exp", .f = root.define(&.{.number}, makeUnary(MathOps.exp).apply) },
    };
    try root.registerTableFunctions(vm, "math", &funcs);

    if (vm.globals.get(try vm.internAtom("math"))) |t| {
        if (t.asTable()) |table_id| {
            const table = try vm.tables.get(table_id);
            try table.putRaw(Data.new.atom(try vm.internAtom("pi")), Data.new.num(std.math.pi));
        }
    }
}

test "math library" {
    try testing.top_number("math.abs(-5)", 5);
    try testing.top_number("math.abs(5)", 5);
    try testing.top_number("math.floor(3.7)", 3);
    try testing.top_number("math.ceil(3.2)", 4);
    try testing.top_number("math.sqrt(4)", 2);
    try testing.top_number("math.pow(2, 3)", 8);
    try testing.top_number("math.min(1, 2, 3)", 1);
    try testing.top_number("math.max(1, 2, 3)", 3);
}

// .number is guaranteed by type sig
inline fn toF64(d: Data) f64 {
    return d.asNum().?;
}
