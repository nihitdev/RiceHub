const std = @import("std");
const Context = @import("system.zig").Context;
const Dir = std.Io.Dir;
const File = std.Io.File;
pub const max_bytes = 256 * 1024;
var save_lock: std.Io.Mutex = .init;

pub fn rootPath(c: Context) ![]const u8 {
    const path = c.env.get("RICEHUB_DOTFILES") orelse blk: {
        if (c.env.get("XDG_CONFIG_HOME")) |xdg| if (std.fs.path.isAbsolute(xdg)) break :blk xdg;
        const home = c.env.get("HOME") orelse return error.HomeUnavailable;
        break :blk try std.fs.path.join(c.allocator, &.{ home, ".config" });
    };
    if (!std.fs.path.isAbsolute(path)) return error.InvalidConfigRoot;
    return path;
}
fn validate(path: []const u8, allow_empty: bool) !void {
    if (path.len == 0 and allow_empty) return;
    if (path.len == 0 or path.len > 4096 or path[0] == '/' or !std.unicode.utf8ValidateSlice(path)) return error.InvalidPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".git") or std.mem.startsWith(u8, part, ".ricehub-")) return error.InvalidPath;
        for (part) |ch| if (ch < 32 or ch == 127 or ch == '\\') return error.InvalidPath;
    }
}
// Open one component at a time, relative to directory descriptors, never following links.
fn directory(c: Context, path: []const u8) !Dir {
    try validate(path, true);
    var dir = try Dir.cwd().openDir(c.io, try rootPath(c), .{ .iterate = true });
    errdefer dir.close(c.io);
    if (path.len > 0) {
        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |part| {
            const next = try dir.openDir(c.io, part, .{ .iterate = true, .follow_symlinks = false });
            dir.close(c.io);
            dir = next;
        }
    }
    return dir;
}
const Parent = struct { dir: Dir, name: []const u8 };
fn parent(c: Context, path: []const u8) !Parent {
    try validate(path, false);
    return .{ .dir = try directory(c, std.fs.path.dirname(path) orelse ""), .name = std.fs.path.basename(path) };
}
const Entry = struct { name: []const u8, kind: []const u8 };
fn less(_: void, a: Entry, b: Entry) bool {
    if (std.mem.eql(u8, a.kind, "directory") != std.mem.eql(u8, b.kind, "directory")) return std.mem.eql(u8, a.kind, "directory");
    return std.mem.lessThan(u8, a.name, b.name);
}
pub fn list(c: Context, path: []const u8) !struct { root: []const u8, path: []const u8, entries: []const Entry, truncated: bool } {
    var dir = try directory(c, path);
    defer dir.close(c.io);
    var entries: std.array_list.Managed(Entry) = .init(c.allocator);
    var it = dir.iterate();
    var truncated = false;
    while (try it.next(c.io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".git") or std.mem.startsWith(u8, entry.name, ".ricehub-")) continue;
        if (entries.items.len >= 1024) {
            truncated = true;
            break;
        }
        try entries.append(.{ .name = try c.allocator.dupe(u8, entry.name), .kind = switch (entry.kind) {
            .directory => "directory",
            .file => "file",
            .sym_link => "symlink",
            else => "other",
        } });
    }
    std.mem.sort(Entry, entries.items, {}, less);
    return .{ .root = try rootPath(c), .path = path, .entries = entries.items, .truncated = truncated };
}
fn openRegular(c: Context, dir: Dir, name: []const u8) !File {
    // NONBLOCK prevents FIFO/device paths from tying up request workers before fstat.
    const name_z = try c.allocator.dupeZ(u8, name);
    const fd = std.os.linux.openat(dir.handle, name_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, 0);
    switch (std.posix.errno(fd)) {
        .SUCCESS => {},
        .NOENT => return error.FileNotFound,
        .LOOP => return error.SymlinkNotAllowed,
        .ACCES, .PERM => return error.AccessDenied,
        else => return error.CannotOpenFile,
    }
    const file: File = .{ .handle = @intCast(fd), .flags = .{ .nonblocking = true } };
    errdefer file.close(c.io);
    const stat = try file.stat(c.io);
    if (stat.kind != .file) return error.NotTextFile;
    if (stat.size > max_bytes) return error.FileTooLarge;
    return file;
}
fn readText(c: Context, file: File) ![]const u8 {
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(c.io, &buffer);
    const content = try reader.interface.allocRemaining(c.allocator, .limited(max_bytes + 1));
    if (content.len > max_bytes) return error.FileTooLarge;
    try textCheck(content);
    return content;
}
fn textCheck(content: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(content)) return error.NotTextFile;
    for (content) |ch| if ((ch < 32 and ch != '\n' and ch != '\r' and ch != '\t') or ch == 127) return error.NotTextFile;
}
fn revision(c: Context, content: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
    return c.allocator.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}
pub fn read(c: Context, path: []const u8) !struct { path: []const u8, content: []const u8, revision: []const u8, editable: bool } {
    const p = try parent(c, path);
    defer p.dir.close(c.io);
    const file = try openRegular(c, p.dir, p.name);
    defer file.close(c.io);
    const stat = try file.stat(c.io);
    const content = try readText(c, file);
    return .{ .path = path, .content = content, .revision = try revision(c, content), .editable = stat.nlink == 1 and (stat.permissions.toMode() & 0o222) != 0 };
}
pub const Save = struct { path: []const u8, content: []const u8, revision: []const u8 };
pub fn save(c: Context, input: Save) !struct { ok: bool, backup: []const u8, revision: []const u8 } {
    if (input.content.len > max_bytes) return error.FileTooLarge;
    try textCheck(input.content);
    try save_lock.lock(c.io);
    defer save_lock.unlock(c.io);
    const p = try parent(c, input.path);
    defer p.dir.close(c.io);
    const file = try openRegular(c, p.dir, p.name);
    defer file.close(c.io);
    const stat = try file.stat(c.io);
    if (stat.nlink != 1 or (stat.permissions.toMode() & 0o222) == 0) return error.ReadOnlyFile;
    const original = try readText(c, file);
    if (!std.mem.eql(u8, input.revision, try revision(c, original))) return error.FileChanged;
    if (std.mem.eql(u8, input.content, original)) return error.NoChanges;
    var random: [16]u8 = undefined;
    try c.io.randomSecure(&random);
    const backup_name = try std.fmt.allocPrint(c.allocator, ".ricehub-backup-{s}", .{std.fmt.bytesToHex(random, .lower)});
    const backup = try p.dir.createFile(c.io, backup_name, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer backup.close(c.io);
    try backup.writeStreamingAll(c.io, original);
    try backup.sync(c.io);
    var replacement = try p.dir.createFileAtomic(c.io, p.name, .{ .replace = true, .permissions = stat.permissions });
    defer replacement.deinit(c.io);
    try replacement.file.writeStreamingAll(c.io, input.content);
    try replacement.file.setPermissions(c.io, stat.permissions);
    try replacement.file.sync(c.io);
    // Check again after writing the backup/temp file to detect intervening external edits.
    const current = try openRegular(c, p.dir, p.name);
    defer current.close(c.io);
    const current_stat = try current.stat(c.io);
    if (current_stat.inode != stat.inode or !std.mem.eql(u8, input.revision, try revision(c, try readText(c, current)))) return error.FileChanged;
    try replacement.replace(c.io);
    return .{ .ok = true, .backup = try std.fs.path.join(c.allocator, &.{ try rootPath(c), std.fs.path.dirname(input.path) orelse "", backup_name }), .revision = try revision(c, input.content) };
}
