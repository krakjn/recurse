const std = @import("std");
const App = @import("../app.zig").App;
const git = @import("../git.zig");
const config = @import("../config.zig");
const cli = @import("../cli.zig");

pub fn run(app: *App, parsed: cli.Parsed, cfg: config.Config, repo: git.Repo) !void {
    const recursive = parsed.recursive orelse cfg.recursive;
    var subs: std.ArrayList(git.Sub) = .empty;
    git.listSubs(app.arena, repo.ptr, "", recursive, &subs) catch |e| git.dieGit(app, e);

    var failures: std.ArrayList([]const u8) = .empty;
    var ok: usize = 0;

    for (subs.items) |s| {
        if (s.skip) continue;
        if (s.uninitialized or s.head_oid == null) {
            try failures.append(app.arena, s.path);
            continue;
        }
        if (!s.direct) continue;

        const child = git.openSub(repo.ptr, s.name, app.arena) catch {
            try failures.append(app.arena, s.path);
            continue;
        };
        defer child.close();

        if (cfg.verify_fetch) {
            git.fetchRemote(child.ptr, "origin") catch {
                try failures.append(app.arena, s.path);
                continue;
            };
        }

        git.lookupOidAfterFetch(child.ptr, &s.head_oid.?) catch {
            try failures.append(app.arena, s.path);
            continue;
        };
        ok += 1;
    }

    if (parsed.json) {
        try app.print("{{\"ok\":{s},\"checked\":{d},\"failures\":[", .{
            if (failures.items.len == 0) "true" else "false",
            ok,
        });
        for (failures.items, 0..) |p, i| {
            if (i != 0) try app.print(",", .{});
            try app.print("\"{s}\"", .{p});
        }
        try app.print("]}}\n", .{});
    } else {
        for (failures.items) |p| {
            try app.print("missing on remote: {s}\n", .{p});
        }
        if (failures.items.len == 0) {
            try app.print("ok ({d} gitlinks on remote)\n", .{ok});
        }
    }

    if (failures.items.len > 0) std.process.exit(1);
}
