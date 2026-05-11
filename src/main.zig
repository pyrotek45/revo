const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const revo = @import("revo");
const Artifact = revo.lang.Artifact;
const VM = revo.VM;
const pretty = revo.pretty;

const repl = @import("repl.zig");

const USAGE =
    \\usage: revo [options] [script [args...]]
    \\
    \\options:
    \\  -e code          run code
    \\  -i               enter interactive mode after executing
    \\  -d               output the last value the program evaluated
    \\  -b               compile script to bytecode (.rvo)
    \\  -o path          output path for -b (default: input with .rvo extension)
    \\  --test           run test blocks
    \\  --bench          run with performance counters
    \\  --dis            show bytecode disassembly instead of running
    \\  -h, --help       show this help message
    \\  --version        show version
    \\
    \\examples:
    \\  revo                           start interactive REPL
    \\  revo script.rv                 run script
    \\  revo -e "1 + 2"                run inline code
    \\  revo -e "1 + 2" -i             run inline code and enter REPL
    \\  revo -b script.rv              compile script to bytecode
    \\  revo -b -o output.rvo script   compile script with custom output path
    \\  revo --bench script.rv         run with performance counters
    \\  revo --dis script.rv           show bytecode disassembly
    \\
    \\revo uses a modified version of the GPLv3, refer to LICENSE.md
    \\https://gills.pages.dev/revo/LICENSE.txt; sha256:415d4cce
;

fn printPrettyError(init: std.process.Init, comptime fmt: []const u8, args: anytype) void {
    var buf = std.Io.Writer.Allocating.init(init.gpa);
    defer buf.deinit();
    pretty.printError(init.gpa, &buf.writer, fmt, args) catch return;
    std.debug.print("{s}", .{buf.written()});
}

fn printPrettySuccess(init: std.process.Init, comptime fmt: []const u8, args: anytype) void {
    var buf = std.Io.Writer.Allocating.init(init.gpa);
    defer buf.deinit();
    pretty.printSuccess(init.gpa, &buf.writer, fmt, args) catch return;
    std.debug.print("{s}", .{buf.written()});
}

fn runMain(init: std.process.Init) !void {
    var arena_instance = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        // not Runtime because i'm using C line editors that don't accept readers/writers
        var vm = VM.init(.{ .alloc = init.gpa, .io = init.io }) catch |err| {
            printPrettyError(init, "initializing vm - {}", .{err});
            return error.VmInitError;
        };
        defer vm.deinit();
        try repl.run(&vm, init.gpa, init);
        return;
    }

    var inline_code: ?[]const u8 = null;
    var interactive = false;
    var script_path: ?[]const u8 = null;
    var show_dis = false;
    var compile_to_bytecode = false;
    var output_path: ?[]const u8 = null;
    var bench_mode = false;
    var test_mode = false;
    var bench_iters: u32 = 10;
    var echo_last: bool = false;
    var i: usize = 1;

    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-e")) {
            i += 1;
            if (i >= args.len) {
                printPrettyError(init, "-e requires an argument", .{});
                return error.InsufficientArgs;
            }
            inline_code = args[i];
        } else if (std.mem.eql(u8, arg, "-i")) {
            interactive = true;
        } else if (std.mem.eql(u8, arg, "-d")) {
            echo_last = true;
        } else if (std.mem.eql(u8, arg, "-b")) {
            compile_to_bytecode = true;
        } else if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) {
                printPrettyError(init, "-o requires an argument", .{});
                return error.InsufficientArgs;
            }
            output_path = args[i];
        } else if (std.mem.eql(u8, arg, "--bench")) {
            bench_mode = true;
        } else if (std.mem.eql(u8, arg, "--test")) {
            test_mode = true;
        } else if (std.mem.eql(u8, arg, "--iters")) {
            i += 1;
            if (i >= args.len) {
                printPrettyError(init, "--iters requires an argument", .{});
                return error.InsufficientArgs;
            }
            bench_iters = std.fmt.parseUnsigned(u32, args[i], 10) catch |err| {
                printPrettyError(init, "invalid --iters value '{s}' - {}", .{ args[i], err });
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, arg, "--dis")) {
            show_dis = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}\n", .{USAGE});
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("revo " ++ @import("build_options").version ++ "\n", .{});
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            printPrettyError(init, "unknown option '{s}'", .{arg});
            std.debug.print("{s}\n", .{USAGE});
            return error.UnknownCommand;
        } else {
            script_path = arg;
            break;
        }
        i += 1;
    }

    if (inline_code) |code| {
        var vm = VM.init(.{ .alloc = init.gpa, .io = init.io }) catch |err| {
            printPrettyError(init, "initializing vm - {}", .{err});
            return error.VmInitError;
        };
        defer vm.deinit();

        const build_result = revo.lang.build(&vm, .{ .name = "<inline>", .text = code }, .{ .test_mode = test_mode }) catch |err| {
            printPrettyError(init, "compilation - {}", .{err});
            return error.CompilationError;
        };

        const artifact = switch (build_result) {
            .ok => |art| art,
            .err => |lang_err| {
                std.debug.print("lang - ", .{});
                var buf = std.Io.Writer.Allocating.init(init.gpa);
                defer buf.deinit();
                revo.lang.renderError(init.gpa, &buf.writer, .{ .name = "<inline>", .text = code }, lang_err) catch |render_err| {
                    std.debug.print("while rendering lang error - {}\n", .{render_err});
                };
                std.debug.print("{s}", .{buf.written()});
                return error.CompilationError;
            },
        };
        defer init.gpa.free(artifact.instructions);
        defer init.gpa.free(artifact.spans);

        if (show_dis) {
            printDisassembly(artifact, code, false);
        } else {
            vm.setProgramDebugInfo(artifact.spans, code, "<inline>") catch |err| {
                std.debug.print("debug info {}\n", .{err});
            };
            const run_result = try revo.module.runCompiledModuleReport(&vm, "<inline>", artifact.instructions);
            switch (run_result) {
                .ok => {
                    if (echo_last) try printResult(init, &vm);
                },
                .err => |failure| try renderRTFailure(init, failure),
            }
        }
        if (!interactive and script_path == null) return;
    }

    if (script_path) |path| {
        const source = std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, std.Io.Limit.unlimited) catch |err| {
            printPrettyError(init, "{s} '{s}'", .{ @errorName(err), path });
            return error.FileError;
        };

        // bytecode path
        if (std.mem.endsWith(u8, path, ".rvo")) {
            if (show_dis) {
                var vm = VM.init(.{ .alloc = init.gpa, .io = init.io }) catch |err| {
                    printPrettyError(init, "initializing vm - {}", .{err});
                    return error.VmInitError;
                };
                defer vm.deinit();
                var deserialized = revo.bytecode.deserialize(&vm, source, init.gpa) catch |err| {
                    printPrettyError(init, "deserializing bytecode - {}", .{err});
                    return error.CompilationError;
                };
                defer deserialized.deinit();
                printDisassembly(.{
                    .instructions = deserialized.instructions,
                    .spans = deserialized.spans,
                }, "", false);
            } else if (bench_mode) {
                try benchBytecode(init, init.gpa, path, source, bench_iters, echo_last);
            } else {
                try runBytecode(init, init.gpa, path, source, echo_last);
            }
        } else {
            // source path
            if (compile_to_bytecode) {
                try compileToBytecode(init, init.gpa, arena, path, source, output_path, test_mode);
            } else if (show_dis) {
                var vm = VM.init(.{ .alloc = init.gpa, .io = init.io }) catch |err| {
                    printPrettyError(init, "initializing vm - {}", .{err});
                    return error.VmInitError;
                };
                defer vm.deinit();

                const build_result = revo.lang.build(&vm, .{ .name = path, .text = source }, .{ .test_mode = test_mode }) catch |err| {
                    printPrettyError(init, "compilation error - {}", .{err});
                    return error.CompilationError;
                };
                const artifact = switch (build_result) {
                    .ok => |art| art,
                    .err => |lang_err| {
                        std.debug.print("lang error: ", .{});
                        var buf = std.Io.Writer.Allocating.init(init.gpa);
                        defer buf.deinit();
                        revo.lang.renderError(init.gpa, &buf.writer, .{ .name = path, .text = source }, lang_err) catch |render_err| {
                            std.debug.print("while rendering lang error - {}\n", .{render_err});
                        };
                        std.debug.print("{s}", .{buf.written()});
                        return error.CompilationError;
                    },
                };
                defer init.gpa.free(artifact.instructions);
                defer init.gpa.free(artifact.spans);
                printDisassembly(artifact, source, false);
            } else if (bench_mode) {
                try benchSource(init, init.gpa, path, source, bench_iters, echo_last, test_mode);
            } else {
                try runSource(init, init.gpa, path, source, echo_last, test_mode);
            }
        }
        if (!interactive) return;
    }

    var vm = VM.init(.{ .alloc = init.gpa, .io = init.io }) catch |err| {
        std.debug.print("initializing vm - {}\n", .{err});
        return error.VmInitError;
    };
    defer vm.deinit();
    try repl.run(&vm, init.gpa, init);
}

pub fn main(init: std.process.Init) void {
    runMain(init) catch |x| switch (x) {
        error.VmInitError,
        error.InsufficientArgs,
        error.InvalidArgs,
        error.UnknownCommand,
        error.CompilationError,
        error.FileError,
        => {},
        else => |err| {
            var stderr_buf: [256]u8 = undefined;
            var stderr = std.Io.File.stderr().writer(init.io, &stderr_buf);
            pretty.printErrorName(init.gpa, &stderr.interface, err) catch return;
        },
    };
}

fn printRuntimeFailure(init: std.process.Init, failure: anytype, source: []const u8) void {
    var buf = std.Io.Writer.Allocating.init(init.gpa);
    defer buf.deinit();
    failure.render(init.gpa, &buf.writer, source) catch |render_err| {
        printPrettyError(init, "while rendering runtime error - {}", .{render_err});
        return;
    };
    std.debug.print("{s}", .{buf.written()});
}

fn printResult(init: std.process.Init, vm: *VM) !void {
    var res = std.ArrayList(u8).initCapacity(vm.runtime.alloc, 1024) catch return;
    vm.mainResult().write(&res, vm, .debug) catch return;
    const s = res.toOwnedSlice(init.gpa) catch return;
    defer init.gpa.free(s);
    std.debug.print("{s}", .{s});
}

fn runSource(init: std.process.Init, gpa: Allocator, path: []const u8, source: []const u8, echo_last: bool, test_mode: bool) !void {
    var vm = VM.init(.{ .alloc = gpa, .io = init.io }) catch |err| {
        printPrettyError(init, "initializing vm - {}", .{err});
        return error.VmInitError;
    };
    defer vm.deinit();

    const build_result = revo.lang.build(&vm, .{ .name = path, .text = source }, .{ .test_mode = test_mode }) catch |err| {
        printPrettyError(init, "compilation - {}", .{err});
        return error.CompilationError;
    };
    const artifact = switch (build_result) {
        .ok => |art| art,
        .err => |lang_err| {
            std.debug.print("build", .{});
            var buf = std.Io.Writer.Allocating.init(gpa);
            defer buf.deinit();
            try revo.lang.renderError(gpa, &buf.writer, .{ .name = path, .text = source }, lang_err);
            std.debug.print("{s}", .{buf.written()});
            return error.CompilationError;
        },
    };
    defer gpa.free(artifact.instructions);
    defer gpa.free(artifact.spans);

    try vm.setProgramDebugInfo(artifact.spans, source, path);

    const run_result = try revo.module.runCompiledModuleReport(&vm, path, artifact.instructions);
    switch (run_result) {
        .ok => if (echo_last) try printResult(init, &vm),
        .err => |failure| printRuntimeFailure(init, failure, source),
    }
}

fn runBytecode(init: std.process.Init, gpa: Allocator, path: []const u8, bytecode_data: []const u8, echo_last: bool) !void {
    var vm = VM.init(.{ .alloc = gpa, .io = init.io }) catch |err| {
        printPrettyError(init, "initializing vm - {}", .{err});
        return error.VmInitError;
    };
    defer vm.deinit();

    const deserialized = revo.bytecode.deserialize(&vm, bytecode_data, gpa) catch |err| {
        printPrettyError(init, "deserializing bytecode - {}", .{err});
        return error.CompilationError;
    };
    defer gpa.free(deserialized.instructions);
    defer gpa.free(deserialized.spans);

    vm.setProgramDebugInfo(deserialized.spans, "", path) catch |err| {
        std.debug.print("debug info error - {}\n", .{err});
    };

    const run_result = try revo.module.runCompiledModuleReport(&vm, path, deserialized.instructions);
    switch (run_result) {
        .ok => if (echo_last) try printResult(init, &vm),
        .err => |failure| try renderRTFailure(init, failure),
    }
}

fn compileToBytecode(init: std.process.Init, gpa: Allocator, arena: Allocator, path: []const u8, source: []const u8, opt_output_path: ?[]const u8, test_mode: bool) !void {
    var vm = VM.init(.{ .alloc = gpa, .io = init.io }) catch |err| {
        printPrettyError(init, "initializing vm - {}", .{err});
        return error.VmInitError;
    };
    defer vm.deinit();

    const build_result = revo.lang.build(&vm, .{ .name = path, .text = source }, .{ .test_mode = test_mode }) catch |err| {
        printPrettyError(init, "compilation error - {}", .{err});
        return error.CompilationError;
    };
    const artifact = switch (build_result) {
        .ok => |art| art,
        .err => |lang_err| {
            std.debug.print("lang error: ", .{});
            var buf = std.Io.Writer.Allocating.init(gpa);
            defer buf.deinit();
            revo.lang.renderError(gpa, &buf.writer, .{ .name = path, .text = source }, lang_err) catch |render_err| {
                printPrettyError(init, "rendering lang error - {}", .{render_err});
            };
            std.debug.print("{s}", .{buf.written()});
            return error.CompilationError;
        },
    };
    defer gpa.free(artifact.instructions);
    defer gpa.free(artifact.spans);

    const bytecode = revo.bytecode.serialize(&vm, artifact, gpa) catch |err| {
        printPrettyError(init, "serializing bytecode - {}", .{err});
        return error.CompilationError;
    };
    defer gpa.free(bytecode);

    const output_path: []const u8 = if (opt_output_path) |provided|
        provided
    else blk: {
        if (std.mem.endsWith(u8, path, ".rv")) {
            const base = path[0 .. path.len - 3];
            break :blk std.fmt.allocPrint(arena, "{s}.rvo", .{base}) catch {
                printPrettyError(init, "output path allocation failed", .{});
                return error.FileError;
            };
        } else {
            break :blk std.fmt.allocPrint(arena, "{s}.rvo", .{path}) catch {
                printPrettyError(init, "output path allocation failed", .{});
                return error.FileError;
            };
        }
    };

    std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = output_path,
        .data = bytecode,
    }) catch |err| {
        printPrettyError(init, "writing bytecode file '{s}' - {}", .{ output_path, err });
        return error.FileError;
    };

    printPrettySuccess(init, "compiled to {s}", .{output_path});
}

fn benchSource(init: std.process.Init, gpa: Allocator, path: []const u8, source: []const u8, iters: u32, echo_last: bool, test_mode: bool) !void {
    var vm = VM.init(.{ .alloc = gpa, .io = init.io }) catch |err| {
        printPrettyError(init, "initializing vm - {}", .{err});
        return error.VmInitError;
    };
    defer vm.deinit();

    const build_result = revo.lang.build(&vm, .{ .name = path, .text = source }, .{ .test_mode = test_mode }) catch |err| {
        printPrettyError(init, "compilation error - {}", .{err});
        return error.CompilationError;
    };
    const artifact = switch (build_result) {
        .ok => |art| art,
        .err => |lang_err| {
            std.debug.print("lang error: ", .{});
            var buf = std.Io.Writer.Allocating.init(gpa);
            defer buf.deinit();
            revo.lang.renderError(gpa, &buf.writer, .{ .name = path, .text = source }, lang_err) catch |render_err| {
                printPrettyError(init, "rendering lang error - {}", .{render_err});
            };
            std.debug.print("{s}", .{buf.written()});
            return error.CompilationError;
        },
    };
    defer gpa.free(artifact.instructions);
    defer gpa.free(artifact.spans);

    vm.setProgramDebugInfo(artifact.spans, source, path) catch |err| {
        std.debug.print("debug info error - {}\n", .{err});
    };

    var times = try std.ArrayList(std.Io.Duration).initCapacity(gpa, iters);
    defer times.deinit(gpa);

    for (0..iters) |_| {
        vm.resetPerfCounters();
        const t_start = std.Io.Timestamp.now(init.io, .cpu_process);
        const run_result = try revo.module.runCompiledModuleReport(&vm, path, artifact.instructions);
        const t_end = std.Io.Timestamp.now(init.io, .cpu_process);
        times.appendAssumeCapacity(t_start.durationTo(t_end));

        if (run_result == .err) {
            const failure = run_result.err;
            printRuntimeFailure(init, failure, source);
        }
    }

    vm.resetPerfCounters();
    const run_result = try revo.module.runCompiledModuleReport(&vm, path, artifact.instructions);
    switch (run_result) {
        .ok => if (echo_last) try printResult(init, &vm),
        .err => |failure| printRuntimeFailure(init, failure, source),
    }

    printBenchStats(&vm, times.items);
}

fn benchBytecode(init: std.process.Init, gpa: Allocator, path: []const u8, bytecode_data: []const u8, iters: u32, echo_last: bool) !void {
    var vm = VM.init(.{ .alloc = gpa, .io = init.io }) catch |err| {
        printPrettyError(init, "initializing vm - {}", .{err});
        return error.VmInitError;
    };
    defer vm.deinit();

    const deserialized = revo.bytecode.deserialize(&vm, bytecode_data, gpa) catch |err| {
        printPrettyError(init, "deserializing bytecode - {}", .{err});
        return error.CompilationError;
    };
    defer gpa.free(deserialized.instructions);
    defer gpa.free(deserialized.spans);

    vm.setProgramDebugInfo(deserialized.spans, "", path) catch |err| {
        std.debug.print("debug info error - {}\n", .{err});
    };

    var times = try std.ArrayList(std.Io.Duration).initCapacity(gpa, iters);
    defer times.deinit(gpa);

    for (0..iters) |_| {
        vm.resetPerfCounters();
        const t_start = std.Io.Timestamp.now(init.io, .cpu_process);
        const run_result = try revo.module.runCompiledModuleReport(&vm, path, deserialized.instructions);
        const t_end = std.Io.Timestamp.now(init.io, .cpu_process);
        times.appendAssumeCapacity(t_start.durationTo(t_end));

        if (run_result == .err) {
            const failure = run_result.err;
            printRuntimeFailure(init, failure, "");
        }
    }

    vm.resetPerfCounters();
    const run_result = try revo.module.runCompiledModuleReport(&vm, path, deserialized.instructions);
    switch (run_result) {
        .ok => if (echo_last) try printResult(init, &vm),
        .err => |failure| try renderRTFailure(init, failure),
    }

    printBenchStats(&vm, times.items);
}

fn printBenchStats(vm: *VM, times: []std.Io.Duration) void {
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

    const max_perf_field_len = comptime blk: {
        var a: usize = 0;
        for (@typeInfo(VM.PerfCounters).@"struct".fields) |field| {
            if (field.name.len > a) a = field.name.len;
        }
        break :blk a;
    };
    {
        const t = "timing";
        const b: usize = max_perf_field_len - t.len - 1;
        std.debug.print("\n+= {s} {s}+\n", .{ t, "=" ** b });
    }
    std.debug.print("| best    {d:.3}ms / {d}ns\n", .{ best_ms, best });
    std.debug.print("| median  {d:.3}ms / {d}ns\n", .{ median_ms, median });
    std.debug.print("| p95     {d:.3}ms / {d}ns\n", .{ p95_ms, p95 });
    std.debug.print("| worst   {d:.3}ms / {d}ns\n", .{ worst_ms, worst });

    {
        const t = "perf";
        const b: usize = max_perf_field_len - t.len - 1;
        std.debug.print("\n+= {s} {s}+\n", .{ t, "=" ** b });
    }

    inline for (@typeInfo(VM.PerfCounters).@"struct".fields) |field| {
        std.debug.print("| {s}{s}{d}\n", .{
            field.name,
            " " ** (max_perf_field_len - field.name.len + 1),
            @field(vm.perf, field.name),
        });
    }
}

fn printDisassembly(artifact: Artifact, source: []const u8, json: bool) void {
    if (!json) {
        std.debug.print(
            \\ pc  op                a  b  c    bx    src
            \\ --  ----------------  -  -  ---  ---  ---------
            \\
        , .{});
    }

    for (artifact.instructions, 0..) |instr, pc| {
        const span = if (pc < artifact.spans.len)
            artifact.spans[pc]
        else
            revo.lang.Span{ .start = 0, .end = 0, .line = 0, .column = 0 };

        if (json) continue;

        const op_name = @tagName(instr.op);

        // skipping prelude ops
        if (false and std.mem.eql(u8, op_name, "jump") or
            std.mem.eql(u8, op_name, "closure") or
            std.mem.eql(u8, op_name, "call") or
            std.mem.eql(u8, op_name, "halt") or
            std.mem.eql(u8, op_name, "ret") or
            std.mem.eql(u8, op_name, "load_const") or
            span.start >= source.len or
            (span.end - span.start) > 200)
        {
            continue;
        }

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

pub fn renderRTFailure(init: std.process.Init, failure: VM.EvalFailure) !void {
    printRuntimeFailure(init, failure, "");
}
