const std = @import("std");

const revo = @import("revo");
const lang = @import("./root.zig");
const VM = revo.VM;

pub const FileId = u32;

pub const Snapshot = struct {
    id: FileId,
    version: u32,
    name: []const u8,
    text: []const u8,
};

const FileEntry = struct {
    id: FileId,
    version: u32,
    name: []u8,
    text: []u8,
};

const CacheEntry = struct {
    version: u32,
    opts: lang.BuildOptions,
    artifact: lang.Artifact,
};

pub const Workspace = struct {
    alloc: std.mem.Allocator,
    vm: *VM,
    files: std.ArrayList(FileEntry),
    file_index: std.AutoHashMap(FileId, usize),
    file_names: std.StringHashMap(FileId),
    dependencies: std.AutoHashMap(FileId, []FileId),
    reverse_deps: std.AutoHashMap(FileId, []FileId),
    cache: std.AutoHashMap(FileId, CacheEntry),
    next_file_id: FileId = 1,

    pub fn init(vm: *VM, alloc: std.mem.Allocator) !Workspace {
        return .{
            .alloc = alloc,
            .vm = vm,
            .files = try std.ArrayList(FileEntry).initCapacity(alloc, 8),
            .file_index = std.AutoHashMap(FileId, usize).init(alloc),
            .file_names = std.StringHashMap(FileId).init(alloc),
            .dependencies = std.AutoHashMap(FileId, []FileId).init(alloc),
            .reverse_deps = std.AutoHashMap(FileId, []FileId).init(alloc),
            .cache = std.AutoHashMap(FileId, CacheEntry).init(alloc),
        };
    }

    pub fn deinit(self: *Workspace) void {
        self.clearFiles();
        self.clearCache();
        self.clearDeps();
        self.files.deinit(self.alloc);
        self.file_index.deinit();
        self.file_names.deinit();
        self.dependencies.deinit();
        self.reverse_deps.deinit();
        self.cache.deinit();
    }

    pub fn open(self: *Workspace, name: []const u8, text: []const u8) !FileId {
        if (self.file_names.get(name)) |id| {
            try self.change(id, text);
            return id;
        }

        const name_copy = try self.alloc.dupe(u8, name);
        const text_copy = try self.alloc.dupe(u8, text);
        var stored = false;
        errdefer if (!stored) {
            self.alloc.free(name_copy);
            self.alloc.free(text_copy);
        };

        const id = self.next_file_id;
        self.next_file_id += 1;

        try self.files.append(self.alloc, .{
            .id = id,
            .version = 1,
            .name = name_copy,
            .text = text_copy,
        });
        stored = true;
        errdefer {
            const removed = self.files.pop().?;
            self.alloc.free(removed.name);
            self.alloc.free(removed.text);
        }
        const index = self.files.items.len - 1;

        try self.file_index.put(id, index);
        errdefer _ = self.file_index.remove(id);

        try self.file_names.put(name_copy, id);
        errdefer _ = self.file_names.remove(name_copy);

        return id;
    }

    pub fn change(self: *Workspace, id: FileId, text: []const u8) !void {
        const entry = try self.entryPtr(id);
        const text_copy = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(text_copy);
        self.alloc.free(entry.text);
        entry.text = text_copy;
        entry.version += 1;
        self.invalidateCache(id);
    }

    pub fn close(self: *Workspace, id: FileId) void {
        const index = self.file_index.get(id) orelse return;
        const removed = self.files.swapRemove(index).?;
        self.invalidateCache(id);
        self.removeDeps(id);
        if (self.reverse_deps.fetchRemove(id)) |kv| {
            self.alloc.free(kv.value);
        }
        _ = self.file_names.remove(removed.name);
        _ = self.file_index.remove(id);
        self.alloc.free(removed.name);
        self.alloc.free(removed.text);
        if (index < self.files.items.len) {
            const moved = self.files.items[index];
            self.file_index.put(moved.id, index) catch {};
        }
    }

    pub fn snapshot(self: *Workspace, id: FileId) ?Snapshot {
        const index = self.file_index.get(id) orelse return null;
        const entry = self.files.items[index];
        return .{
            .id = entry.id,
            .version = entry.version,
            .name = entry.name,
            .text = entry.text,
        };
    }

    pub fn analyze(
        self: *Workspace,
        alloc: std.mem.Allocator,
        id: FileId,
        opts: lang.BuildOptions,
    ) !lang.BuildResult {
        const snap = self.snapshot(id) orelse return error.FileNotOpen;
        if (self.cache.get(id)) |cached| {
            if (cached.version == snap.version and sameOpts(cached.opts, opts)) {
                const artifact = try copyArtifact(alloc, cached.artifact);
                errdefer deinitArtifact(alloc, artifact);
                if (opts.install_debug_info) {
                    try self.vm.setProgramDebugInfo(artifact.spans, snap.text, snap.name);
                }
                return .{ .ok = artifact };
            }
        }

        const build_result = try lang.build(self.vm, .{
            .name = snap.name,
            .text = snap.text,
        }, opts);

        return switch (build_result) {
            .ok => |artifact| blk: {
                errdefer deinitArtifact(self.vm.runtime.alloc, artifact);
                const cache_artifact = try copyArtifact(self.alloc, artifact);
                errdefer deinitArtifact(self.alloc, cache_artifact);
                const deps = try self.collectDeps(snap, opts);
                errdefer self.alloc.free(deps);
                try self.updateDeps(id, deps);
                try self.putCache(id, snap.version, opts, cache_artifact);
                const copy = try copyArtifact(alloc, artifact);
                errdefer deinitArtifact(alloc, copy);
                break :blk .{ .ok = copy };
            },
            .err => |err| .{ .err = err },
        };
    }

    pub fn analyzeSource(
        self: *Workspace,
        alloc: std.mem.Allocator,
        name: []const u8,
        text: []const u8,
        opts: lang.BuildOptions,
    ) !lang.BuildResult {
        const id = try self.open(name, text);
        return self.analyze(alloc, id, opts);
    }

    fn putCache(
        self: *Workspace,
        id: FileId,
        version: u32,
        opts: lang.BuildOptions,
        artifact: lang.Artifact,
    ) !void {
        const entry = CacheEntry{
            .version = version,
            .opts = opts,
            .artifact = artifact,
        };
        if (self.cache.getPtr(id)) |slot| {
            deinitArtifact(self.alloc, slot.artifact);
            slot.* = entry;
        } else {
            try self.cache.put(id, entry);
        }
    }

    fn invalidateCache(self: *Workspace, id: FileId) void {
        var visited = std.AutoHashMap(FileId, void).init(self.alloc);
        defer visited.deinit();
        self.invalidateCacheImpl(id, &visited);
    }

    fn invalidateCacheImpl(
        self: *Workspace,
        id: FileId,
        visited: *std.AutoHashMap(FileId, void),
    ) void {
        if (visited.contains(id)) return;
        visited.put(id, {}) catch return;

        if (self.cache.fetchRemove(id)) |kv| {
            deinitArtifact(self.alloc, kv.value.artifact);
        }

        if (self.reverse_deps.get(id)) |dependents| {
            for (dependents) |dep| self.invalidateCacheImpl(dep, visited);
        }
    }

    fn collectDeps(
        self: *Workspace,
        snap: Snapshot,
        opts: lang.BuildOptions,
    ) ![]FileId {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();

        const parsed = try lang.parse(arena.allocator(), .{
            .name = snap.name,
            .text = snap.text,
        }, .{
            .include_default_macros = opts.include_default_macros,
        });

        const root = switch (parsed) {
            .ok => |ok| ok.root,
            .err => return try self.alloc.alloc(FileId, 0),
        };

        var out = try std.ArrayList(FileId).initCapacity(self.alloc, 4);
        errdefer out.deinit(self.alloc);

        var visitor = ImportVisitor{
            .ws = self,
            .out = &out,
            .base = snap.name,
            .failed = false,
        };
        visitor.visit(root);
        if (visitor.failed) return error.OutOfMemory;
        return out.toOwnedSlice(self.alloc);
    }

    fn resolveOpenImport(
        self: *Workspace,
        source_name: []const u8,
        raw_path: []const u8,
    ) ?FileId {
        const resolved = self.resolveImportPath(source_name, raw_path) orelse return null;
        defer self.alloc.free(resolved);
        return self.file_names.get(resolved);
    }

    fn resolveImportPath(
        self: *Workspace,
        source_name: []const u8,
        raw_path: []const u8,
    ) ?[]u8 {
        const base_dir = std.fs.path.dirname(source_name) orelse ".";
        const joined = if (std.fs.path.isAbsolute(raw_path))
            self.alloc.dupe(u8, raw_path) catch return null
        else
            std.fs.path.join(self.alloc, &.{ base_dir, raw_path }) catch return null;
        if (std.fs.path.extension(joined).len != 0) return joined;
        const with_ext = std.fmt.allocPrint(self.alloc, "{s}.rv", .{joined}) catch {
            self.alloc.free(joined);
            return null;
        };
        self.alloc.free(joined);
        return with_ext;
    }

    fn updateDeps(self: *Workspace, id: FileId, new_deps: []FileId) !void {
        const old_deps = if (self.dependencies.fetchRemove(id)) |kv| kv.value else &.{};

        if (old_deps.len != 0) {
            for (old_deps) |dep| {
                if (!containsId(new_deps, dep)) try self.removeReverseDep(dep, id);
            }
            self.alloc.free(old_deps);
        }

        if (new_deps.len != 0) {
            for (new_deps) |dep| {
                if (!containsId(old_deps, dep)) try self.addReverseDep(dep, id);
            }
            try self.dependencies.put(id, new_deps);
        } else {
            self.alloc.free(new_deps);
        }
    }

    fn removeDeps(self: *Workspace, id: FileId) void {
        if (self.dependencies.fetchRemove(id)) |kv| {
            for (kv.value) |dep| self.removeReverseDep(dep, id) catch {};
            self.alloc.free(kv.value);
        }
    }

    fn addReverseDep(self: *Workspace, dep: FileId, id: FileId) !void {
        const current = self.reverse_deps.get(dep);
        if (current) |items| {
            if (containsId(items, id)) return;
            const next = try self.alloc.alloc(FileId, items.len + 1);
            @memcpy(next[0..items.len], items);
            next[items.len] = id;
            self.alloc.free(items);
            try self.reverse_deps.put(dep, next);
        } else {
            const next = try self.alloc.alloc(FileId, 1);
            next[0] = id;
            try self.reverse_deps.put(dep, next);
        }
    }

    fn removeReverseDep(self: *Workspace, dep: FileId, id: FileId) !void {
        const current = self.reverse_deps.get(dep) orelse return;
        var pos: ?usize = null;
        for (current, 0..) |item, idx| {
            if (item == id) {
                pos = idx;
                break;
            }
        }
        const idx = pos orelse return;
        if (current.len == 1) {
            self.alloc.free(current);
            _ = self.reverse_deps.remove(dep);
            return;
        }
        const next = try self.alloc.alloc(FileId, current.len - 1);
        @memcpy(next[0..idx], current[0..idx]);
        @memcpy(next[idx..], current[idx + 1 ..]);
        self.alloc.free(current);
        try self.reverse_deps.put(dep, next);
    }

    fn clearFiles(self: *Workspace) void {
        while (self.files.items.len != 0) {
            const entry = self.files.pop().?;
            self.alloc.free(entry.name);
            self.alloc.free(entry.text);
        }
    }

    fn clearCache(self: *Workspace) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            deinitArtifact(self.alloc, entry.value_ptr.artifact);
        }
    }

    fn clearDeps(self: *Workspace) void {
        var it = self.dependencies.iterator();
        while (it.next()) |entry| self.alloc.free(entry.value_ptr.*);
        it = self.reverse_deps.iterator();
        while (it.next()) |entry| self.alloc.free(entry.value_ptr.*);
        self.dependencies.clearRetainingCapacity();
        self.reverse_deps.clearRetainingCapacity();
    }

    fn entryPtr(self: *Workspace, id: FileId) !*FileEntry {
        const index = self.file_index.get(id) orelse return error.FileNotOpen;
        return &self.files.items[index];
    }
};

fn sameOpts(a: lang.BuildOptions, b: lang.BuildOptions) bool {
    return a.include_default_macros == b.include_default_macros and
        a.install_debug_info == b.install_debug_info and
        a.test_mode == b.test_mode;
}

fn copyArtifact(alloc: std.mem.Allocator, artifact: lang.Artifact) !lang.Artifact {
    return .{
        .instructions = try alloc.dupe(revo.Instruction, artifact.instructions),
        .spans = try alloc.dupe(lang.Span, artifact.spans),
    };
}

fn deinitArtifact(alloc: std.mem.Allocator, artifact: lang.Artifact) void {
    alloc.free(artifact.instructions);
    alloc.free(artifact.spans);
}

fn containsId(items: []const FileId, id: FileId) bool {
    for (items) |item|
        if (item == id) return true;

    return false;
}

const ImportVisitor = struct {
    ws: *Workspace,
    out: *std.ArrayList(FileId),
    base: []const u8,
    failed: bool,

    pub fn visit(self: *@This(), node: *const lang.Node) void {
        if (node.expr == .import_expr) {
            const path = node.expr.import_expr;
            const raw = switch (path.expr) {
                .string => path.expr.string,
                .multiline_string => path.expr.multiline_string,
                else => "",
            };
            if (raw.len != 0) {
                if (self.ws.resolveOpenImport(self.base, raw)) |id| {
                    if (!containsId(self.out.items, id)) {
                        self.out.append(self.ws.alloc, id) catch {
                            self.failed = true;
                        };
                    }
                }
            }
        }
        lang.ast.walkAST(ImportVisitor, self, node);
    }
};

test "workspace caches repeated analysis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var vm = try VM.init(.{ .alloc = alloc, .io = std.testing.io });
    defer vm.deinit();

    var ws = try Workspace.init(&vm, alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "1 + 1");
    const first = try ws.analyze(alloc, id, .{});
    defer switch (first) {
        .ok => |artifact| {
            alloc.free(artifact.instructions);
            alloc.free(artifact.spans);
        },
        .err => |err| lang.deinitError(alloc, err),
    };
    try std.testing.expect(first == .ok);

    const second = try ws.analyze(alloc, id, .{});
    defer switch (second) {
        .ok => |artifact| {
            alloc.free(artifact.instructions);
            alloc.free(artifact.spans);
        },
        .err => |err| lang.deinitError(alloc, err),
    };
    try std.testing.expect(second == .ok);
    try std.testing.expectEqual(first.ok.instructions.len, second.ok.instructions.len);
}

test "workspace invalidates cache on change" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var vm = try VM.init(.{ .alloc = alloc, .io = std.testing.io });
    defer vm.deinit();

    var ws = try Workspace.init(&vm, alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "1 + 1");
    const first = try ws.analyze(alloc, id, .{});
    defer switch (first) {
        .ok => |artifact| {
            alloc.free(artifact.instructions);
            alloc.free(artifact.spans);
        },
        .err => |err| lang.deinitError(alloc, err),
    };

    try ws.change(id, "1 + 2");
    const snap = ws.snapshot(id).?;
    try std.testing.expectEqual(@as(u32, 2), snap.version);

    const second = try ws.analyze(alloc, id, .{});
    defer switch (second) {
        .ok => |artifact| {
            alloc.free(artifact.instructions);
            alloc.free(artifact.spans);
        },
        .err => |err| lang.deinitError(alloc, err),
    };
    try std.testing.expect(second == .ok);
}

test "workspace invalidates dependent caches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var vm = try VM.init(.{ .alloc = alloc, .io = std.testing.io });
    defer vm.deinit();

    var ws = try Workspace.init(&vm, alloc);
    defer ws.deinit();

    const a = try ws.open("dir/a.rv", "1");
    const b = try ws.open("dir/b.rv", "import \"a\"");
    const c = try ws.open("dir/c.rv", "import \"b\"");

    const res_b = try ws.analyze(alloc, b, .{});
    defer switch (res_b) {
        .ok => |artifact| {
            alloc.free(artifact.instructions);
            alloc.free(artifact.spans);
        },
        .err => |err| lang.deinitError(alloc, err),
    };

    const res_c = try ws.analyze(alloc, c, .{});
    defer switch (res_c) {
        .ok => |artifact| {
            alloc.free(artifact.instructions);
            alloc.free(artifact.spans);
        },
        .err => |err| lang.deinitError(alloc, err),
    };

    try std.testing.expect(ws.cache.get(b) != null);
    try std.testing.expect(ws.cache.get(c) != null);

    try ws.change(a, "2");

    try std.testing.expect(ws.cache.get(b) == null);
    try std.testing.expect(ws.cache.get(c) == null);
}
