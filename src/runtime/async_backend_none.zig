const async_backend = @import("./async_backend.zig");

pub const BackendState = struct {};

pub fn init(_: *BackendState) anyerror!void {
    return;
}

pub fn deinit(_: *BackendState) void {}

pub fn submit(_: *BackendState, _: *anyopaque, _: *async_backend.AsyncJob) anyerror!async_backend.AsyncTicket {
    return error.OsNotSupported;
}

pub fn poll_all(_: *BackendState, _: *anyopaque, _: i32) anyerror!bool {
    return false;
}
