const std = @import("std");
const source = @import("source.zig");
const translator = @import("translator.zig");

const usage =
    \\usage: pseudocode_compiler <input.pseudo> [-o output.py]
    \\
    \\  -o <file>   write the generated python to a file instead of stdout
    \\  -h          show this message
    \\
;

const Options = struct {
    inputPath: []const u8,
    outputPath: ?[]const u8 = null,
};

const ArgError = error{ MissingInput, MissingOutputPath, UnknownOption };

fn parseArgs(args: []const []const u8) ArgError!Options {
    var inputPath: ?[]const u8 = null;
    var outputPath: ?[]const u8 = null;

    var i: usize = 1; // args[0] is the program name
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) return error.MissingOutputPath;
            outputPath = args[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else {
            inputPath = arg;
        }
    }

    const path = inputPath orelse return error.MissingInput;
    return Options{ .inputPath = path, .outputPath = outputPath };
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
        }
    }

    const options = parseArgs(args) catch |err| {
        switch (err) {
            error.MissingInput => std.debug.print("error: no input file given\n\n", .{}),
            error.MissingOutputPath => std.debug.print("error: -o needs a file name\n\n", .{}),
            error.UnknownOption => std.debug.print("error: unknown option\n\n", .{}),
        }
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    };

    const text = source.readSource(init.io, arena, options.inputPath) catch |err| {
        std.debug.print("error: cannot read '{s}': {s}\n", .{ options.inputPath, @errorName(err) });
        std.process.exit(1);
    };

    var diagnostic = translator.Diagnostic{};
    const python = translator.translate(arena, text, &diagnostic) catch |err| switch (err) {
        error.SyntaxError => {
            std.debug.print("{s}:{d}:{d}: error: {s}\n", .{ options.inputPath, diagnostic.line, diagnostic.column, diagnostic.message });
            std.process.exit(1);
        },
        error.OutOfMemory => return err,
    };

    if (options.outputPath) |path| {
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = python });
    } else {
        try std.Io.File.stdout().writeStreamingAll(init.io, python);
    }
}

test "parseArgs accepts an input file" {
    const options = try parseArgs(&.{ "prog", "a.pseudo" });
    try std.testing.expectEqualStrings("a.pseudo", options.inputPath);
    try std.testing.expect(options.outputPath == null);
}

test "parseArgs reads the output option" {
    const options = try parseArgs(&.{ "prog", "a.pseudo", "-o", "a.py" });
    try std.testing.expectEqualStrings("a.py", options.outputPath.?);
}

test "parseArgs rejects missing input and unknown options" {
    try std.testing.expectError(error.MissingInput, parseArgs(&.{"prog"}));
    try std.testing.expectError(error.MissingOutputPath, parseArgs(&.{ "prog", "a.pseudo", "-o" }));
    try std.testing.expectError(error.UnknownOption, parseArgs(&.{ "prog", "-x" }));
}

// tests in other files only run if main.zig references them
test {
    _ = @import("source.zig");
    _ = @import("lexer.zig");
    _ = @import("translator.zig");
}
