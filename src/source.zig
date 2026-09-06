const std = @import("std");

const maxSourceBytes = 1024 * 1024;

pub fn readSource(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(maxSourceBytes));
}

pub const Line = struct {
    number: usize, // 1-based, counted in the original file
    text: []const u8, // trimmed
};

/// Splits the program into trimmed lines. Blank lines and lines that only
/// contain a // comment are dropped, but the original line numbers are kept
/// so error messages can point at the right place.
pub fn splitLines(gpa: std.mem.Allocator, text: []const u8) ![]Line {
    var lines: std.ArrayList(Line) = .empty;
    var number: usize = 0;
    var iterator = std.mem.splitScalar(u8, text, '\n');
    while (iterator.next()) |rawLine| {
        number += 1;
        const trimmed = std.mem.trim(u8, rawLine, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        try lines.append(gpa, .{ .number = number, .text = trimmed });
    }
    return lines.toOwnedSlice(gpa);
}

test "splitLines trims and skips blank and comment lines" {
    const text = "  x <- 1  \n\n// a comment\r\nOUTPUT x\n";
    const lines = try splitLines(std.testing.allocator, text);
    defer std.testing.allocator.free(lines);

    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("x <- 1", lines[0].text);
    try std.testing.expectEqual(@as(usize, 1), lines[0].number);
    try std.testing.expectEqualStrings("OUTPUT x", lines[1].text);
    try std.testing.expectEqual(@as(usize, 4), lines[1].number);
}
