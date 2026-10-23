const std = @import("std");
const Io = std.Io;
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

    var already: std.ArrayList([]const u8) = .empty;
    git.sortDeepest(subs.items);

    for (subs.items) |s| {
        if (s.skip or !tree.affected(paths, s.path)) continue;
        if (s.uninitialized) failCommit(app, already.items, s.path, error.Uninitialized);
        const files = tree.inScope(paths, s.path);
        if (files and s.tracked_dirty and s.detached) {
            failCommit(app, already.items, s.path, error.Detached);
        }
    }

    const msg = parsed.message orelse (readEditorMessage(app, repo) catch |e| git.fail(app, ".", e));
    const msg_z = app.arena.dupeSentinel(u8, msg, 0) catch app.die("out of memory", .{});

    for (subs.items) |s| {
        if (s.skip or s.uninitialized or !tree.affected(paths, s.path)) continue;
        const files = tree.inScope(paths, s.path);
        const child = git.openByPath(repo.ptr, s.path, app.arena) catch |e| failCommit(app, already.items, s.path, e);
        defer child.close();
        if (!files) {
            const allowed = gitlinksUnder(app, subs.items, s.path, paths);
            git.refuseForeignStaged(child.ptr, allowed) catch |e| failCommit(app, already.items, s.path, e);
        }
        const did = git.commitTracked(child.ptr, msg_z, files) catch |e| failCommit(app, already.items, s.path, e);
        if (did) {
            already.append(app.arena, s.path) catch app.die("out of memory", .{});
            try app.ok("committed", s.path);
        }
        const parent = git.openParent(repo.ptr, s, app.arena) catch |e| failCommit(app, already.items, s.path, e);
        defer parent.close();
        git.addToIndex(parent.ptr, parent.name, app.arena) catch |e| failCommit(app, already.items, s.path, e);
    }

    if (paths.len != 0) {
        const allowed = gitlinksUnder(app, subs.items, "", paths);
        git.refuseForeignStaged(repo.ptr, allowed) catch |e| failCommit(app, already.items, ".", e);
    }
    const parent_did = git.commitTracked(repo.ptr, msg_z, paths.len == 0) catch |e| failCommit(app, already.items, ".", e);
    if (!parent_did) {
        if (already.items.len > 0) failCommit(app, already.items, ".", error.NothingToCommit);
        git.fail(app, ".", error.NothingToCommit);
    }
    try app.ok("committed", ".");
}

fn gitlinksUnder(
    app: *App,
    subs: []const git.Sub,
    parent: []const u8,
    paths: []const []const u8,
) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (subs) |s| {
        if (!std.mem.eql(u8, s.parent_path, parent)) continue;
        if (!tree.affected(paths, s.path)) continue;
        const rel = if (parent.len == 0) s.path else s.path[parent.len + 1 ..];
        out.append(app.arena, rel) catch app.die("out of memory", .{});
    }
    return out.toOwnedSlice(app.arena) catch app.die("out of memory", .{});
}

fn failCommit(app: *App, already: []const []const u8, where: []const u8, err: git.GitError) noreturn {
    if (already.len > 0) {
        app.paintErr(.yellow, "already committed:");
        app.stderr.writeAll("\n") catch {};
        for (already) |p| app.stderr.print("  {s}\n", .{p}) catch {};
        app.paintErr(.yellow, "superproject was not updated");
        app.stderr.writeAll("\n") catch {};
        app.stderr.flush() catch {};
    }
    git.fail(app, where, err);
}

fn readEditorMessage(app: *App, repo: git.Repo) git.GitError![]const u8 {
    const tty = Io.File.stdin().isTty(app.io) catch return error.NoTty;
    if (!tty) return error.NoTty;

    const path_z = try app.arena.printSentinel("{s}RC_EDITMSG", .{repo.gitdir()}, 0);
    const file = Io.Dir.createFileAbsolute(app.io, path_z, .{}) catch return error.Git;
    {
        defer file.close(app.io);
        var buf: [512]u8 = undefined;
        var w = file.writer(app.io, &buf);
        w.interface.writeAll(
            \\
            \\# Enter a commit message for recurse. This message is reused on
            \\# every dirty submodule and the superproject. Empty aborts.
            \\
        ) catch return error.Git;
        w.interface.flush() catch return error.Git;
    }

    const editor = app.environ.get("GIT_EDITOR") orelse app.environ.get("EDITOR") orelse "vi";
    var argv_buf: [8][]const u8 = undefined;
    var argv_len: usize = 0;
    var it = std.mem.tokenizeScalar(u8, editor, ' ');
    while (it.next()) |tok| {
        if (argv_len >= argv_buf.len) break;
        argv_buf[argv_len] = tok;
        argv_len += 1;
    }
    if (argv_len >= argv_buf.len) return error.Git;
    argv_buf[argv_len] = path_z;
    argv_len += 1;

    var child = std.process.spawn(app.io, .{
        .argv = argv_buf[0..argv_len],
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return error.Git;
    const term = child.wait(app.io) catch return error.Git;
    switch (term) {
        .exited => |code| if (code != 0) return error.Aborted,
        else => return error.Aborted,
    }

    const rf = Io.Dir.openFileAbsolute(app.io, path_z, .{}) catch return error.Git;
    defer rf.close(app.io);
    var rbuf: [1024]u8 = undefined;
    var reader = rf.reader(app.io, &rbuf);
    const raw = reader.interface.allocRemaining(app.arena, .unlimited) catch return error.OutOfMemory;
    return stripMessage(app.arena, raw);
}

fn stripMessage(arena: std.mem.Allocator, raw: []const u8) git.GitError![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        if (line.len > 0 and line[0] == '#') continue;
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }
    const msg = std.mem.trim(u8, out.items, " \t\n\r");
    if (msg.len == 0) return error.Aborted;
    return msg;
}
