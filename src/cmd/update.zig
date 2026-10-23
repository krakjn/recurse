const std = @import("std");
const App = @import("../app.zig").App;
const git = @import("../git.zig");
const config = @import("../config.zig");
const cli = @import("../cli.zig");
const tree = @import("../tree.zig");

pub fn run(app: *App, parsed: cli.Parsed, cfg: config.Config, repo: git.Repo) !void {
    const recursive = parsed.recursive orelse cfg.recursive;
    var subs: std.ArrayList(git.Sub) = .empty;
    git.listSubs(app.arena, repo.ptr, "", true, &subs) catch |e| git.fail(app, ".", e);
    const paths = tree.resolve(app, app.arena, subs.items, parsed.paths);
    for (subs.items) |s| {
        if (s.skip) continue;
        if (s.tracked_dirty and tree.inScope(paths, s.path)) git.fail(app, s.path, error.Dirty);
    }
    // Decide every attach before the first checkout, so one refusal leaves the rest put.
    for (subs.items) |s| {
        if (s.skip or s.uninitialized or !tree.inScope(paths, s.path)) continue;
        const pin = s.head_oid orelse continue;
        const child = git.openByPath(repo.ptr, s.path, app.arena) catch |e| git.fail(app, s.path, e);
        defer child.close();
        _ = git.classifyAttach(child.ptr, &pin, s.branch, app.arena) catch |e| git.fail(app, s.path, e);
    }
    try updateRepo(app, repo.ptr, "", recursive, paths);
}

fn updateRepo(
    app: *App,
    repo: *git.Repository,
    prefix: []const u8,
    recursive: bool,
    paths: []const []const u8,
) !void {
    var subs: std.ArrayList(git.Sub) = .empty;
    git.listSubs(app.arena, repo, prefix, false, &subs) catch |e| git.fail(app, if (prefix.len == 0) "." else prefix, e);

    for (subs.items) |s| {
        if (s.skip) continue;
        const selected = tree.inScope(paths, s.path);
        const toward = paths.len != 0 and tree.affected(paths, s.path);
        if (!selected and !toward and !recursive) continue;
        if (recursive and paths.len != 0 and !selected and !toward) continue;

        // Ancestors that are not checked out yet still have to materialize,
        // or the requested child cannot be opened.
        if (selected or (toward and s.uninitialized)) {
            const branch = git.syncSub(repo, s.name, app.arena) catch |e| git.fail(app, s.path, e);
            try app.print("updated {s} ({s})\n", .{ s.path, branch });
        }

        const descend = recursive or toward;
        if (!descend) continue;
        const child = git.openSub(repo, s.name, app.arena) catch |e| git.fail(app, s.path, e);
        defer child.close();
        try updateRepo(app, child.ptr, s.path, recursive, paths);
    }
}
