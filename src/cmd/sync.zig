const std = @import("std");
const App = @import("../app.zig").App;
const git = @import("../git.zig");
const config = @import("../config.zig");
const cli = @import("../cli.zig");

pub fn run(app: *App, parsed: cli.Parsed, cfg: config.Config, repo: git.Repo) !void {
    const recursive = parsed.recursive orelse cfg.recursive;
    var subs: std.ArrayList(git.Sub) = .empty;
    git.listSubs(app.arena, repo.ptr, "", recursive, &subs) catch |e| git.dieGit(app, e);

    var dirty = false;
    for (subs.items) |s| {
        if (s.skip) continue;
        if (s.dirty) {
            try app.print("dirty: {s}\n", .{s.path});
            dirty = true;
        }
    }
    if (dirty) git.dieGit(app, error.Dirty);

    for (subs.items) |s| {
        if (s.skip) continue;
        // only sync direct children of this repo in this loop; nested handled if we open each
        if (!s.direct) continue;
        git.syncSub(repo.ptr, s.name, app.arena) catch |e| {
            try app.stderr.print("{s}: {s}\n", .{ s.path, git.lastError() });
            git.dieGit(app, e);
        };
        try app.print("synced {s}\n", .{s.path});
    }
}
