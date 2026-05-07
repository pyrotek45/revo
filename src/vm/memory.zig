const std = @import("std");

const revo = @import("revo");

pub const StringID = usize;
pub const AtomID = usize;
pub const FunctionID = usize;
pub const TableID = usize;
pub const TupleID = usize;

pub const Type = enum(u4) { number = 0, string = 1, atom = 2, function = 3, table = 4, tuple = 5 };

pub const Data = union(Type) {
    number: f64,
    string: StringID,
    atom: AtomID,
    function: FunctionID, // id into FunctionPool
    table: TableID, // id into TablePool
    tuple: TupleID, // id into TuplePool

    pub const new = struct {
        pub inline fn num(val: anytype) Data {
            return .{ .number = switch (@typeInfo(@TypeOf(val))) {
                .comptime_int, .int => @as(f64, @floatFromInt(val)),
                .comptime_float, .float => val,
                else => @compileError("new.num expects int or float"),
            } };
        }
        pub inline fn nil() Data {
            return revo.core_atoms.data(.nil);
        }
        pub inline fn str(id: StringID) Data {
            return .{ .string = id };
        }
        pub inline fn atom(id: AtomID) Data {
            return .{ .atom = id };
        }
        pub inline fn boolean(val: bool) Data {
            return if (val) revo.core_atoms.data(.true) else revo.core_atoms.data(.false);
        }
        pub inline fn table(id: TableID) Data {
            return .{ .table = id };
        }
        pub inline fn tuple(id: TupleID) Data {
            return .{ .tuple = id };
        }
    };

    pub const RenderMode = enum(u1) { display, debug };

    pub fn write(self: Data, buf: *std.ArrayList(u8), vm: *revo.VM, mode: RenderMode) anyerror!void {
        if (mode == .debug) {
            if (try vm.getMetamethod(self, "__debug")) |mm| {
                const result = switch (mm) {
                    .function => try vm.callFunction(mm, &.{self}),
                    else => return error.TypeError,
                };
                switch (result) {
                    .string => |id| {
                        try buf.appendSlice(vm.runtime.alloc, vm.stringValue(id));
                        return;
                    },
                    else => return error.TypeError,
                }
            }
        }

        switch (self) {
            .number => |n| {
                const s = try std.fmt.allocPrint(vm.runtime.alloc, "{}", .{n});
                defer vm.runtime.alloc.free(s);
                try buf.appendSlice(vm.runtime.alloc, s);
            },
            .string => |id| switch (mode) {
                .display => try buf.appendSlice(vm.runtime.alloc, vm.stringValue(id)),
                .debug => {
                    const s = try std.fmt.allocPrint(vm.runtime.alloc, "\"{s}\"", .{vm.stringValue(id)});
                    defer vm.runtime.alloc.free(s);
                    try buf.appendSlice(vm.runtime.alloc, s);
                },
            },
            .atom => |id| {
                const s = try std.fmt.allocPrint(vm.runtime.alloc, ":{s}", .{vm.atomName(id)});
                defer vm.runtime.alloc.free(s);
                try buf.appendSlice(vm.runtime.alloc, s);
            },
            .function => |id| {
                const f = try vm.functions.get(id);
                switch (f.*) {
                    .native => {
                        const s = try std.fmt.allocPrint(vm.runtime.alloc, "#fn(){}/{}", .{ id, f.arity() });
                        defer vm.runtime.alloc.free(s);
                        try buf.appendSlice(vm.runtime.alloc, s);
                    },
                    .c_function => |cf| {
                        const s = try std.fmt.allocPrint(vm.runtime.alloc, "${s}@{}()/{}", .{ cf.name, id, f.arity() });
                        defer vm.runtime.alloc.free(s);
                        try buf.appendSlice(vm.runtime.alloc, s);
                    },
                    .closure => {
                        const s = try std.fmt.allocPrint(vm.runtime.alloc, "{s}()/{d}", .{ f.name(), f.arity() });
                        defer vm.runtime.alloc.free(s);
                        try buf.appendSlice(vm.runtime.alloc, s);
                    },
                }
            },
            .table => |id| {
                const table = vm.tables.get(id) catch {
                    try buf.appendSlice(vm.runtime.alloc, "<dead-table>");
                    return;
                };

                table.write(buf, vm, mode) catch {
                    try buf.appendSlice(vm.runtime.alloc, "<table-unprintable>");
                };
            },
            .tuple => |id| {
                const tuple = vm.tuples.get(id) catch {
                    try buf.appendSlice(vm.runtime.alloc, "<dead-tuple>");
                    return;
                };
                tuple.write(buf, vm, mode) catch {
                    try buf.appendSlice(vm.runtime.alloc, "<tuple-unprintable>");
                };
            },
        }
    }

    pub fn print(self: Data, vm: *revo.VM) void {
        var buf = std.ArrayList(u8).initCapacity(vm.runtime.alloc, 4) catch {
            std.debug.print("<oom>", .{});
            return;
        };
        defer buf.deinit(vm.runtime.alloc);
        self.write(&buf, vm, .debug) catch {
            std.debug.print("<print-error>", .{});
            return;
        };
        std.debug.print("{s}", .{buf.items});
    }

    pub fn as_number(self: Data) !f64 {
        return switch (self) {
            .number => |v| v,
            else => error.TypeError,
        };
    }
};
