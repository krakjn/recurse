const std = @import("std");
const App = @import("app.zig").App;
const git = @import("git.zig");

pub fn resolve(app: *App, arena: std.mem.Allocator, subs: []const git.Sub, paths: []const []const u8) []const []const u8 {
    if (paths.len == 0) return paths;
    var out: std.ArrayList([]const u8) = .empty;
    for (paths) |p| {
        var exact: ?[]const u8 = null;
        var by_name: ?[]const u8 = null;
        var name_count: usize = 0;
        for (subs) |s| {
            if (std.mem.eql(u8, s.path, p)) exact = s.path;
            if (std.mem.eql(u8, s.name, p)) {
                name_count += 1;
                by_name = s.path;
            }
        }
        if (exact) |e| {
            out.append(arena, e) catch app.die("out of memory", .{});
            continue;
        }
        if (name_count > 1) app.report(p, "ambiguous submodule path");
        if (name_count == 1) {
            out.append(arena, by_name.?) catch app.die("out of memory", .{});
            continue;
        }
        app.report(p, "unknown submodule");
    }
    return out.toOwnedSlice(arena) catch app.die("out of memory", .{});
}

/// True when `full` is a requested path or sits under one. Empty `paths` means everything.
pub fn inScope(paths: []const []const u8, full: []const u8) bool {
    if (paths.len == 0) return true;
    for (paths) |p| {
        if (std.mem.eql(u8, full, p)) return true;
        if (full.len > p.len and std.mem.startsWith(u8, full, p) and full[p.len] == '/') return true;
    }
    return false;
}

/// `inScope`, plus ancestors of a requested path (so gitlinks can bubble up).
pub fn affected(paths: []const []const u8, full: []const u8) bool {
    if (inScope(paths, full)) return true;
    for (paths) |p| {
        if (p.len > full.len and std.mem.startsWith(u8, p, full) and p[full.len] == '/') return true;
    }
    return false;
}
