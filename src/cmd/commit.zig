const std = @import("std");
const Io = std.Io;
const App = @import("../app.zig").App;
const git = @import("../git.zig");
const config = @import("../config.zig");
const cli = @import("../cli.zig");

pub fn run(app: *App, parsed: cli.Parsed, cfg: config.Config, repo: git.Repo) !void {
    const recursive = parsed.recursive orelse cfg.recursive;
    var subs: std.ArrayList(git.Sub) = .empty;
    git.listSubs(app.arena, repo.ptr, "", recursive, &subs) catch |e| git.dieGit(app, e);

    for (subs.items) |s| {
        if (s.skip or s.uninitialized) continue;
        if (s.tracked_dirty and s.detached) {
            app.die("{s}: detached HEAD; check out a branch first", .{s.path});
        }
    }

    const msg = parsed.message orelse (readEditorMessage(app, repo) catch |e| git.dieGit(app, e));
    const msg_z = app.arena.dupeZ(u8, msg) catch app.die("oom", .{});

    var child_committed: usize = 0;
    for (subs.items) |s| {
        if (s.skip or s.uninitialized) continue;
        if (!s.direct) continue;
        if (!s.tracked_dirty) continue;
        const child = git.openSub(repo.ptr, s.name, app.arena) catch |e| git.dieGit(app, e);
        defer child.close();
        const did = git.commitTracked(child.ptr, msg_z, true) catch |e| git.dieGit(app, e);
        if (did) {
            child_committed += 1;
            try app.print("committed {s}\n", .{s.path});
        }
    }

    for (subs.items) |s| {
        if (s.skip or s.uninitialized) continue;
        if (!s.direct) continue;
        git.addToIndex(repo.ptr, s.name, app.arena) catch |e| git.dieGit(app, e);
    }

    const parent_did = git.commitTracked(repo.ptr, msg_z, false) catch |e| git.dieGit(app, e);
    if (!parent_did) {
        if (child_committed > 0) {
            app.die("children committed but superproject had nothing to record", .{});
        }
        git.dieGit(app, error.NothingToCommit);
    }
    try app.print("committed superproject\n", .{});
}

fn readEditorMessage(app: *App, repo: git.Repo) git.GitError![]const u8 {
    const tty = Io.File.stdin().isTty(app.io) catch return error.NoTty;
    if (!tty) return error.NoTty;

    const path_z = try std.fmt.allocPrintSentinel(app.arena, "{s}RC_EDITMSG", .{repo.gitdir()}, 0);
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
