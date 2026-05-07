const revo = @import("../root.zig");
const root = @import("root.zig");

const Data = revo.Data;
const VM = revo.VM;
const NativeResult = root.NativeResult;

pub fn ok_(args: []const Data, vm: *VM) NativeResult {
    if (!root.expectArity(args, 1)) return .errArity(args.len, 1);
    return root.resultTuple(vm, .ok, args[0]);
}

pub fn err_(args: []const Data, vm: *VM) NativeResult {
    if (!root.expectArity(args, 1)) return .errArity(args.len, 1);
    return root.resultTuple(vm, .err, args[0]);
}

pub fn error_(args: []const Data, vm: *VM) NativeResult {
    if (args.len < 1) return .errArity(args.len, 1);
    if (args[0] != .atom) return .errType(0, "atom", "not atom");
    if (args[0].atom == try root.resultTag(vm, .ok) or args[0].atom == try root.resultTag(vm, .err)) {
        return .errType(0, "non-result atom", "ok or err");
    }
    return .okData(Data.new.tuple(try vm.tuples.create(args)));
}

pub fn is_ok(args: []const Data, vm: *VM) NativeResult {
    if (!root.expectArity(args, 1)) return .errArity(args.len, 1);
    return .{ .ok = root.boolData(root.isResultTag(args[0], try root.resultTag(vm, .ok), vm)) };
}

pub fn is_err(args: []const Data, vm: *VM) NativeResult {
    if (!root.expectArity(args, 1)) return .errArity(args.len, 1);
    return .{ .ok = root.boolData(root.isResultTag(args[0], try root.resultTag(vm, .err), vm)) };
}

pub fn is_result(args: []const Data, vm: *VM) NativeResult {
    if (!root.expectArity(args, 1)) return .errArity(args.len, 1);
    const ok_tag = try root.resultTag(vm, .ok);
    const err_tag = try root.resultTag(vm, .err);
    const tag = root.tupleTag(args[0], vm) orelse return .{ .ok = root.boolData(false) };
    return .{ .ok = root.boolData(tag == ok_tag or tag == err_tag) };
}

pub fn is_error(args: []const Data, vm: *VM) NativeResult {
    if (!root.expectArity(args, 1)) return .errArity(args.len, 1);
    const ok_tag = try root.resultTag(vm, .ok);
    const err_tag = try root.resultTag(vm, .err);
    const tag = root.tupleTag(args[0], vm) orelse return .{ .ok = root.boolData(false) };
    return .{ .ok = root.boolData(tag != ok_tag and tag != err_tag) };
}

pub fn error_tag(args: []const Data, vm: *VM) NativeResult {
    if (!root.expectArity(args, 1)) return .errArity(args.len, 1);
    const tag = root.tupleTag(args[0], vm) orelse return .{ .ok = root.noneAtom(vm) };
    const ok_tag = try root.resultTag(vm, .ok);
    const err_tag = try root.resultTag(vm, .err);
    if (tag == ok_tag or tag == err_tag) return .{ .ok = root.noneAtom(vm) };
    return .{ .ok = .{ .atom = tag } };
}

pub fn error_payload(args: []const Data, vm: *VM) NativeResult {
    if (!root.expectArity(args, 1)) return .errArity(args.len, 1);
    const tuple = root.asErrorTuple(args[0], vm) orelse return .{ .ok = root.noneAtom(vm) };
    if (tuple.items.len <= 1) return .{ .ok = root.noneAtom(vm) };
    if (tuple.items.len == 2) return .{ .ok = tuple.items[1] };
    return .{ .ok = .{ .tuple = try vm.tuples.create(tuple.items[1..]) } };
}

pub fn error_message(args: []const Data, vm: *VM) NativeResult {
    if (!root.expectArity(args, 1)) return .errArity(args.len, 1);
    const payload = error_payload(args, vm);
    return switch (payload) {
        .err => |e| .{ .err = e },
        .ok => |p| switch (p) {
            .table => |id| blk: {
                const table = vm.tables.get(id) catch return .errType(0, "table", "invalid table");
                const value = (try table.get(.{ .atom = try vm.internAtom("message") }, vm)) orelse break :blk root.noneAtom(vm);
                break :blk switch (value) {
                    .string => .{ .ok = value },
                    else => .{ .ok = root.noneAtom(vm) },
                };
            },
            else => .{ .ok = root.noneAtom(vm) },
        },
    };
}

pub const resultTuple = root.resultTuple;
pub const resultTag = root.resultTag;
pub const tupleTag = root.tupleTag;
pub const isResultTag = root.isResultTag;
pub const asErrorTuple = root.asErrorTuple;
pub const boolData = root.boolData;
