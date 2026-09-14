const std = @import("std");
pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,

    pub fn read(c: Context, path: []const u8) ?[]const u8 {
        const file = std.Io.Dir.cwd().openFile(c.io, path, .{}) catch return null;
        defer file.close(c.io);
        // procfs files report a size of zero: read the stream through EOF.
        var buffer: [4096]u8 = undefined;
        var reader = file.readerStreaming(c.io, &buffer);
        const bytes = reader.interface.allocRemaining(c.allocator, .limited(4 * 1024 * 1024)) catch return null;
        const value = std.mem.trim(u8, bytes, " \r\n\t");
        return if (value.len > 0) value else null;
    }
};
fn field(text: []const u8, key: []const u8, separator: u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const i = std.mem.indexOfScalar(u8, line, separator) orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, line[0..i], " \t"), key))
            return std.mem.trim(u8, line[i + 1 ..], " \t\r\"'");
    }
    return null;
}
pub fn system(c: Context) struct {
    os: ?[]const u8,
    kernel: ?[]const u8,
    hostname: ?[]const u8,
    uptime_seconds: ?f64,
    shell: ?[]const u8,
    desktop: ?[]const u8,
    session_type: ?[]const u8,
    hyprland_available: bool,
} {
    const os = c.read("/etc/os-release") orelse c.read("/usr/lib/os-release");
    const uptime = c.read("/proc/uptime");
    var seconds: ?f64 = null;
    if (uptime) |s| {
        var parts = std.mem.tokenizeAny(u8, s, " \t");
        if (parts.next()) |n| seconds = std.fmt.parseFloat(f64, n) catch null;
    }
    return .{
        .os = if (os) |s| field(s, "PRETTY_NAME", '=') orelse field(s, "NAME", '=') else null,
        .kernel = c.read("/proc/sys/kernel/osrelease"),
        .hostname = c.read("/proc/sys/kernel/hostname"),
        .uptime_seconds = seconds,
        .shell = c.env.get("SHELL"),
        .desktop = c.env.get("XDG_CURRENT_DESKTOP") orelse c.env.get("XDG_SESSION_DESKTOP") orelse c.env.get("DESKTOP_SESSION"),
        .session_type = c.env.get("XDG_SESSION_TYPE"),
        .hyprland_available = if (c.env.get("HYPRLAND_INSTANCE_SIGNATURE")) |s| s.len > 0 else false,
    };
}
fn memoryValue(data: []const u8, name: []const u8) ?u64 {
    const value = field(data, name, ':') orelse return null;
    var tokens = std.mem.tokenizeAny(u8, value, " \t");
    const kb = std.fmt.parseInt(u64, tokens.next() orelse return null, 10) catch return null;
    return std.math.mul(u64, kb, 1024) catch null;
}
pub fn memory(c: Context) struct { total_bytes: ?u64, used_bytes: ?u64, available_bytes: ?u64 } {
    const data = c.read("/proc/meminfo") orelse return .{ .total_bytes = null, .used_bytes = null, .available_bytes = null };
    const total = memoryValue(data, "MemTotal");
    const available = memoryValue(data, "MemAvailable");
    return .{ .total_bytes = total, .available_bytes = available, .used_bytes = if (total != null and available != null and total.? >= available.?) total.? - available.? else null };
}
pub fn cpu(c: Context) struct { model: ?[]const u8, logical_cores: ?usize } {
    const data = c.read("/proc/cpuinfo") orelse return .{ .model = null, .logical_cores = null };
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (field(line, "processor", ':') != null) count += 1;
    }
    return .{ .model = field(data, "model name", ':') orelse field(data, "Hardware", ':') orelse field(data, "Processor", ':'), .logical_cores = if (count > 0) count else null };
}
