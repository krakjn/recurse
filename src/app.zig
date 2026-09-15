const std = @import("std");
const Io = std.Io;

pub const App = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    stdout: *Io.Writer,
    stderr: *Io.Writer,

    pub fn die(self: *App, comptime fmt: []const u8, args: anytype) noreturn {
        self.stdout.flush() catch {};
        self.stderr.print(fmt ++ "\n", args) catch {};
        self.stderr.flush() catch {};
        std.process.exit(1);
    }

    pub fn print(self: *App, comptime fmt: []const u8, args: anytype) !void {
        try self.stdout.print(fmt, args);
    }
};
