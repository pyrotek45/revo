//
// stands for "i am stupid", or unsafe
//

const revo = @import("../root.zig");
const testing = revo.lang.testing;
const root = @import("root.zig");

const Data = revo.Data;
const VM = revo.VM;
const NativeResult = root.NativeResult;
const dataToString = root.dataToString;

pub fn eval(args: []const Data, vm: *VM) !NativeResult {
    if (args.len != 1) return .errArity(args.len, 1);

    const source = switch (args[0]) {
        .string => |id| vm.stringValue(id),
        else => return .errType(0, "string", dataToString(args[0])),
    };

    const source_name = "<eval>";
    const res = revo.module.runModuleReport(vm, source_name, source) catch {
        return .other("eval failed");
    };

    return switch (res) {
        .ok => root.resultTuple(vm, .ok, vm.currentFiber().result),
        .err => |err| {
            const err_str = try vm.ownDataString(err.message);
            return root.resultTuple(vm, .err, err_str);
        },
    };
}

test "native eval works" {
    try testing.top_number(
        \\ const (_, res) = @eval("21*2")
        \\ res
    , 42);
}
