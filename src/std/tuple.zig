const std = @import("std");
const revo = @import("../root.zig");
const root = @import("root.zig");

const Data = revo.Data;
const VM = revo.VM;
const NativeResult = root.NativeResult;

const iter = @import("iter.zig");

pub fn register(vm: *VM) !void {
    try root.registerTableFunctions(vm, "tuple", &[_]root.FuncDef{
        .{ .name = "len", .f = root.define(&[_]root.TypeSpec{.tuple}, len) },
        .{ .name = "unwrap", .f = root.define(&[_]root.TypeSpec{.tuple}, root.try_) },
        .{ .name = "unwrap_err", .f = root.define(&[_]root.TypeSpec{.tuple}, root.unwrap_err_) },
        .{ .name = "map", .f = root.define(&.{ .any, .function }, iter.map_fn) },
        .{ .name = "filter", .f = root.define(&.{ .any, .function }, iter.filter_fn) },
        .{ .name = "reduce", .f = root.define(&.{ .any, .function, .any }, iter.reduce_fn) },
        .{ .name = "each", .f = root.define(&.{ .any, .function }, iter.each_fn) },
        .{ .name = "find", .f = root.define(&.{ .any, .function }, iter.find_fn) },
        .{ .name = "all?", .f = root.define(&.{ .any, .function }, iter.all_fn) },
        .{ .name = "any?", .f = root.define(&.{ .any, .function }, iter.any_fn) },
        .{ .name = "add", .f = root.define(&[_]root.TypeSpec{ .tuple, .tuple }, add) },
        .{ .name = "mul", .f = root.define(&[_]root.TypeSpec{ .tuple, .number }, mul) },
    });

    try root.registerMetatable(vm, &[_]root.MethodDef{
        .{ .key = .{ .named = "len" }, .func = root.define(&[_]root.TypeSpec{.tuple}, len) },
        .{ .key = .{ .named = "unwrap" }, .func = root.define(&[_]root.TypeSpec{.tuple}, root.try_) },
        .{ .key = .{ .named = "unwrap_err" }, .func = root.define(&[_]root.TypeSpec{.tuple}, root.unwrap_err_) },
        .{ .key = .{ .core = .__index }, .func = root.define(&[_]root.TypeSpec{ .tuple, .number }, index) },
        .{ .key = .{ .named = "add" }, .func = root.define(&[_]root.TypeSpec{ .tuple, .tuple }, add) },
        .{ .key = .{ .named = "mul" }, .func = root.define(&[_]root.TypeSpec{ .tuple, .number }, mul) },
    }, Data.new.tuple(std.math.maxInt(usize)));
}

fn len(args: []const Data, vm: *VM) !NativeResult {
    const id = args[0].asTuple() orelse return .errType(0, "tuple", root.dataToString(args[0]));
    const t = try vm.tuples.get(id);
    return .{ .ok = Data.new.num(t.len()) };
}

fn index(args: []const Data, vm: *VM) !NativeResult {
    const id = args[0].asTuple() orelse return .errType(0, "tuple", root.dataToString(args[0]));
    const n = args[1].asNum() orelse return .errType(1, "number", root.dataToString(args[1]));
    const idx = try revo.asIndex(n);
    const t = try vm.tuples.get(id);
    if (idx >= t.items.len) return .{ .ok = revo.core_atoms.data(.missing) };
    return .{ .ok = t.items[idx] };
}

fn add(args: []const Data, vm: *VM) !NativeResult {
    const left_id = args[0].asTuple() orelse return .errType(0, "tuple", root.dataToString(args[0]));
    const right_id = args[1].asTuple() orelse return .errType(1, "tuple", root.dataToString(args[1]));
    const left = try vm.tuples.get(left_id);
    const right = try vm.tuples.get(right_id);
    var items = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, left.items.len + right.items.len);
    defer items.deinit(vm.runtime.alloc);
    try items.appendSlice(vm.runtime.alloc, left.items);
    try items.appendSlice(vm.runtime.alloc, right.items);
    return .okData(Data.new.tuple(try vm.tuples.create(items.items)));
}

fn mul(args: []const Data, vm: *VM) !NativeResult {
    const tuple_id = args[0].asTuple() orelse return .errType(0, "tuple", root.dataToString(args[0]));
    const n = args[1].asNum() orelse return .errType(1, "number", root.dataToString(args[1]));
    const times = @as(i64, @intFromFloat(n));
    if (times < 0) return .errType(1, "non-negative number", "negative number");
    const tuple = try vm.tuples.get(tuple_id);
    var items = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, tuple.items.len * @as(usize, @intCast(times)));
    defer items.deinit(vm.runtime.alloc);
    for (0..@as(usize, @intCast(times))) |_| {
        try items.appendSlice(vm.runtime.alloc, tuple.items);
    }
    return .okData(Data.new.tuple(try vm.tuples.create(items.items)));
}

fn _tostring(args: []const Data, vm: *VM) !NativeResult {
    var buf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer buf.deinit();
    try args[0].write(&buf.writer, vm, .display);
    const str = try buf.toOwnedSlice();
    return .{ .ok = try vm.adoptDataString(str) };
}

fn _debug(args: []const Data, vm: *VM) !NativeResult {
    const id = args[0].asTuple() orelse return .errType(0, "tuple", root.dataToString(args[0]));
    const tuple = try vm.tuples.get(id);
    var buf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer buf.deinit();
    try tuple.write(&buf.writer, vm, .debug);
    const str = try buf.toOwnedSlice();
    return .{ .ok = try vm.adoptDataString(str) };
}
