const std = @import("std");
const App = @import("../app.zig").App;
const git = @import("../git.zig");
const config = @import("../config.zig");
const cli = @import("../cli.zig");

pub fn run(app: *App, parsed: cli.Parsed, cfg: config.Config, repo: git.Repo) !void {
    const recursive = parsed.recursive orelse cfg.recursive;
    var subs: std.ArrayList(git.Sub) = .empty;
    git.listSubs(app.arena, repo.ptr, "", recursive, &subs) catch |e| git.dieGit(app, e);

    if (git.parentDirty(repo.ptr) catch |e| git.dieGit(app, e)) git.dieGit(app, error.Uncommitted);

    for (subs.items) |s| {
        if (s.skip) continue;
        if (s.dirty or s.tracked_dirty) {
            try app.print("dirty: {s}\n", .{s.path});
            git.dieGit(app, error.Uncommitted);
        }
        if (s.gitlink_mismatch) {
            try app.print("uncommitted gitlink: {s}\n", .{s.path});
            git.dieGit(app, error.Uncommitted);
        }
        if (!s.uninitialized and s.detached) {
            app.die("{s}: detached HEAD; cannot push", .{s.path});
        }
    }

    for (subs.items) |s| {
        if (s.skip or s.uninitialized) continue;
        if (!s.direct) continue;
        if (s.ahead == 0) continue;
        const child = git.openSub(repo.ptr, s.name, app.arena) catch |e| git.dieGit(app, e);
        defer child.close();
        git.pushCurrent(child.ptr, app.arena) catch |e| git.dieGit(app, e);
        try app.print("pushed {s}\n", .{s.path});
    }

    git.pushCurrent(repo.ptr, app.arena) catch |e| git.dieGit(app, e);
    try app.print("pushed superproject\n", .{});
}
