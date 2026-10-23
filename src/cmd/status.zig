const std = @import("std");
const App = @import("../app.zig").App;
const git = @import("../git.zig");
const config = @import("../config.zig");
const cli = @import("../cli.zig");
const style = @import("../style.zig");

const Flag = struct {
    tone: style.Tone,
    text: []const u8,
};

const Row = struct {
    path: []const u8,
    branch: []const u8,
    branch_tone: style.Tone,
    sha: []const u8,
    flags: [8]Flag = undefined,
    nflags: u8 = 0,

    fn add(self: *Row, tone: style.Tone, text: []const u8) void {
        self.flags[self.nflags] = .{ .tone = tone, .text = text };
        self.nflags += 1;
    }
};

pub fn run(app: *App, parsed: cli.Parsed, cfg: config.Config, repo: git.Repo) !void {
    const recursive = parsed.recursive orelse cfg.recursive;
    const parent_name = git.headName(app.arena, repo.ptr) catch |e| git.fail(app, ".", e);
    const parent_sha = git.headShort(repo.ptr);
    const pdirty = git.parentDirty(repo.ptr) catch |e| git.fail(app, ".", e);
    const puntracked = git.parentUntracked(repo.ptr) catch |e| git.fail(app, ".", e);

    var subs: std.ArrayList(git.Sub) = .empty;
    git.listSubs(app.arena, repo.ptr, "", recursive, &subs) catch |e| git.fail(app, ".", e);

    var rows: std.ArrayList(Row) = .empty;
    const parent_sha_text: []const u8 = if (parent_sha) |s| try app.arena.dupe(u8, &s) else "-";
    try rows.append(app.arena, parentRow(parent_name, parent_sha_text, pdirty, puntracked));

    var max_path: usize = rows.items[0].path.len;
    for (subs.items) |s| {
        const row = try childRow(app.arena, s);
        max_path = @max(max_path, row.path.len);
        try rows.append(app.arena, row);
    }

    const layout = style.lineLayout(max_path, style.terminalColumns(app.io, app.environ));
    var branch_width: usize = 1;
    for (rows.items) |row| {
        const shown = style.fitLabel(row.branch, layout.branch_col);
        branch_width = @max(branch_width, shown.len);
    }
    branch_width = @min(branch_width, layout.branch_col);

    for (rows.items) |row| {
        try style.writePath(app.stdout, app.stdout_color, row.path, layout.path_col);
        try app.stdout.writeByte(' ');
        const branch = style.fitLabel(row.branch, branch_width);
        try app.paint(row.branch_tone, branch);
        if (branch.len < branch_width) try app.stdout.splatByteAll(' ', branch_width - branch.len);
        try app.stdout.writeByte(' ');
        try app.paint(.dim, row.sha);
        if (row.nflags == 0) {
            try app.stdout.writeByte('\n');
            continue;
        }
        if (row.sha.len < 7) try app.stdout.splatByteAll(' ', 7 - row.sha.len);
        try app.stdout.writeAll("  ");
        for (row.flags[0..row.nflags], 0..) |flag, i| {
            if (i != 0) try app.stdout.writeByte(' ');
            try app.paint(flag.tone, flag.text);
        }
        try app.stdout.writeByte('\n');
    }
}

fn parentRow(name: []const u8, sha: []const u8, dirty: bool, untracked: bool) Row {
    const detached = std.mem.eql(u8, name, "detached");
    var row = Row{
        .path = ".",
        .branch = if (detached) "(detached)" else name,
        .branch_tone = if (detached or std.mem.eql(u8, name, "unborn")) .yellow else .cyan,
        .sha = sha,
    };
    if (dirty) row.add(.red_bold, "dirty");
    if (untracked) row.add(.yellow, "untracked");
    if (!dirty and !untracked) row.add(.green_bold, "clean");
    return row;
}

fn childRow(arena: std.mem.Allocator, s: git.Sub) !Row {
    const path = try std.fmt.allocPrint(arena, "  {s}", .{s.path});
    const sha_bytes: ?[7]u8 = s.wd orelse s.head;
    var row = Row{
        .path = path,
        .branch = if (s.detached) "(detached)" else (s.ref_name orelse s.branch orelse "-"),
        .branch_tone = if (s.detached or s.uninitialized) .yellow else .cyan,
        .sha = if (sha_bytes) |bytes| try arena.dupe(u8, &bytes) else "-",
    };
    if (s.uninitialized) row.add(.yellow, "uninit");
    if (s.skip) row.add(.yellow, "skip");
    if (s.dirty) row.add(.red_bold, "dirty");
    if (s.untracked) row.add(.yellow, "untracked");
    if (s.gitlink_mismatch) if (s.head) |pin| {
        row.add(.magenta, try std.fmt.allocPrint(arena, "pin {s}", .{&pin}));
    };
    if (s.ahead > 0) row.add(.cyan_bold, try std.fmt.allocPrint(arena, "ahead {d}", .{s.ahead}));
    if (s.behind > 0) row.add(.cyan_bold, try std.fmt.allocPrint(arena, "behind {d}", .{s.behind}));
    return row;
}
