const std = @import("std");
const Context = @import("system.zig").Context;
pub fn run(c: Context, argv: []const []const u8) !std.process.RunResult {
    var env = try c.env.clone(c.allocator);
    defer env.deinit();
    try env.put("LC_ALL", "C");
    return std.process.run(c.allocator, c.io, .{ .argv = argv, .environ_map = &env, .stdout_limit = .limited(1024 * 1024), .stderr_limit = .limited(64 * 1024), .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } });
}
pub fn success(result: std.process.RunResult) bool {
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}
pub const Dotfiles = struct {
    available: bool = false,
    path: ?[]const u8 = null,
    entries: []const []const u8 = &.{},
    truncated: bool = false,
    git_available: bool = false,
    branch: ?[]const u8 = null,
    dirty: ?bool = null,
    changed_files: ?usize = null,
    git_error: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
};
fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
pub fn dotfiles(c: Context) !Dotfiles {
    const path = try @import("config.zig").rootPath(c);
    var result: Dotfiles = .{ .path = path };
    var dir = std.Io.Dir.cwd().openDir(c.io, path, .{ .iterate = true }) catch |err| {
        result.error_message = @errorName(err);
        return result;
    };
    defer dir.close(c.io);
    var entries: std.array_list.Managed([]const u8) = .init(c.allocator);
    var iterator = dir.iterate();
    while (iterator.next(c.io) catch |err| {
        result.error_message = @errorName(err);
        return result;
    }) |entry| {
        if (std.mem.eql(u8, entry.name, ".git") or std.mem.startsWith(u8, entry.name, ".ricehub-")) continue;
        if (entries.items.len == 512) {
            result.truncated = true;
            break;
        }
        try entries.append(try c.allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, entries.items, {}, lessThan);
    result.entries = entries.items;
    result.available = true;
    // Git is optional metadata. Discovery never depends on a repository or Git being installed.
    dir.access(c.io, ".git", .{}) catch return result;
    gitStatus(c, &result) catch |err| {
        result.git_error = @errorName(err);
    };
    return result;
}
fn gitStatus(c: Context, result: *Dotfiles) !void {
    const path = result.path.?;
    const status = try run(c, &.{ "git", "--no-optional-locks", "-C", path, "status", "--porcelain=v1", "-z", "--untracked-files=normal" });
    if (!success(status)) return error.GitStatusFailed;
    var count: usize = 0;
    var records = std.mem.splitScalar(u8, status.stdout, 0);
    while (records.next()) |record| {
        if (record.len < 3) continue;
        count += 1;
        if (record[0] == 'R' or record[0] == 'C' or record[1] == 'R' or record[1] == 'C') _ = records.next();
    }
    result.git_available = true;
    result.dirty = count > 0;
    result.changed_files = count;
    const branch = try run(c, &.{ "git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD" });
    if (success(branch)) result.branch = std.mem.trim(u8, branch.stdout, "\r\n");
}
pub fn reload(c: Context) !void {
    if (!@import("system.zig").system(c).hyprland_available) return error.HyprlandUnavailable;
    const result = try run(c, &.{ "hyprctl", "reload" });
    if (!success(result)) return error.HyprlandReloadFailed;
}
