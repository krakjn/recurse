const std = @import("std");
const App = @import("../app.zig").App;
const git = @import("../git.zig");
const config = @import("../config.zig");
const cli = @import("../cli.zig");

pub fn run(app: *App, parsed: cli.Parsed, cfg: config.Config, repo: git.Repo) !void {
    if (!cfg.pull_ff_only) app.die("pull.ff must be only", .{});

    var subs: std.ArrayList(git.Sub) = .empty;
    git.listSubs(app.arena, repo.ptr, "", true, &subs) catch |e| git.fail(app, ".", e);

    for (subs.items) |s| {
        if (s.skip) continue;
        if (s.tracked_dirty) git.fail(app, s.path, error.Dirty);
    }
    if (git.parentDirty(repo.ptr) catch |e| git.fail(app, ".", e)) git.fail(app, ".", error.Dirty);

    const prepared = git.ffPrepare(repo.ptr, app.arena, true) catch |e| git.fail(app, ".", e);
    if (prepared.target) |target| {
        try git.preflightTree(app, app.arena, repo.ptr, &target, "");
        git.ffApply(repo.ptr, target) catch |e| git.fail(app, ".", e);
    }
    try app.print("pulled .\n", .{});
    try @import("update.zig").run(app, .{ .cmd = .update, .recursive = parsed.recursive }, cfg, repo);
}
