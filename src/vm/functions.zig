const std = @import("std");

const revo = @import("revo");

const mem = revo.memory;
const Data = mem.Data;
const t = revo.lang.testing;

const root = @import("root.zig");
pub const NativeError = revo.std_lib.NativeError;
pub const NativeErrPayload = revo.std_lib.NativeErrPayload;
pub const NativeResult = revo.std_lib.NativeResult;

pub const ProgramCounter = usize;
pub const LocalSlot = revo.opcode.Register;
pub const Register = revo.opcode.Register;
pub const RegisterCount = Register;
pub const PrototypeID = usize;
pub const UpvalueID = usize;

pub const Frame = struct {
    return_addr: ProgramCounter,
    call_site_pc: ?ProgramCounter = null,
    base: usize = 0,
    result_register: Register = 0,
    register_count: RegisterCount = 0,
    closure_id: ?mem.FunctionID = null,
};

pub const NativeFn = *const fn (args: []const Data, vm: *revo.VM) NativeResult;
pub const CFnPtr = *const fn (
    vm: *anyopaque,
    argc: usize,
    argv: [*]revo.ffi.CRevoData,
    out_result: *revo.ffi.CRevoData,
) callconv(.c) void;
/// TODO: make functions have fixed arity too
pub const VARIADIC: u8 = 0xFF;

pub const CFunction = struct {
    name: []const u8,
    fn_ptr: CFnPtr,
};

pub const UpvalueSpec = struct {
    is_local: bool,
    index: LocalSlot,
    mutable: bool,
};

pub const Prototype = struct {
    addr: ProgramCounter,
    arity: u8,
    register_count: RegisterCount = 0,
    name: []const u8,
    upvalue_specs: []UpvalueSpec,
    const_locals: []LocalSlot,
    const_local_bits: []u8,
};

pub const Closure = struct {
    prototype: PrototypeID,
    arity: u8,
    name: []const u8,
    upvalues: []UpvalueID,
};

pub const Upvalue = struct {
    open_index: ?usize,
    closed: Data,
};

pub const UpvalueSlot = struct {
    value: ?Upvalue = null,
    marked: bool = false,
    next_free: ?UpvalueID = null,
};

pub const FunctionSlot = struct {
    value: ?Function = null,
    marked: bool = false,
    next_free: ?mem.FunctionID = null,
};

pub const Function = union(enum) {
    closure: Closure,
    native: revo.std_lib.NativeFunc,
    c_function: CFunction,

    pub fn arity(self: Function) u8 {
        return switch (self) {
            .closure => |f| f.arity,
            .native => |f| @intCast(f.arity),
            .c_function => VARIADIC,
        };
    }

    pub fn name(self: Function) []const u8 {
        return switch (self) {
            .closure => |f| f.name,
            .native => "<native>",
            .c_function => |f| f.name,
        };
    }
};

pub const FunctionPool = struct {
    alloc: std.mem.Allocator,
    functions: std.ArrayList(FunctionSlot),
    prototypes: std.ArrayList(Prototype),
    upvalues: std.ArrayList(UpvalueSlot),
    free_head: ?mem.FunctionID = null,
    upvalue_free_head: ?UpvalueID = null,

    pub fn init(alloc: std.mem.Allocator) !FunctionPool {
        return .{
            .alloc = alloc,
            .functions = try std.ArrayList(FunctionSlot).initCapacity(alloc, 16),
            .prototypes = try std.ArrayList(Prototype).initCapacity(alloc, 16),
            .upvalues = try std.ArrayList(UpvalueSlot).initCapacity(alloc, 16),
        };
    }

    pub fn deinit(self: *FunctionPool) void {
        for (self.functions.items) |slot| {
            if (slot.value) |func| switch (func) {
                .closure => |closure| self.alloc.free(closure.upvalues),
                .c_function => {},
                .native => {},
            };
        }
        for (self.prototypes.items) |proto| {
            self.alloc.free(proto.name);
            self.alloc.free(proto.upvalue_specs);
            self.alloc.free(proto.const_locals);
            self.alloc.free(proto.const_local_bits);
        }
        self.functions.deinit(self.alloc);
        self.prototypes.deinit(self.alloc);
        self.upvalues.deinit(self.alloc);
    }

    pub fn create(self: *FunctionPool, func: Function) !mem.FunctionID {
        return try revo.allocSlot(FunctionSlot, mem.FunctionID, self.alloc, &self.functions, &self.free_head, .{ .value = func });
    }

    // dupes ownership name upbalue specs const locals dont forget to free at call site
    pub fn createPrototype(self: *FunctionPool, proto: Prototype) !PrototypeID {
        const const_bits_len = if (proto.const_local_bits.len != 0)
            proto.const_local_bits.len
        else blk: {
            var max_slot: usize = 0;
            for (proto.const_locals) |slot| {
                if (slot > max_slot) max_slot = slot;
            }
            break :blk if (proto.const_locals.len == 0) 0 else (max_slot / 8) + 1;
        };
        var const_bits = try self.alloc.alloc(u8, const_bits_len);
        errdefer self.alloc.free(const_bits);
        @memset(const_bits, 0);
        if (proto.const_local_bits.len != 0) {
            @memcpy(const_bits, proto.const_local_bits);
        } else {
            for (proto.const_locals) |slot| {
                const idx = slot / 8;
                const bit: u3 = @intCast(slot % 8);
                const_bits[idx] |= (@as(u8, 1) << bit);
            }
        }

        const id: PrototypeID = @intCast(self.prototypes.items.len);
        try self.prototypes.append(self.alloc, .{
            .addr = proto.addr,
            .arity = proto.arity,
            .register_count = proto.register_count,
            .name = try self.alloc.dupe(u8, proto.name),
            .upvalue_specs = try self.alloc.dupe(UpvalueSpec, proto.upvalue_specs),
            .const_locals = try self.alloc.dupe(LocalSlot, proto.const_locals),
            .const_local_bits = const_bits,
        });
        return id;
    }

    pub fn createClosure(self: *FunctionPool, prototype_id: PrototypeID, upvalues: []const UpvalueID) !mem.FunctionID {
        const proto = try self.getPrototype(prototype_id);
        return self.create(.{ .closure = .{
            .prototype = prototype_id,
            .arity = proto.arity,
            .name = proto.name,
            .upvalues = try self.alloc.dupe(UpvalueID, upvalues),
        } });
    }

    pub fn createUpvalue(self: *FunctionPool, upvalue: Upvalue) !UpvalueID {
        return try revo.allocSlot(UpvalueSlot, UpvalueID, self.alloc, &self.upvalues, &self.upvalue_free_head, .{ .value = upvalue });
    }

    pub fn get(self: *FunctionPool, id: mem.FunctionID) !*Function {
        if (id >= self.functions.items.len) return error.FunctionDNE;
        const slot = &self.functions.items[id];
        if (slot.value) |*func| return func;
        return error.FunctionDNE;
    }

    pub fn getPrototype(self: *FunctionPool, id: PrototypeID) !*Prototype {
        if (id >= self.prototypes.items.len) return error.FunctionDNE;
        return &self.prototypes.items[id];
    }

    pub fn getUpvalue(self: *FunctionPool, id: UpvalueID) !*Upvalue {
        if (id >= self.upvalues.items.len) return error.FunctionDNE;
        const slot = &self.upvalues.items[id];
        if (slot.value) |*upvalue| return upvalue;
        return error.FunctionDNE;
    }

    pub fn mark(self: *FunctionPool, id: mem.FunctionID, vm: *revo.VM) void {
        if (id >= self.functions.items.len) return;
        const slot = &self.functions.items[id];
        if (slot.value) |*func| {
            if (slot.marked) return;
            slot.marked = true;
            switch (func.*) {
                .closure => |closure| {
                    for (closure.upvalues) |upvalue_id| {
                        self.markUpvalue(upvalue_id, vm);
                    }
                },
                .native, .c_function => {},
            }
        }
    }

    pub fn markUpvalue(self: *FunctionPool, id: UpvalueID, vm: *revo.VM) void {
        if (id >= self.upvalues.items.len) return;
        const slot = &self.upvalues.items[id];
        if (slot.value) |*upvalue| {
            if (slot.marked) return;
            slot.marked = true;
            if (upvalue.open_index == null) vm.markData(upvalue.closed);
        }
    }

    pub fn sweep(self: *FunctionPool) void {
        revo.sweepSlots(FunctionSlot, mem.FunctionID, &self.functions, &self.free_head, self, FunctionPool.finalizeFunctionSlot);
        revo.sweepSlots(UpvalueSlot, UpvalueID, &self.upvalues, &self.upvalue_free_head, self, FunctionPool.finalizeUpvalueSlot);
    }

    fn finalizeFunctionSlot(slot: *FunctionSlot, self: *FunctionPool) void {
        if (slot.value) |func| {
            switch (func) {
                .closure => |closure| self.alloc.free(closure.upvalues),
                .native, .c_function => {},
            }
        }
    }

    fn finalizeUpvalueSlot(_: *UpvalueSlot, _: *FunctionPool) void {}

    pub fn bytes(self: *const FunctionPool) usize {
        var total: usize = 0;
        for (self.functions.items) |slot| {
            if (slot.value) |*func| {
                total += 48; // base
                switch (func.*) {
                    .closure => |closure| total += @sizeOf(UpvalueID) * closure.upvalues.len, // upvalue array
                    .native, .c_function => {},
                }
            }
        }
        for (self.upvalues.items) |slot| {
            if (slot.value != null)
                total += 24; // upvalue

        }
        return total;
    }
};

test "functions call with lexical locals" {
    try t.top_number(
        \\ const id = fn(x) x
        \\ id(42)
    , 42);
    try t.top_number(
        \\ const add = fn(a, b) a + b
        \\ add(20, 22)
    , 42);
    try t.top_number(
        \\ const forty_two = fn() 42
        \\ forty_two()
    , 42);
}

test "functions return exactly one value" {
    try t.top_number(
        \\ const f = fn() do
        \\     1
        \\     2
        \\ end
        \\ f()
    , 2);
    try t.top_number(
        \\ const f = fn() do
        \\     return 41
        \\     0
        \\ end
        \\ f()
    , 41);
    try t.top_nil(
        \\ const f = fn() do
        \\     return
        \\ end
        \\ f()
    );
    try t.top_type(
        \\ const f = fn() (1, 2)
        \\ f()
    , .tuple);
    try t.top_number(
        \\ const f = fn() do
        \\ return 1 2 end
        \\ f()
    , 1);
}

test "functions reject wrong arity" {
    try t.expectRuntimeError(
        \\ const id = fn(x) x
        \\ id()
    , .WrongArity);
    try t.expectRuntimeError(
        \\ const forty_two = fn() 42
        \\ forty_two(1)
    , .WrongArity);
    try t.expectRuntimeError(
        \\ const all = fn(a, b, c) a + b * c
        \\ all(1, 2)
    , .WrongArity);
    try t.expectRuntimeError(
        \\ const all = fn(a, b, c) a + b * c
        \\ all(1, 2, 3, 4)
    , .WrongArity);
}

test "function pool prototype ownership and upvalue slot reuse" {
    var pool = try FunctionPool.init(std.testing.allocator);
    defer pool.deinit();

    var name_buf = [_]u8{ 'f', 'n' };
    var specs = [_]UpvalueSpec{.{ .is_local = true, .index = 0, .mutable = false }};
    var consts = [_]LocalSlot{1};

    const proto_id = try pool.createPrototype(.{
        .addr = 9,
        .arity = 1,
        .name = name_buf[0..],
        .upvalue_specs = specs[0..],
        .const_locals = consts[0..],
        .const_local_bits = &.{},
    });

    name_buf[0] = 'x';
    specs[0].index = 99;
    consts[0] = 77;

    const stored = try pool.getPrototype(proto_id);
    try std.testing.expectEqualStrings("fn", stored.name);
    try std.testing.expectEqual(@as(LocalSlot, 0), stored.upvalue_specs[0].index);
    try std.testing.expectEqual(@as(LocalSlot, 1), stored.const_locals[0]);

    const up_id = try pool.createUpvalue(.{ .open_index = null, .closed = Data.new.num(1) });
    pool.sweep();
    const up_reused = try pool.createUpvalue(.{ .open_index = null, .closed = Data.new.num(2) });
    try std.testing.expectEqual(up_id, up_reused);
}
