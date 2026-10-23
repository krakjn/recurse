const std = @import("std");
const App = @import("../app.zig").App;
const git = @import("../git.zig");
const config = @import("../config.zig");
const cli = @import("../cli.zig");
const tree = @import("../tree.zig");

pub fn run(app: *App, parsed: cli.Parsed, cfg: config.Config, repo: git.Repo) !void {
    const recursive = parsed.recursive orelse cfg.recursive;
    var subs: std.ArrayList(git.Sub) = .empty;
    git.listSubs(app.arena, repo.ptr, "", recursive, &subs) catch |e| git.fail(app, ".", e);
    const paths = tree.resolve(app, app.arena, subs.items, parsed.paths);

    if (git.parentDirty(repo.ptr) catch |e| git.fail(app, ".", e)) {
        if (paths.len == 0) git.fail(app, ".", error.Uncommitted);
    }

    for (subs.items) |s| {
        if (s.skip or !tree.affected(paths, s.path)) continue;
        if (s.tracked_dirty) git.fail(app, s.path, error.Uncommitted);
        if (s.gitlink_mismatch) git.fail(app, s.path, error.Uncommitted);
        if (!s.uninitialized and s.detached) git.fail(app, s.path, error.Detached);
    }

    git.sortDeepest(subs.items);
    var pushed: std.ArrayList([]const u8) = .empty;
    for (subs.items) |s| {
        if (s.skip or s.uninitialized or !tree.affected(paths, s.path)) continue;
        if (s.ahead == 0) continue;
        const child = git.openByPath(repo.ptr, s.path, app.arena) catch |e| git.fail(app, s.path, e);
        defer child.close();
        git.pushCurrent(child.ptr, app.arena) catch |e| git.fail(app, s.path, e);
        pushed.append(app.arena, s.path) catch app.die("out of memory", .{});
        try app.ok("pushed", s.path);
    }

    const push_parent = paths.len == 0 or parentAhead(repo.ptr);
    if (push_parent) {
        for (subs.items) |s| {
            if (s.skip or s.uninitialized or !tree.affected(paths, s.path)) continue;
            if (containsPath(pushed.items, s.path)) continue;
            const pin = s.head_oid orelse continue;
            const child = git.openByPath(repo.ptr, s.path, app.arena) catch |e| git.fail(app, s.path, e);
            defer child.close();
            if (!git.oidOnRemote(child.ptr, &pin)) git.fail(app, s.path, error.NoUpstream);
        }
        git.pushCurrent(repo.ptr, app.arena) catch |e| git.fail(app, ".", e);
        try app.ok("pushed", ".");
    }
}

fn containsPath(paths: []const []const u8, path: []const u8) bool {
    for (paths) |p| if (std.mem.eql(u8, p, path)) return true;
    return false;
}

fn parentAhead(repo: *git.Repository) bool {
    var ahead: usize = 0;
    var behind: usize = 0;
    git.aheadBehind(repo, &ahead, &behind);
    return ahead > 0;
}
