const std = @import("std");

const revo = @import("revo");
const lang = revo.lang;
const testing = revo.lang.testing;
const Data = revo.Data;

pub fn runModule(vm: *revo.VM, source_path: []const u8, source: []const u8) !revo.Data {
    const result = try runModuleReport(vm, source_path, source);
    if (result == .err) return error.RuntimeFailure;
    return vm.currentFiber().result;
}

pub fn runModuleReport(vm: *revo.VM, source_path: []const u8, source: []const u8) !revo.EvalResult {
    const artifact = switch (try lang.build(vm, .{ .name = source_path, .text = source }, .{})) {
        .ok => |ok| ok,
        .err => |lang_err| {
            var buf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
            defer buf.deinit();
            lang.renderError(vm.runtime.alloc, &buf.writer, .{ .name = source_path, .text = source }, lang_err) catch {};
            std.debug.print("{s}", .{buf.written()});
            lang.deinitError(vm.runtime.alloc, lang_err);
            return error.ParseError;
        },
    };
    defer vm.runtime.alloc.free(artifact.instructions);
    defer vm.runtime.alloc.free(artifact.spans);
    return runCompiledModuleReport(vm, source_path, artifact.instructions);
}

pub fn runImportedModule(vm: *revo.VM, source_path: []const u8, source: []const u8) !revo.Data {
    const result = try runImportedModuleReport(vm, source_path, source);
    if (result == .err) return error.RuntimeFailure;
    return vm.currentFiber().result;
}

pub fn runImportedModuleReport(vm: *revo.VM, source_path: []const u8, source: []const u8) !revo.EvalResult {
    const artifact = switch (try lang.build(vm, .{ .name = source_path, .text = source }, .{
        .module_mode = true,
    })) {
        .ok => |ok| ok,
        .err => |lang_err| {
            var buf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
            defer buf.deinit();
            lang.renderError(vm.runtime.alloc, &buf.writer, .{ .name = source_path, .text = source }, lang_err) catch {};
            std.debug.print("{s}", .{buf.written()});
            lang.deinitError(vm.runtime.alloc, lang_err);
            return error.ParseError;
        },
    };
    defer vm.runtime.alloc.free(artifact.instructions);
    defer vm.runtime.alloc.free(artifact.spans);
    return runCompiledImportedModuleReport(vm, source_path, artifact.instructions);
}

pub fn runCompiledModuleReport(
    vm: *revo.VM,
    source_path: []const u8,
    program: []const revo.Instruction,
) !revo.EvalResult {
    try vm.setProgramSourceName(source_path);

    const module_globals = revo.VM.Globals.init(vm.runtime.alloc);
    const module_const_globals = @TypeOf(vm.const_globals).init(vm.runtime.alloc);

    const module_dir = std.fs.path.dirname(source_path) orelse ".";
    const previous_module_dir = vm.module_dir;
    vm.module_dir = module_dir;
    defer vm.module_dir = previous_module_dir;

    const previous_globals = vm.globals;
    const previous_const_globals = vm.const_globals;
    vm.globals = module_globals;
    vm.const_globals = module_const_globals;
    defer {
        vm.globals.deinit();
        vm.const_globals.deinit();
        vm.globals = previous_globals;
        vm.const_globals = previous_const_globals;
    }

    try vm.seedBootstrapGlobals(&vm.globals);

    const module_state = try revo.VM.Fiber.init(vm.runtime.alloc, vm.currentFiber().id, program);
    var module_state_with_debug = module_state;
    module_state_with_debug.debug_info_id = vm.pending_debug_info_id;

    var previous_state = vm.swapFiber(module_state_with_debug);
    defer {
        var finished_state = vm.swapFiber(previous_state);
        revo.VM.Fiber.deinit(&finished_state, vm.runtime.alloc);
    }

    const result = try vm.runReport();
    if (result == .ok) previous_state.result = vm.currentResult();
    return result;
}

pub fn runCompiledImportedModuleReport(
    vm: *revo.VM,
    source_path: []const u8,
    program: []const revo.Instruction,
) !revo.EvalResult {
    try vm.setProgramSourceName(source_path);

    const module_globals = revo.VM.Globals.init(vm.runtime.alloc);
    const module_const_globals = @TypeOf(vm.const_globals).init(vm.runtime.alloc);

    const module_dir = std.fs.path.dirname(source_path) orelse ".";
    const previous_module_dir = vm.module_dir;
    vm.module_dir = module_dir;
    defer vm.module_dir = previous_module_dir;

    const previous_globals = vm.globals;
    const previous_const_globals = vm.const_globals;
    vm.globals = module_globals;
    vm.const_globals = module_const_globals;
    defer {
        vm.globals.deinit();
        vm.const_globals.deinit();
        vm.globals = previous_globals;
        vm.const_globals = previous_const_globals;
    }

    try vm.seedBootstrapGlobals(&vm.globals);
    const exports_atom = try vm.internAtom("__module_pub_exports");
    const exports_table = try vm.tables.create();
    try vm.globals.put(exports_atom, Data.new.table(exports_table));

    const module_state = try revo.VM.Fiber.init(vm.runtime.alloc, vm.currentFiber().id, program);
    var module_state_with_debug = module_state;
    module_state_with_debug.debug_info_id = vm.pending_debug_info_id;

    var previous_state = vm.swapFiber(module_state_with_debug);
    defer {
        var finished_state = vm.swapFiber(previous_state);
        revo.VM.Fiber.deinit(&finished_state, vm.runtime.alloc);
    }

    const result = try vm.runReport();
    if (result == .ok) {
        const exports_value = vm.globals.get(exports_atom) orelse Data.new.table(exports_table);
        previous_state.result = exports_value;
    }
    return result;
}

/// run compiled code in the current vm globals or constglobals context
/// intended for repl
pub fn runCompiledSessionReport(
    vm: *revo.VM,
    source_path: []const u8,
    program: []const revo.Instruction,
) !revo.EvalResult {
    try vm.setProgramSourceName(source_path);

    const module_dir = std.fs.path.dirname(source_path) orelse ".";
    const previous_module_dir = vm.module_dir;
    vm.module_dir = module_dir;
    defer vm.module_dir = previous_module_dir;

    try vm.seedBootstrapGlobals(&vm.globals);

    const module_state = try revo.VM.Fiber.init(vm.runtime.alloc, vm.currentFiber().id, program);
    var module_state_with_debug = module_state;
    module_state_with_debug.debug_info_id = vm.pending_debug_info_id;

    var previous_state = vm.swapFiber(module_state_with_debug);
    defer {
        var finished_state = vm.swapFiber(previous_state);
        revo.VM.Fiber.deinit(&finished_state, vm.runtime.alloc);
    }

    const result = try vm.runReport();
    if (result == .ok) previous_state.result = vm.currentResult();
    return result;
}

test "module message setters clear previous values" {
    var vm = try revo.VM.init(testing.runtime());
    defer vm.deinit();

    try vm.setProgramDebugInfo(&.{}, "", "one.rv");
    try vm.setProgramSourceName("one.rv");
    try std.testing.expectEqualStrings("one.rv", vm.currentDebugSourceName().?);
    try vm.setProgramSourceName("two.rv");
    try std.testing.expectEqualStrings("two.rv", vm.currentDebugSourceName().?);

    try vm.setPanicMessage("panic-a");
    try std.testing.expectEqualStrings("panic-a", vm.panic_message.?);
    try vm.setPanicMessage("panic-b");
    try std.testing.expectEqualStrings("panic-b", vm.panic_message.?);
    vm.clearPanicMessage();
    try std.testing.expect(vm.panic_message == null);

    try vm.setRuntimeMessage("runtime-a");
    try std.testing.expectEqualStrings("runtime-a", vm.runtime_message.?);
    try vm.setRuntimeMessageFmt("runtime-{d}", .{7});
    try std.testing.expectEqualStrings("runtime-7", vm.runtime_message.?);
    vm.clearRuntimeMessage();
    try std.testing.expect(vm.runtime_message == null);
}

test "module cache reloads changed files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "hot.rv",
        .data =
        \\ pub const value = 1
        ,
    });

    const module_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(module_dir);

    const source_name = try std.fmt.allocPrint(alloc, "{s}/script.rv", .{module_dir});
    defer alloc.free(source_name);

    const code =
        \\ const mod = import "hot"
        \\ mod.value
    ;

    var vm = try revo.VM.init(testing.runtime());
    defer vm.deinit();
    vm.module_dir = module_dir;

    const artifact = switch (try lang.build(&vm, .{ .name = source_name, .text = code }, .{})) {
        .ok => |ok| ok,
        .err => |lang_err| {
            defer lang.deinitError(alloc, lang_err);
            return error.ParseError;
        },
    };
    defer vm.runtime.alloc.free(artifact.instructions);
    defer vm.runtime.alloc.free(artifact.spans);

    _ = try runCompiledSessionReport(&vm, source_name, artifact.instructions);
    try std.testing.expectEqual(Data.new.num(1), vm.mainResult());

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "hot.rv",
        .data =
        \\ pub const value = 2
        ,
    });

    _ = try runCompiledSessionReport(&vm, source_name, artifact.instructions);
    try std.testing.expectEqual(Data.new.num(2), vm.mainResult());
}
