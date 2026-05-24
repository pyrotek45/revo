const std = @import("std");

pub const UnionVariant = struct {
    name: []const u8,
    types: []const TypeInfo,
};

pub const TypeInfo = union(enum) {
    // TODO: remove
    void,
    bool,
    // TODO: maybe unify here maybe split at vm
    int,
    float,
    string,
    atom: []const u8,
    tuple: []const TypeInfo,
    @"union": []const UnionVariant,
    struct_type: []const u8,
    function: *const FunctionSignature,
    any,

    pub fn eql(self: TypeInfo, other: TypeInfo) bool {
        return switch (self) {
            .void => other == .void,
            .bool => other == .bool,
            .int => other == .int,
            .float => other == .float,
            .string => other == .string,
            .atom => |a| if (other == .atom) std.mem.eql(u8, atomPayload(a), atomPayload(other.atom)) else false,
            .struct_type => |s| if (other == .struct_type) std.mem.eql(u8, s, other.struct_type) else false,
            .tuple => |ts| if (other == .tuple) blk: {
                if (ts.len != other.tuple.len) break :blk false;
                for (ts, other.tuple) |a, b| if (!eql(a, b)) break :blk false;
                break :blk true;
            } else false,
            .@"union" => |us| if (other == .@"union") blk: {
                if (us.len != other.@"union".len) break :blk false;
                for (us, other.@"union") |a, b| {
                    if (!std.mem.eql(u8, a.name, b.name)) break :blk false;
                    if (a.types.len != b.types.len) break :blk false;
                    for (a.types, b.types) |at, bt| if (!eql(at, bt)) break :blk false;
                }
                break :blk true;
            } else false,
            .function => |f| if (other == .function) f == other.function else false,
            .any => true,
        };
    }
};

pub fn atomPayload(name: []const u8) []const u8 {
    return if (name.len > 0 and name[0] == ':') name[1..] else name;
}

pub const FunctionSignature = struct { params: []const TypeInfo, return_type: TypeInfo };

pub fn typeName(t: TypeInfo) []const u8 {
    return switch (t) {
        .struct_type => |s| s,
        .atom => |a| a,
        else => @tagName(t),
    };
}

pub fn isNumeric(t: TypeInfo) bool {
    return t == .int or t == .float;
}

pub fn canCoerce(from: TypeInfo, to: TypeInfo) bool {
    if (from.eql(to) or to == .any or from == .any) return true;
    if (to == .@"union") {
        // fast-path for atom literals vs atom-only variants
        if (from == .atom) {
            for (to.@"union") |variant| {
                if (variant.name.len == 0 and variant.types.len == 1 and variant.types[0] == .atom) {
                    if (std.mem.eql(u8, atomPayload(variant.types[0].atom), atomPayload(from.atom))) return true;
                }
                if (variant.name.len != 0 and variant.types.len == 0) {
                    if (std.mem.eql(u8, atomPayload(variant.name), atomPayload(from.atom))) return true;
                }
            }
        }
        for (to.@"union") |variant| {
            if (unionVariantAccepts(variant, from)) return true;
        }
    }
    if (from == .@"union") {
        if (from.@"union".len == 0) return false;
        for (from.@"union") |variant| {
            if (!targetAcceptsVariant(variant, to)) return false;
        }
        return true;
    }
    return from == .int and to == .float;
}

fn unionVariantAccepts(variant: UnionVariant, value: TypeInfo) bool {
    if (variant.name.len != 0) {
        // named (tagged) variant
        if (variant.types.len == 0) {
            // atom-only variant accepts plain atoms with matching payload
            return value == .atom and std.mem.eql(u8, atomPayload(value.atom), atomPayload(variant.name));
        }
        if (value != .tuple) return false;
        if (value.tuple.len != variant.types.len + 1) return false;
        if (value.tuple[0] != .atom) return false;
        if (!std.mem.eql(u8, atomPayload(value.tuple[0].atom), atomPayload(variant.name))) return false;
        for (variant.types, 0..) |expected, i| {
            if (!canCoerce(value.tuple[i + 1], expected)) return false;
        }
        return true;
    }

    if (variant.types.len == 1) return canCoerce(value, variant.types[0]);
    if (value != .tuple) return false;
    if (value.tuple.len != variant.types.len) return false;
    for (variant.types, value.tuple) |expected, actual| {
        if (!canCoerce(actual, expected)) return false;
    }
    return true;
}

fn targetAcceptsVariant(variant: UnionVariant, target: TypeInfo) bool {
    if (variant.name.len != 0) {
        // named variant
        if (variant.types.len == 0) {
            // atom-only variant is acceptable by plain atom target
            return target == .atom and std.mem.eql(u8, atomPayload(target.atom), atomPayload(variant.name));
        }
        if (target != .tuple) return false;
        if (target.tuple.len != variant.types.len + 1) return false;
        if (target.tuple[0] != .atom) return false;
        if (!std.mem.eql(u8, atomPayload(target.tuple[0].atom), atomPayload(variant.name))) return false;
        for (variant.types, 0..) |source, i| {
            if (!canCoerce(source, target.tuple[i + 1])) return false;
        }
        return true;
    }

    if (variant.types.len == 1) return canCoerce(variant.types[0], target);
    if (target != .tuple) return false;
    if (target.tuple.len != variant.types.len) return false;
    for (variant.types, target.tuple) |source, expected| {
        if (!canCoerce(source, expected)) return false;
    }
    return true;
}

pub const BinaryOp = enum { add, sub, mul, div, mod, eq, neq, lt, gt, lte, gte, @"and", @"or" };

pub fn inferBinaryOp(op: BinaryOp, l: TypeInfo, r: TypeInfo) TypeInfo {
    return switch (op) {
        .add, .sub, .mul, .div, .mod => blk: {
            if (l == .int and r == .int) break :blk .int;
            if (isNumeric(l) and isNumeric(r)) break :blk .float;
            break :blk .any;
        },
        .eq, .neq, .lt, .gt, .lte, .gte => .bool,
        .@"and", .@"or" => .bool,
    };
}

pub const UnaryOp = enum { negate, not };

pub fn inferUnaryOp(op: UnaryOp, t: TypeInfo) TypeInfo {
    return switch (op) {
        .negate => if (isNumeric(t)) t else .any,
        .not => .bool,
    };
}
