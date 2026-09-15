const std = @import("std");

pub const Cmd = enum {
    status,
    sync,
    commit,
    pull,
    push,
    verify,
    help,
};

pub const Parsed = struct {
    cmd: Cmd = .status,
    config_path: ?[]const u8 = null,
    jobs: u32 = 0,
    recursive: ?bool = null,
    message: ?[]const u8 = null,
    json: bool = false,
    paths: []const []const u8 = &.{},
};

pub const ParseError = error{ Usage, OutOfMemory };

pub fn parse(arena: std.mem.Allocator, args: []const []const u8) ParseError!Parsed {
    var out: Parsed = .{};
    var paths: std.ArrayList([]const u8) = .empty;
    var i: usize = 1; // skip argv0
    var seen_cmd = false;

    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            out.cmd = .help;
            return out;
        }
        if (std.mem.eql(u8, a, "--config")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.config_path = args[i];
            continue;
        }
        if (std.mem.startsWith(u8, a, "--config=")) {
            out.config_path = a["--config=".len..];
            continue;
        }
        if (std.mem.eql(u8, a, "--jobs")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.jobs = std.fmt.parseInt(u32, args[i], 10) catch return error.Usage;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--jobs=")) {
            out.jobs = std.fmt.parseInt(u32, a["--jobs=".len..], 10) catch return error.Usage;
            continue;
        }
        if (std.mem.eql(u8, a, "--recursive")) {
            out.recursive = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-recursive")) {
            out.recursive = false;
            continue;
        }
        if (std.mem.eql(u8, a, "--json")) {
            out.json = true;
            continue;
        }
        if (std.mem.eql(u8, a, "-m") or std.mem.eql(u8, a, "--message")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.message = args[i];
            continue;
        }
        if (std.mem.startsWith(u8, a, "-m")) {
            // git-style -mMSG
            if (a.len > 2) out.message = a[2..];
            continue;
        }
        if (std.mem.startsWith(u8, a, "--message=")) {
            out.message = a["--message=".len..];
            continue;
        }
        if (a.len > 0 and a[0] == '-') return error.Usage;

        if (!seen_cmd) {
            seen_cmd = true;
            out.cmd = std.meta.stringToEnum(Cmd, a) orelse return error.Usage;
            continue;
        }
        try paths.append(arena, a);
    }

    out.paths = try paths.toOwnedSlice(arena);
    return out;
}

pub const usage =
    \\Recurse (rc) — git-shaped frontend for a superproject with submodules.
    \\
    \\Usage: recurse [command] [options]
    \\
    \\Commands:
    \\  status              recursive snapshot (default)
    \\  sync                checkout gitlinks from parent HEAD (fails if dirty)
    \\  commit [-m MSG]     commit children then the superproject
    \\  pull [PATH]         pull parent then sync, or absorb one nested repo
    \\  push                push children then the superproject
    \\  verify [--json]     fail if a gitlink SHA is missing on its remote
    \\
    \\Options:
    \\  --config PATH       recurse.toml override
    \\  --recursive / --no-recursive
    \\  --jobs N
    \\  -h, --help
    \\
;

test "parse default status" {
    const parsed = try parse(std.testing.allocator, &.{ "recurse" });
    try std.testing.expectEqual(Cmd.status, parsed.cmd);
}

test "parse commit -m" {
    const parsed = try parse(std.testing.allocator, &.{ "recurse", "commit", "-m", "hi" });
    try std.testing.expectEqual(Cmd.commit, parsed.cmd);
    try std.testing.expectEqualStrings("hi", parsed.message.?);
}
