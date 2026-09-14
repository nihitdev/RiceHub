const std = @import("std");
const Context = @import("system.zig").Context;
const commands = @import("commands.zig");
pub var jobs: std.Io.Group = .init;
var launch_lock: std.Io.Mutex = .init;
var check_lock: std.Io.Mutex = .init;
var terminal_exit: std.atomic.Value(i32) = .init(-2);
var terminal_running: std.atomic.Value(bool) = .init(false);
pub fn executable(c: Context, name: []const u8) !bool {
    var paths = std.mem.splitScalar(u8, c.env.get("PATH") orelse "", ':');
    while (paths.next()) |path| {
        const full = try std.fs.path.join(c.allocator, &.{ path, name });
        std.Io.Dir.cwd().access(c.io, full, .{ .execute = true }) catch continue;
        return true;
    }
    return false;
}
fn output(c: Context, argv: []const []const u8) ![]const u8 {
    const result = try commands.run(c, argv);
    if (!commands.success(result)) return error.CommandFailed;
    return std.mem.trim(u8, result.stdout, " \r\n\t");
}
fn audioTool(c: Context) ![]const u8 {
    if (try executable(c, "wpctl")) return "wpctl";
    if (try executable(c, "pactl")) return "pactl";
    return error.AudioToolsUnavailable;
}
pub fn audio(c: Context) !struct { tool: []const u8, volume: u32, muted: bool } {
    const tool = try audioTool(c);
    if (std.mem.eql(u8, tool, "wpctl")) {
        const raw = try output(c, &.{ "wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@" });
        var tokens = std.mem.tokenizeAny(u8, raw, " \t\n");
        _ = tokens.next();
        const volume = try std.fmt.parseFloat(f64, tokens.next() orelse return error.InvalidAudioResponse);
        if (!std.math.isFinite(volume) or volume < 0 or volume > 100) return error.InvalidAudioResponse;
        return .{ .tool = tool, .volume = @intFromFloat(@round(volume * 100)), .muted = std.mem.indexOf(u8, raw, "MUTED") != null };
    }
    const raw = try output(c, &.{ "pactl", "get-sink-volume", "@DEFAULT_SINK@" });
    const percent = std.mem.indexOfScalar(u8, raw, '%') orelse return error.InvalidAudioResponse;
    var start = percent;
    while (start > 0 and std.ascii.isDigit(raw[start - 1])) start -= 1;
    const muted = try output(c, &.{ "pactl", "get-sink-mute", "@DEFAULT_SINK@" });
    return .{ .tool = tool, .volume = try std.fmt.parseInt(u32, raw[start..percent], 10), .muted = std.mem.endsWith(u8, muted, "yes") };
}
pub const AudioAction = struct { action: enum { volume, mute }, value: u8 };
pub fn setAudio(c: Context, input: AudioAction) !void {
    if (input.value > (if (input.action == .volume) @as(u8, 100) else 1)) return error.InvalidValue;
    const tool = try audioTool(c);
    const value = try std.fmt.allocPrint(c.allocator, "{d}{s}", .{ input.value, if (input.action == .volume) "%" else "" });
    if (std.mem.eql(u8, tool, "wpctl")) {
        _ = try output(c, &.{ "wpctl", if (input.action == .volume) "set-volume" else "set-mute", "@DEFAULT_AUDIO_SINK@", value });
    } else {
        _ = try output(c, &.{ "pactl", if (input.action == .volume) "set-sink-volume" else "set-sink-mute", "@DEFAULT_SINK@", value });
    }
}
pub fn brightness(c: Context) !struct { device: []const u8, value: u8 } {
    if (!try executable(c, "brightnessctl")) return error.BrightnessToolUnavailable;
    const raw = try output(c, &.{ "brightnessctl", "--class=backlight", "--machine-readable", "info" });
    var tokens = std.mem.splitScalar(u8, raw, ',');
    const device = tokens.next() orelse return error.InvalidBrightnessResponse;
    _ = tokens.next();
    _ = tokens.next();
    const percent = tokens.next() orelse return error.InvalidBrightnessResponse;
    return .{ .device = device, .value = try std.fmt.parseInt(u8, std.mem.trim(u8, percent, "%"), 10) };
}
pub const BrightnessAction = struct { value: u8 };
pub fn setBrightness(c: Context, input: BrightnessAction) !void {
    if (input.value < 1 or input.value > 100) return error.InvalidValue;
    _ = try brightness(c);
    _ = try output(c, &.{ "brightnessctl", "--class=backlight", "set", try std.fmt.allocPrint(c.allocator, "{d}%", .{input.value}) });
}
pub const Service = struct { unit: []const u8, load: []const u8, active: []const u8, sub: []const u8, description: []const u8, controllable: bool = false };
fn protected(unit: []const u8) bool {
    return std.mem.startsWith(u8, unit, "dbus") or std.mem.startsWith(u8, unit, "wayland-") or std.mem.startsWith(u8, unit, "graphical-session");
}
pub fn services(c: Context) !struct { services: []Service } {
    if (!try executable(c, "systemctl")) return error.UserServicesUnavailable;
    const raw = try output(c, &.{ "systemctl", "--user", "list-units", "--type=service", "--all", "--output=json", "--no-pager" });
    const parsed = try std.json.parseFromSlice([]Service, c.allocator, raw, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    for (parsed.value) |*service| service.controllable = std.mem.eql(u8, service.load, "loaded") and !protected(service.unit);
    return .{ .services = parsed.value };
}
pub const ServiceAction = struct { unit: []const u8, action: enum { start, stop, restart } };
pub fn serviceAction(c: Context, input: ServiceAction) !void {
    if (input.unit.len == 0 or input.unit.len > 255 or input.unit[0] == '-' or !std.mem.endsWith(u8, input.unit, ".service")) return error.InvalidService;
    for (input.unit) |ch| if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "_-.:@\\", ch) == null) return error.InvalidService;
    const current = try services(c);
    for (current.services) |service| {
        if (std.mem.eql(u8, service.unit, input.unit)) {
            if (!service.controllable) return error.ProtectedService;
            // Queue the job; clients re-read the service state instead of claiming the job finished.
            _ = try output(c, &.{ "systemctl", "--user", "--no-block", @tagName(input.action), "--", input.unit });
            return;
        }
    }
    return error.UnknownService;
}
pub const Manager = enum { arch, apt, dnf };
fn manager(c: Context) !Manager {
    if (try executable(c, "pacman")) return .arch;
    if (try executable(c, "apt")) return .apt;
    if (try executable(c, "dnf")) return .dnf;
    return error.PackageManagerUnavailable;
}
fn isOmarchy(c: Context) !bool {
    return std.mem.eql(u8, @import("system.zig").system(c).os orelse "", "Omarchy") and try executable(c, "omarchy");
}
fn updateCommand(c: Context, which: Manager) ![]const []const u8 {
    return switch (which) {
        .arch => if (try isOmarchy(c)) &.{ "omarchy", "update" } else &.{ "sudo", "pacman", "-Syu" },
        .apt => &.{ "sudo", "apt", "upgrade" },
        .dnf => &.{ "sudo", "dnf", "upgrade", "--refresh" },
    };
}
pub fn updates(c: Context, fresh: bool) !struct { manager: Manager, packages: []const []const u8, source: []const u8, can_check: bool, can_apply: bool, command: []const []const u8, terminal_running: bool, terminal_exit_code: ?i32 } {
    if (!check_lock.tryLock()) return error.UpdateCheckBusy;
    defer check_lock.unlock(c.io);
    const which = try manager(c);
    const can_check = which != .arch or try executable(c, "checkupdates");
    if (fresh and !can_check) return error.CheckupdatesUnavailable;
    const argv: []const []const u8 = switch (which) {
        .arch => if (fresh) &.{ "checkupdates", "--nocolor" } else &.{ "pacman", "-Qu" },
        .apt => &.{ "apt", "list", "--upgradable" },
        .dnf => if (fresh) &.{ "dnf", "--refresh", "check-upgrade" } else &.{ "dnf", "--cacheonly", "check-upgrade" },
    };
    var env = try c.env.clone(c.allocator);
    defer env.deinit();
    try env.put("LC_ALL", "C");
    const result = try std.process.run(c.allocator, c.io, .{ .argv = argv, .environ_map = &env, .stdout_limit = .limited(512 * 1024), .stderr_limit = .limited(64 * 1024), .timeout = .{ .duration = .{ .raw = .fromSeconds(if (fresh) 60 else 8), .clock = .awake } } });
    const code = switch (result.term) {
        .exited => |code| code,
        else => return error.UpdateCheckFailed,
    };
    const okay = code == 0 or (which == .arch and code == (if (fresh) @as(u8, 2) else 1)) or (which == .dnf and code == 100);
    if (!okay) return error.UpdateCheckFailed;
    var lines: std.array_list.Managed([]const u8) = .init(c.allocator);
    var it = std.mem.splitScalar(u8, result.stdout, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or std.mem.startsWith(u8, line, "Listing...")) continue;
        try lines.append(line);
    }
    return .{ .manager = which, .packages = lines.items, .source = if (fresh and which != .apt) "Refreshed repositories" else "Local package cache (may be stale)", .can_check = can_check, .can_apply = try executable(c, "xdg-terminal-exec"), .command = try updateCommand(c, which), .terminal_running = terminal_running.load(.acquire), .terminal_exit_code = if (terminal_exit.load(.acquire) == -2) null else terminal_exit.load(.acquire) };
}
pub const UpdateAction = struct { manager: Manager };
fn reap(io: std.Io, child_value: std.process.Child) void {
    var child = child_value;
    const term = child.wait(io) catch {
        terminal_exit.store(-1, .release);
        terminal_running.store(false, .release);
        return;
    };
    terminal_exit.store(switch (term) {
        .exited => |code| @intCast(code),
        else => -1,
    }, .release);
    terminal_running.store(false, .release);
}
pub fn applyUpdates(c: Context, input: UpdateAction) !void {
    try launch_lock.lock(c.io);
    defer launch_lock.unlock(c.io);
    if (input.manager != try manager(c)) return error.PackageManagerChanged;
    if (!try executable(c, "xdg-terminal-exec")) return error.TerminalLauncherUnavailable;
    if (c.env.get("WAYLAND_DISPLAY") == null and c.env.get("DISPLAY") == null) return error.DesktopSessionUnavailable;
    if (terminal_running.load(.acquire)) return error.UpdateTerminalAlreadyRunning;
    var args: std.array_list.Managed([]const u8) = .init(c.allocator);
    try args.appendSlice(&.{ "xdg-terminal-exec", "--hold", "--title=RiceHub updates", "--" });
    try args.appendSlice(try updateCommand(c, input.manager));
    var child = try std.process.spawn(c.io, .{ .argv = args.items, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    terminal_exit.store(-2, .release);
    terminal_running.store(true, .release);
    jobs.concurrent(c.io, reap, .{ c.io, child }) catch |err| {
        child.kill(c.io);
        terminal_running.store(false, .release);
        return err;
    };
}
