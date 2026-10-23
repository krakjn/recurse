const std = @import("std");
const Io = std.Io;
const style = @import("style.zig");

pub const App = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    stdout_color: bool = false,
    stderr_color: bool = false,

    pub fn die(self: *App, comptime fmt: []const u8, args: anytype) noreturn {
        self.stdout.flush() catch {};
        const line = std.fmt.allocPrint(self.arena, fmt, args) catch {
            self.stderr.writeAll("out of memory\n") catch {};
            self.stderr.flush() catch {};
            std.process.exit(1);
        };
        style.write(self.stderr, self.stderr_color, .red, line) catch {};
        self.stderr.writeAll("\n") catch {};
        self.stderr.flush() catch {};
        std.process.exit(1);
    }

    /// `where` is red bold and `msg` is red. An empty `where` prints `msg` alone.
    /// With color off the text is still `where: msg`.
    pub fn report(self: *App, where: []const u8, msg: []const u8) noreturn {
        self.stdout.flush() catch {};
        if (where.len == 0) {
            style.write(self.stderr, self.stderr_color, .red, msg) catch {};
        } else {
            style.write(self.stderr, self.stderr_color, .red_bold, where) catch {};
            self.stderr.writeAll(": ") catch {};
            style.write(self.stderr, self.stderr_color, .red, msg) catch {};
        }
        self.stderr.writeAll("\n") catch {};
        self.stderr.flush() catch {};
        std.process.exit(1);
    }

    pub fn print(self: *App, comptime fmt: []const u8, args: anytype) !void {
        try self.stdout.print(fmt, args);
    }

    pub fn paint(self: *App, tone: style.Tone, text: []const u8) !void {
        try style.write(self.stdout, self.stdout_color, tone, text);
    }

    pub fn paintErr(self: *App, tone: style.Tone, text: []const u8) void {
        style.write(self.stderr, self.stderr_color, tone, text) catch {};
    }

    pub fn ok(self: *App, verb: []const u8, path: []const u8) !void {
        try self.paint(.green_bold, verb);
        try self.stdout.print(" {s}\n", .{path});
    }

    pub fn okBranch(self: *App, verb: []const u8, path: []const u8, branch: []const u8) !void {
        try self.paint(.green_bold, verb);
        try self.stdout.print(" {s} (", .{path});
        try self.paint(.cyan, branch);
        try self.stdout.writeAll(")\n");
    }
};
