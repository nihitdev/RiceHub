const std = @import("std");
const api = @import("api.zig");
fn serve(init: std.process.Init, stream: std.Io.net.Stream) void {
    defer stream.close(init.io);
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;
    var reader = stream.reader(init.io, &read_buffer);
    var writer = stream.writer(init.io, &write_buffer);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    var req = server.receiveHead() catch return;
    const context = @import("system.zig").Context{ .allocator = arena.allocator(), .io = init.io, .env = init.environ_map };
    api.handle(context, &req) catch |err| {
        std.log.err("request failed: {s}", .{@errorName(err)});
        api.internalError(context, &req);
    };
}
pub fn main(init: std.process.Init) !void {
    defer @import("controls.zig").jobs.cancel(init.io);
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 7070);
    var listener = try address.listen(init.io, .{ .reuse_address = true });
    defer listener.deinit(init.io);
    var group: std.Io.Group = .init;
    defer group.cancel(init.io);
    std.log.info("RiceHub API listening on http://127.0.0.1:7070", .{});
    while (true) {
        const stream = try listener.accept(init.io);
        group.concurrent(init.io, serve, .{ init, stream }) catch |err| {
            stream.close(init.io);
            std.log.warn("could not accept client: {s}", .{@errorName(err)});
        };
    }
}
