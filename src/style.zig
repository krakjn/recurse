const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const When = enum { auto, always, never };

pub const Tone = enum {
    plain,
    dim,
    cyan,
    cyan_bold,
    yellow,
    green_bold,
    red,
    red_bold,
    magenta,

    fn open(self: Tone) []const u8 {
        return switch (self) {
            .plain => "",
            .dim => "\x1b[2m",
            .cyan => "\x1b[36m",
            .cyan_bold => "\x1b[1;36m",
            .yellow => "\x1b[33m",
            .green_bold => "\x1b[1;32m",
            .red => "\x1b[31m",
            .red_bold => "\x1b[1;31m",
            .magenta => "\x1b[35m",
        };
    }
};

const reset = "\x1b[0m";

/// `auto` paints only a TTY, and only when `NO_COLOR` is unset.
/// `always` and `never` ignore both.
pub fn enabled(when: When, tty: bool, no_color: bool) bool {
    return switch (when) {
        .always => true,
        .never => false,
        .auto => tty and !no_color,
    };
}

pub fn write(w: *Io.Writer, on: bool, tone: Tone, text: []const u8) !void {
    if (text.len == 0) return;
    if (!on or tone == .plain) {
        try w.writeAll(text);
        return;
    }
    try w.writeAll(tone.open());
    try w.writeAll(text);
    try w.writeAll(reset);
}

fn writeDots(w: *Io.Writer, on: bool, n: usize) !void {
    if (n == 0) return;
    if (!on) {
        try w.splatByteAll('.', n);
        return;
    }
    try w.writeAll(Tone.dim.open());
    try w.splatByteAll('.', n);
    try w.writeAll(reset);
}

/// Path field of `col` columns.
/// Fits: path, a space, then dim dots. The space keeps "." from vanishing into the leaders.
/// Too narrow: a suffix and exactly `..`.
pub fn writePath(w: *Io.Writer, on: bool, path: []const u8, col: usize) !void {
    const width = @max(col, 3);
    if (path.len + 2 <= width) {
        try w.writeAll(path);
        const pad = width - path.len;
        try w.writeByte(' ');
        try writeDots(w, on, pad - 1);
    } else {
        const keep = width - 2;
        try w.writeAll(path[path.len - keep ..]);
        try writeDots(w, on, 2);
    }
}

pub fn fitLabel(label: []const u8, col: usize) []const u8 {
    const width = @max(col, 1);
    if (label.len > width) return label[label.len - width ..];
    return label;
}

pub const path_dot_pad = 10;
pub const path_min_col = 6;
pub const branch_max_col = 25;
pub const marker_budget = 8;

pub const Layout = struct {
    path_col: usize,
    branch_col: usize,
};

pub fn lineLayout(max_path: usize, term_cols: usize) Layout {
    // Keep every intermediate a usize. @min/@max otherwise pick a tiny
    // integer for the comptime bounds, and 25 + 8 overflows it on a wide tty.
    const cols: usize = if (term_cols == 0) 80 else term_cols;
    const desired: usize = max_path + path_dot_pad;
    const branch_reserve: usize = @max(@min(@as(usize, branch_max_col), cols / 3), @as(usize, 4));
    const path_cap: usize = cols -| (branch_reserve + @as(usize, marker_budget));
    const path_floor: usize = @min(@as(usize, path_min_col), cols -| (@as(usize, marker_budget) + 4));
    const path_col: usize = @max(@min(desired, path_cap), path_floor);
    const branch_span: usize = cols -| (path_col + @as(usize, marker_budget));
    return .{
        .path_col = @max(path_col, @as(usize, 3)),
        .branch_col = std.math.clamp(branch_span, @as(usize, 4), branch_max_col),
    };
}

pub fn terminalColumns(io: Io, environ: *std.process.Environ.Map) usize {
    if (environ.get("COLUMNS")) |raw| {
        const n = std.fmt.parseInt(usize, raw, 10) catch 0;
        if (n > 0) return n;
    }
    return detectColumns(io) orelse 80;
}

fn detectColumns(io: Io) ?usize {
    switch (builtin.os.tag) {
        .windows, .wasi => return null,
        else => {
            var size: std.posix.winsize = .{
                .row = 0,
                .col = 0,
                .xpixel = 0,
                .ypixel = 0,
            };
            const result = io.operate(.{ .device_io_control = .{
                .file = Io.File.stdout(),
                .code = std.posix.T.IOCGWINSZ,
                .arg = &size,
            } }) catch return null;
            if (result.device_io_control < 0 or size.col == 0) return null;
            return size.col;
        },
    }
}

fn capture(buf: []u8, on: bool, path: []const u8, col: usize) ![]u8 {
    var w = Io.Writer.fixed(buf);
    try writePath(&w, on, path, col);
    return w.buffered();
}

test "color follows when, tty, and NO_COLOR" {
    try std.testing.expect(!enabled(.never, true, false));
    try std.testing.expect(enabled(.always, false, true));
    try std.testing.expect(enabled(.auto, true, false));
    try std.testing.expect(!enabled(.auto, true, true));
    try std.testing.expect(!enabled(.auto, false, false));
}

test "wide terminal layout stays in range" {
    var cols: usize = 120;
    // Address-taken so the width is not folded away and the safety checks run.
    _ = &cols;
    const layout = lineLayout(16, cols);
    try std.testing.expect(layout.path_col >= 16);
    try std.testing.expect(layout.path_col <= cols);
    try std.testing.expect(layout.branch_col >= 4);
    try std.testing.expect(layout.branch_col <= branch_max_col);
}

test "path pads with a space and dots" {
    const layout = lineLayout(4, 100);
    try std.testing.expectEqual(@as(usize, 14), layout.path_col);
    var buf: [32]u8 = undefined;
    const got = try capture(&buf, false, "abcd", layout.path_col);
    try std.testing.expectEqualStrings("abcd .........", got);
    var wide: [32]u8 = undefined;
    const dots = try capture(&wide, false, "a", layout.path_col);
    try std.testing.expectEqualStrings("a ............", dots);
}

test "path keeps a suffix and two dots when truncated" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("e/path..", try capture(&buf, false, "../some/path", 8));
    try std.testing.expectEqualStrings("cdefghij..", try capture(&buf, false, "abcdefghij", 10));
    try std.testing.expectEqualStrings("ab ...", try capture(&buf, false, "ab", 6));
}

test "narrow terminal still leaves a branch column" {
    const layout = lineLayout(10, 30);
    try std.testing.expect(layout.path_col >= path_min_col);
    try std.testing.expect(layout.branch_col >= 4);
    var buf: [32]u8 = undefined;
    const got = try capture(&buf, false, "../reflect/very/long", 8);
    try std.testing.expectEqualStrings("y/long..", got);
}

test "paint wraps only when color is on" {
    var plain: [16]u8 = undefined;
    var w = Io.Writer.fixed(&plain);
    try write(&w, false, .green_bold, "clean");
    try std.testing.expectEqualStrings("clean", w.buffered());

    var colored: [32]u8 = undefined;
    var c = Io.Writer.fixed(&colored);
    try write(&c, true, .green_bold, "clean");
    try std.testing.expectEqualStrings("\x1b[1;32mclean\x1b[0m", c.buffered());
}
