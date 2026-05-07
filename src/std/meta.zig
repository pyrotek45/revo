const std = @import("std");
const revo = @import("../root.zig");
const std_lib = @import("root.zig");
const testing = revo.lang.testing;

const Data = revo.Data;
const VM = revo.VM;
const NativeResult = std_lib.NativeResult;

// debug flags
pub fn set_debug(args: []const Data, vm: *VM) !NativeResult {
    if (args[0] != .table) return .errType(0, "table", @tagName(args[0]));
    const table = try vm.tables.get(args[0].table);
    vm.debug.dump = try check_field("dump", table, vm);
    vm.debug.each_instr = try check_field("instr", table, vm);
    vm.debug.each_stack = try check_field("stack", table, vm);
    vm.debug.trace = try check_field("trace", table, vm);
    return std_lib.okAtom(vm);
}

// get metatable
pub fn get_metatable_(args: []const Data, vm: *VM) !NativeResult {
    const mt = try vm.getMetatableId(args[0]);
    return if (mt) |id| .{ .ok = .{ .table = id } } else .{ .ok = revo.core_atoms.data(.missing) };
}

/// > set_metatable(tbl: table, meta: table) -> table
/// returns table with the mt set
///     t = {}
///     mt = {__len = fn() 42}
///     set_metatable(t, mt)
pub fn set_metatable_(args: []const Data, vm: *VM) !NativeResult {
    const mt = switch (args[1]) {
        .atom => |a| if (a == revo.core_atoms.atom_id(.nil)) null else return .errType(
            1,
            "nil atom or table",
            "atom",
        ),
        .table => |id| id,
        else => return .errType(1, "nil atom or table", @tagName(args[1])),
    };
    try vm.setMetatable(args[0], mt);
    return .{ .ok = args[0] };
}

fn check_field(name: []const u8, table: *revo.table.Table, vm: *VM) !bool {
    return !revo.isFalse((try table.get(try vm.ownDataString(name), vm)) orelse Data.new.nil());
}

// comparison metamethods
pub const comparison_mt = struct {
    const Op = enum { eq, ne, lt, gt, lte, gte };

    fn compare(comptime op: Op, args: []const Data, vm: *VM) NativeResult {
        if (args.len != 2) return .errArity(args.len, 2);
        const a = args[0];
        const b = args[1];

        // num comp
        const a_num = switch (a) {
            .number => |v| v,
            else => null,
        };
        const b_num = switch (b) {
            .number => |v| v,
            else => null,
        };
        if (a_num != null and b_num != null) {
            return .okBool(switch (op) {
                .eq => a_num.? == b_num.?,
                .ne => a_num.? != b_num.?,
                .lt => a_num.? < b_num.?,
                .gt => a_num.? > b_num.?,
                .lte => a_num.? <= b_num.?,
                .gte => a_num.? >= b_num.?,
            });
        }

        // str comp
        if (a == .string and b == .string) {
            const a_str = vm.stringValue(a.string);
            const b_str = vm.stringValue(b.string);
            return .okBool(switch (op) {
                .eq => std.mem.eql(u8, a_str, b_str),
                .ne => !std.mem.eql(u8, a_str, b_str),
                .lt => std.mem.lessThan(u8, a_str, b_str),
                .gt => std.mem.lessThan(u8, b_str, a_str),
                .lte => std.mem.eql(u8, a_str, b_str) or std.mem.lessThan(u8, a_str, b_str),
                .gte => std.mem.eql(u8, a_str, b_str) or std.mem.lessThan(u8, b_str, a_str),
            });
        }

        // atom comp
        if (a == .atom and b == .atom) {
            return .okBool(switch (op) {
                .eq, .lte, .gte => a.atom == b.atom,
                .ne => a.atom != b.atom,
                .lt, .gt => false,
            });
        }

        // mixed types
        return switch (op) {
            .eq => .okBool(false),
            .ne => .okBool(true),
            else => switch (a) {
                .number => switch (b) {
                    .number => unreachable,
                    else => .errType(1, "number", @tagName(b)),
                },
                .string => switch (b) {
                    .string => unreachable,
                    else => .errType(1, "string", @tagName(b)),
                },
                else => .errType(0, "number or string", @tagName(a)),
            },
        };
    }

    inline fn makeOp(comptime op: Op) std_lib.NativeFn {
        return struct {
            fn call(args: []const Data, vm: *VM) !NativeResult {
                return compare(op, args, vm);
            }
        }.call;
    }

    const eq = makeOp(.eq);
    const ne = makeOp(.ne);
    const lt = makeOp(.lt);
    const gt = makeOp(.gt);
    const lte = makeOp(.lte);
    const gte = makeOp(.gte);

    const comparison_methods = [_]std_lib.MethodDef{
        .{ .key = .{ .core = .__eq }, .func = std_lib.define(&[_]std_lib.TypeSpec{ .any, .any }, eq) },
        .{ .key = .{ .core = .__ne }, .func = std_lib.define(&[_]std_lib.TypeSpec{ .any, .any }, ne) },
        .{ .key = .{ .core = .__lt }, .func = std_lib.define(&[_]std_lib.TypeSpec{ .any, .any }, lt) },
        .{ .key = .{ .core = .__gt }, .func = std_lib.define(&[_]std_lib.TypeSpec{ .any, .any }, gt) },
        .{ .key = .{ .core = .__lte }, .func = std_lib.define(&[_]std_lib.TypeSpec{ .any, .any }, lte) },
        .{ .key = .{ .core = .__gte }, .func = std_lib.define(&[_]std_lib.TypeSpec{ .any, .any }, gte) },
    };

    pub fn register(vm: *VM) !void {
        // globals
        inline for (comparison_methods) |method| {
            const fn_id = try vm.functions.create(.{ .native = method.func });
            const meta_name = switch (method.key) {
                .core => |atom| @tagName(atom),
                .named => |name| name,
            };
            const global_name = if (std.mem.startsWith(u8, meta_name, "__")) meta_name[2..] else meta_name;
            try vm.globals.put(try vm.internAtom(global_name), .{ .function = fn_id });
        }
        // numbers
        try std_lib.registerMetatable(vm, &comparison_methods, Data.new.num(0));
        // strings
        if (try vm.getMetatableId(try vm.ownDataString(""))) |mt_id| {
            const str_mt = try vm.tables.get(mt_id);
            inline for (comparison_methods) |method| {
                const fn_id = try vm.functions.create(.{ .native = method.func });
                const key_atom = switch (method.key) {
                    .named => |name| try vm.internAtom(name),
                    .core => |atom| revo.core_atoms.atom_id(atom),
                };
                try str_mt.putRaw(.{ .atom = key_atom }, .{ .function = fn_id });
            }
        }
    }

    test "comparison metamethods" {
        try testing.top_true("eq(1, 1)");
        try testing.top_false("eq(1, 2)");
        try testing.top_true("ne(1, 2)");
        try testing.top_true("lt(1, 2)");
        try testing.top_true("gt(2, 1)");
        try testing.top_true("lte(1, 1)");
        try testing.top_true("gte(2, 1)");
    }
};

test "all lens" {
    try testing.top_number("len({ 1, 2, 3, 8 }) + len(\"asdf\")", 8);
}
