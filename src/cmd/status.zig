const std = @import("std");
const App = @import("../app.zig").App;
const git = @import("../git.zig");
const config = @import("../config.zig");
const cli = @import("../cli.zig");

pub fn run(app: *App, parsed: cli.Parsed, cfg: config.Config, repo: git.Repo) !void {
    const recursive = parsed.recursive orelse cfg.recursive;
    const parent_name = try git.headName(app.arena, repo.ptr);
    const parent_sha = git.headShort(repo.ptr);
    const pdirty = git.parentDirty(repo.ptr) catch |e| git.dieGit(app, e);

    try app.print("{s:<24} {s:<12} {s:<6} {s}\n", .{
        ".",
        parent_name,
        if (pdirty) "dirty" else "clean",
        if (parent_sha) |s| s[0..] else "-",
    });

    var subs: std.ArrayList(git.Sub) = .empty;
    git.listSubs(app.arena, repo.ptr, "", recursive, &subs) catch |e| git.dieGit(app, e);

    for (subs.items) |s| {
        const ref = s.ref_name orelse s.branch orelse "-";
        const sha: []const u8 = if (s.wd) |wd| &wd else if (s.head) |h| &h else "-";
        try app.print("  {s:<22} {s:<12} {s}", .{ s.path, ref, sha });
        if (s.uninitialized) try app.print(" uninit", .{});
        if (s.skip) try app.print(" skip", .{});
        if (s.detached) try app.print(" detached", .{});
        if (s.dirty) try app.print(" dirty", .{});
        if (s.gitlink_mismatch) try app.print(" mismatch", .{});
        if (s.ahead > 0) try app.print(" ahead {d}", .{s.ahead});
        if (s.behind > 0) try app.print(" behind {d}", .{s.behind});
        try app.print("\n", .{});
    }
}
