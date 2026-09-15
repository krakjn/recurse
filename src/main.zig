const std = @import("std");
const Io = std.Io;

const cli = @import("cli.zig");
const config = @import("config.zig");
const git = @import("git.zig");
const App = @import("app.zig").App;

const cmd_status = @import("cmd/status.zig");
const cmd_sync = @import("cmd/sync.zig");
const cmd_commit = @import("cmd/commit.zig");
const cmd_pull = @import("cmd/pull.zig");
const cmd_push = @import("cmd/push.zig");
const cmd_verify = @import("cmd/verify.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    defer stdout_fw.interface.flush() catch {};

    var stderr_buf: [4096]u8 = undefined;
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    defer stderr_fw.interface.flush() catch {};

    var app: App = .{
        .arena = arena,
        .gpa = init.gpa,
        .io = io,
        .environ = init.environ_map,
        .stdout = &stdout_fw.interface,
        .stderr = &stderr_fw.interface,
    };

    const args = try init.minimal.args.toSlice(arena);
    const parsed = cli.parse(arena, args) catch {
        try app.stderr.writeAll(cli.usage);
        std.process.exit(2);
    };
    if (parsed.cmd == .help) {
        try app.stdout.writeAll(cli.usage);
        return;
    }

    git.init() catch |e| git.dieGit(&app, e);
    defer git.shutdown();

    const cwd = try std.process.currentPathAlloc(io, arena);
    const repo = git.Repo.openDiscover(cwd) catch |e| git.dieGit(&app, e);
    defer repo.close();

    var cfg = config.load(arena, io, parsed.config_path, repo.workdir()) catch {
        app.die("failed to read recurse.toml", .{});
    };
    if (parsed.recursive) |r| cfg.recursive = r;

    switch (parsed.cmd) {
        .status => try cmd_status.run(&app, parsed, cfg, repo),
        .sync => try cmd_sync.run(&app, parsed, cfg, repo),
        .commit => try cmd_commit.run(&app, parsed, cfg, repo),
        .pull => try cmd_pull.run(&app, parsed, cfg, repo),
        .push => try cmd_push.run(&app, parsed, cfg, repo),
        .verify => try cmd_verify.run(&app, parsed, cfg, repo),
        .help => unreachable,
    }
}
