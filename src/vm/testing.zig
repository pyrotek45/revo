const std = @import("std");
const revo = @import("revo");
const vm_mod = @import("VM.zig");

pub fn runtime() revo.Runtime {
    return .{
        .alloc = std.heap.page_allocator,
        .io = std.testing.io,
    };
}

pub fn run(vm: *vm_mod.VM) !void {
    const result = try vm.runReport();
    switch (result) {
        .ok => {},
        .err => |failure| {
            if (vm.currentDebugSource()) |source| {
                var buf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
                defer buf.deinit();
                try failure.render(&buf.writer, source);
                std.debug.print("{s}", .{buf.written()});
            } else {
                std.debug.print("error: {s}\n", .{failure.message});
            }
            return error.RuntimeFailure;
        },
    }
}

pub fn runTop(vm: *vm_mod.VM) !revo.Data {
    try run(vm);
    return vm.mainResult();
}

pub fn expectFailure(vm: *vm_mod.VM, expected: vm_mod.EvalErrorKind) !void {
    const result = try vm.runReport();
    switch (result) {
        .ok => return error.ExpectedRuntimeFailure,
        .err => |failure| try std.testing.expectEqual(expected, failure.kind),
    }
}

test "expectFailure returns error when vm run succeeds" {
    var vm = try vm_mod.VM.init(runtime());
    defer vm.deinit();
    vm.mainFiber().program = &.{.{ .op = .halt }};

    try std.testing.expectError(error.ExpectedRuntimeFailure, expectFailure(&vm, .TypeError));
}
