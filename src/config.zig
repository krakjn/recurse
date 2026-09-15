const std = @import("std");
const Io = std.Io;

pub const Config = struct {
    recursive: bool = true,
    verify_fetch: bool = true,
    require_on_remote: bool = true,
    pull_ff_only: bool = true,
};

pub fn load(
    arena: std.mem.Allocator,
    io: Io,
    override: ?[]const u8,
    workdir: ?[]const u8,
) !Config {
    if (override) |p| return parseFile(arena, io, p);

    var cwd_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    if (findUp(io, cwd_buf[0..cwd_len], "recurse.toml")) |found| {
        return parseFile(arena, io, found);
    }
    if (workdir) |wd| {
        const p = try std.fmt.allocPrint(arena, "{s}recurse.toml", .{slash(wd)});
        if (exists(io, p)) return parseFile(arena, io, p);
    }
    return .{};
}

fn slash(dir: []const u8) []const u8 {
    if (dir.len == 0) return dir;
    if (dir[dir.len - 1] == '/') return dir;
    return dir; // join below adds slash when needed
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

fn findUp(io: Io, start: []const u8, name: []const u8) ?[]const u8 {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    if (start.len >= buf.len) return null;
    @memcpy(buf[0..start.len], start);
    var len = start.len;
    while (true) {
        const path_len = if (len > 0 and buf[len - 1] == '/')
            std.fmt.bufPrint(buf[len..], "{s}", .{name}) catch return null
        else
            std.fmt.bufPrint(buf[len..], "/{s}", .{name}) catch return null;
        const full = buf[0 .. len + path_len.len];
        if (exists(io, full)) {
            const out = std.heap.page_allocator.dupe(u8, full) catch return null;
            return out;
        }
        if (len == 0 or (len == 1 and buf[0] == '/')) return null;
        while (len > 0 and buf[len - 1] != '/') len -= 1;
        if (len > 1) len -= 1; // drop slash, stay at parent
        if (len == 0) {
            buf[0] = '/';
            len = 1;
        }
    }
}

fn parseFile(arena: std.mem.Allocator, io: Io, path: []const u8) !Config {
    const file = Io.Dir.openFileAbsolute(io, path, .{}) catch return error.Config;
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    const bytes = reader.interface.allocRemaining(arena, .unlimited) catch return error.Config;
    return parseToml(bytes);
}

fn parseToml(src: []const u8) Config {
    var cfg: Config = .{};
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == '[') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        var val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
            val = val[1 .. val.len - 1];
        }
        if (std.mem.eql(u8, key, "recursive")) cfg.recursive = truthy(val);
        if (std.mem.eql(u8, key, "fetch")) cfg.verify_fetch = truthy(val);
        if (std.mem.eql(u8, key, "require_on_remote")) cfg.require_on_remote = truthy(val);
        if (std.mem.eql(u8, key, "ff")) cfg.pull_ff_only = !std.mem.eql(u8, val, "false") and !std.mem.eql(u8, val, "no");
    }
    return cfg;
}

fn truthy(v: []const u8) bool {
    return std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "yes");
}
