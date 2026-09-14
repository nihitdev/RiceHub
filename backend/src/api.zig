const std = @import("std");
const sys = @import("system.zig");
const commands = @import("commands.zig");
const config = @import("config.zig");
const controls = @import("controls.zig");
const Request = std.http.Server.Request;
fn json(c: sys.Context, req: *Request, status: std.http.Status, value: anytype) !void {
    const response_body = try std.json.Stringify.valueAlloc(c.allocator, value, .{});
    try req.respond(response_body, .{ .status = status, .keep_alive = false, .extra_headers = &.{
        .{ .name = "Content-Type", .value = "application/json; charset=utf-8" },
        .{ .name = "Cache-Control", .value = "no-store" },
        .{ .name = "X-Content-Type-Options", .value = "nosniff" },
    } });
}
fn header(req: *Request, name: []const u8) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}
fn isLocalHost(value: []const u8) bool {
    for ([_][]const u8{ "127.0.0.1:7070", "localhost:7070", "127.0.0.1:5173", "localhost:5173", "127.0.0.1:4173", "localhost:4173" }) |allowed| {
        if (std.mem.eql(u8, value, allowed)) return true;
    }
    return false;
}
pub fn handle(c: sys.Context, req: *Request) !void {
    if (!isLocalHost(header(req, "host") orelse "")) return json(c, req, .forbidden, .{ .error_message = "Untrusted Host" });
    if (header(req, "origin")) |origin| {
        if (!std.mem.startsWith(u8, origin, "http://") or !isLocalHost(origin[7..])) return json(c, req, .forbidden, .{ .error_message = "Untrusted Origin" });
    }
    if (std.mem.startsWith(u8, req.head.target, "/api/config/") or std.mem.startsWith(u8, req.head.target, "/api/controls/")) {
        extended(c, req) catch |err| try problem(c, req, err);
        return;
    }
    if (req.head.transfer_encoding != .none or (req.head.content_length orelse 0) != 0)
        return json(c, req, .bad_request, .{ .error_message = "Request bodies are not accepted" });
    const path = req.head.target;
    if (std.mem.eql(u8, path, "/api/hypr/reload")) {
        if (req.head.method != .POST) return json(c, req, .method_not_allowed, .{ .error_message = "Use POST" });
        if (!std.mem.eql(u8, header(req, "x-ricehub-action") orelse "", "reload")) return json(c, req, .forbidden, .{ .error_message = "Missing X-RiceHub-Action: reload header" });
        commands.reload(c) catch |err| return json(c, req, .service_unavailable, .{ .error_message = @errorName(err) });
        return json(c, req, .ok, .{ .ok = true, .message = "Hyprland configuration reloaded" });
    }
    const known = std.mem.eql(u8, path, "/api/system") or std.mem.eql(u8, path, "/api/memory") or std.mem.eql(u8, path, "/api/cpu") or std.mem.eql(u8, path, "/api/dotfiles");
    if (!known) return json(c, req, .not_found, .{ .error_message = "Endpoint not found" });
    if (req.head.method != .GET) return json(c, req, .method_not_allowed, .{ .error_message = "Use GET" });
    if (std.mem.eql(u8, path, "/api/system")) return json(c, req, .ok, sys.system(c));
    if (std.mem.eql(u8, path, "/api/memory")) return json(c, req, .ok, sys.memory(c));
    if (std.mem.eql(u8, path, "/api/cpu")) return json(c, req, .ok, sys.cpu(c));
    return json(c, req, .ok, try commands.dotfiles(c));
}
pub fn internalError(c: sys.Context, req: *Request) void {
    json(c, req, .internal_server_error, .{ .error_message = "Internal API error" }) catch {};
}

fn problem(c: sys.Context, req: *Request, err: anyerror) !void {
    const status: std.http.Status = switch (err) {
        error.InvalidPath, error.InvalidValue, error.InvalidService, error.InvalidJson, error.NoChanges, error.InvalidQuery => .bad_request,
        error.FileNotFound, error.UnknownService => .not_found,
        error.FileChanged, error.PackageManagerChanged, error.UpdateCheckBusy, error.UpdateTerminalAlreadyRunning => .conflict,
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFile, error.SymlinkNotAllowed, error.SymLinkLoop, error.ProtectedService => .forbidden,
        error.FileTooLarge, error.StreamTooLong => .payload_too_large,
        error.NotTextFile => .unsupported_media_type,
        else => .service_unavailable,
    };
    const message: []const u8 = switch (err) {
        error.FileChanged => "This file changed on disk. Reopen it and review your changes again.",
        error.SymlinkNotAllowed, error.SymLinkLoop, error.NotDir => "Symlinks are not followed. Open the real configuration directory instead.",
        error.InvalidPath => "Only relative config paths are allowed; parent paths and internal files are blocked.",
        error.NotTextFile => "Only UTF-8 text files can be opened in the editor.",
        error.FileTooLarge, error.StreamTooLong => "This file or request is too large. The editor supports text files up to 256 KiB.",
        error.ReadOnlyFile => "This file is read-only or has multiple hard links.",
        error.InvalidJson => "Invalid JSON fields or field types.",
        error.ProtectedService => "This session infrastructure service is read-only.",
        error.CheckupdatesUnavailable => "Install pacman-contrib to refresh available Arch updates.",
        error.TerminalLauncherUnavailable => "Install xdg-terminal-exec to open an interactive update terminal.",
        else => @errorName(err),
    };
    try json(c, req, status, .{ .error_message = message, .code = @errorName(err) });
}
fn queryPath(c: sys.Context, target: []const u8) ![]const u8 {
    const index = std.mem.indexOfScalar(u8, target, '?') orelse return "";
    const query = target[index + 1 ..];
    if (!std.mem.startsWith(u8, query, "path=") or std.mem.indexOfScalar(u8, query, '&') != null) return error.InvalidQuery;
    const raw = query[5..];
    var decoded: std.array_list.Managed(u8) = .init(c.allocator);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '%') {
            if (i + 2 >= raw.len) return error.InvalidQuery;
            const byte = std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16) catch return error.InvalidQuery;
            try decoded.append(byte);
            i += 2;
        } else try decoded.append(if (raw[i] == '+') ' ' else raw[i]);
    }
    return decoded.items;
}
fn body(comptime T: type, c: sys.Context, req: *Request) !T {
    if ((req.head.content_length orelse 0) > 2 * 1024 * 1024) return error.StreamTooLong;
    var buffer: [4096]u8 = undefined;
    const reader = try req.readerExpectContinue(&buffer);
    const raw = try reader.allocRemaining(c.allocator, .limited(2 * 1024 * 1024));
    const parsed = std.json.parseFromSlice(T, c.allocator, raw, .{ .allocate = .alloc_always }) catch return error.InvalidJson;
    return parsed.value;
}
fn extended(c: sys.Context, req: *Request) !void {
    // Body readers invalidate request header storage: copy the route before reading.
    const target = try c.allocator.dupe(u8, req.head.target);
    const end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..end];
    if (req.head.method == .GET) {
        if (req.head.transfer_encoding != .none or (req.head.content_length orelse 0) != 0) return json(c, req, .bad_request, .{ .error_message = "GET requests cannot have a body" });
        if (std.mem.eql(u8, path, "/api/config/list")) return json(c, req, .ok, try config.list(c, try queryPath(c, target)));
        if (std.mem.eql(u8, path, "/api/config/file")) return json(c, req, .ok, try config.read(c, try queryPath(c, target)));
        if (end != target.len) return error.InvalidQuery;
        if (std.mem.eql(u8, path, "/api/controls/audio")) return json(c, req, .ok, try controls.audio(c));
        if (std.mem.eql(u8, path, "/api/controls/brightness")) return json(c, req, .ok, try controls.brightness(c));
        if (std.mem.eql(u8, path, "/api/controls/services")) return json(c, req, .ok, try controls.services(c));
        if (std.mem.eql(u8, path, "/api/controls/updates")) return json(c, req, .ok, try controls.updates(c, false));
        return json(c, req, .method_not_allowed, .{ .error_message = "Use POST for actions" });
    }
    if (req.head.method != .POST) return json(c, req, .method_not_allowed, .{ .error_message = "Use GET or POST" });
    if (!std.mem.eql(u8, header(req, "x-ricehub-action") orelse "", "control")) return json(c, req, .forbidden, .{ .error_message = "Missing X-RiceHub-Action: control header" });
    if (!std.mem.eql(u8, req.head.content_type orelse "", "application/json")) return json(c, req, .unsupported_media_type, .{ .error_message = "Use Content-Type: application/json" });
    if (end != target.len) return error.InvalidQuery;
    if (std.mem.eql(u8, path, "/api/config/save")) return json(c, req, .ok, try config.save(c, try body(config.Save, c, req)));
    if (std.mem.eql(u8, path, "/api/controls/audio")) {
        try controls.setAudio(c, try body(controls.AudioAction, c, req));
        return json(c, req, .ok, try controls.audio(c));
    }
    if (std.mem.eql(u8, path, "/api/controls/brightness")) {
        try controls.setBrightness(c, try body(controls.BrightnessAction, c, req));
        return json(c, req, .ok, try controls.brightness(c));
    }
    if (std.mem.eql(u8, path, "/api/controls/services")) {
        try controls.serviceAction(c, try body(controls.ServiceAction, c, req));
        return json(c, req, .ok, .{ .message = "Service job queued. Refresh to see its current state." });
    }
    if (std.mem.eql(u8, path, "/api/controls/updates/check")) {
        _ = try body(struct {}, c, req);
        return json(c, req, .ok, try controls.updates(c, true));
    }
    if (std.mem.eql(u8, path, "/api/controls/updates/apply")) {
        try controls.applyUpdates(c, try body(controls.UpdateAction, c, req));
        return json(c, req, .accepted, .{ .message = "Update terminal requested. Review and complete the transaction there." });
    }
    return json(c, req, .not_found, .{ .error_message = "Endpoint not found" });
}
