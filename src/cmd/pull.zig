const std = @import("std");
const App = @import("../app.zig").App;
const git = @import("../git.zig");
const config = @import("../config.zig");
const cli = @import("../cli.zig");

pub fn run(app: *App, parsed: cli.Parsed, cfg: config.Config, repo: git.Repo) !void {
    const recursive = parsed.recursive orelse cfg.recursive;
    var subs: std.ArrayList(git.Sub) = .empty;
    git.listSubs(app.arena, repo.ptr, "", recursive, &subs) catch |e| git.dieGit(app, e);

    if (parsed.paths.len > 0) {
        const want = parsed.paths[0];
        for (subs.items) |s| {
            if (!std.mem.eql(u8, s.path, want) and !std.mem.eql(u8, s.name, want)) continue;
            if (s.skip) app.die("{s}: skipped (update = none)", .{s.path});
            if (s.dirty) git.dieGit(app, error.Dirty);
            if (s.uninitialized) app.die("{s}: uninitialized; run rc sync first", .{s.path});
            const child = git.openSub(repo.ptr, s.name, app.arena) catch |e| git.dieGit(app, e);
            defer child.close();
            git.ffPull(child.ptr, cfg.pull_ff_only) catch |e| git.dieGit(app, e);
            git.addToIndex(repo.ptr, s.name, app.arena) catch |e| git.dieGit(app, e);
            try app.print("pulled {s}; gitlink staged — rc commit to record\n", .{s.path});
            return;
        }
        app.die("unknown submodule: {s}", .{want});
    }

    for (subs.items) |s| {
        if (s.skip) continue;
        if (s.dirty) {
            try app.print("dirty: {s}\n", .{s.path});
            git.dieGit(app, error.Dirty);
        }
    }
    if (git.parentDirty(repo.ptr) catch |e| git.dieGit(app, e)) {
        git.dieGit(app, error.Dirty);
    }

    git.ffPull(repo.ptr, cfg.pull_ff_only) catch |e| git.dieGit(app, e);
    try app.print("pulled superproject\n", .{});

    for (subs.items) |s| {
        if (s.skip) continue;
        if (!s.direct) continue;
        git.syncSub(repo.ptr, s.name, app.arena) catch |e| git.dieGit(app, e);
        try app.print("synced {s}\n", .{s.path});
    }
}
