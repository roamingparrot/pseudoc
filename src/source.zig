const std = @import("std");

const maxSourceBytes = 1024 * 1024;

pub fn readSource(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(maxSourceBytes));
}
