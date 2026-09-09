const std = @import("std");
const lexer = @import("lexer.zig");

const Token = lexer.Token;
const TokenKind = lexer.TokenKind;

pub const Diagnostic = struct {
    line: usize = 0,
    column: usize = 0,
    message: []const u8 = "",
};

pub const TranslateError = error{ SyntaxError, OutOfMemory };

const indentWidth = 4;

const Translator = struct {
    arena: std.mem.Allocator,
    tokens: []const Token,
    position: usize = 0,
    output: std.ArrayList(u8) = .empty,
    indentLevel: usize = 0,
    diagnostic: *Diagnostic,

    fn current(self: *Translator) Token {
        return self.tokens[self.position];
    }

    fn advance(self: *Translator) Token {
        const token = self.tokens[self.position];
        if (token.kind != .eof) self.position += 1;
        return token;
    }

    fn check(self: *Translator, kind: TokenKind) bool {
        return self.current().kind == kind;
    }

    fn describe(self: *Translator, token: Token) ![]const u8 {
        return switch (token.kind) {
            .newline => "end of line",
            .eof => "end of file",
            else => try std.fmt.allocPrint(self.arena, "'{s}'", .{token.text}),
        };
    }

    fn fail(self: *Translator, token: Token, comptime format: []const u8, args: anytype) TranslateError {
        self.diagnostic.* = .{
            .line = token.line,
            .column = token.column,
            .message = try std.fmt.allocPrint(self.arena, format, args),
        };
        return error.SyntaxError;
    }

    fn expect(self: *Translator, kind: TokenKind, what: []const u8) TranslateError!Token {
        if (!self.check(kind)) {
            const found = try self.describe(self.current());
            return self.fail(self.current(), "expected {s} but found {s}", .{ what, found });
        }
        return self.advance();
    }

    fn emit(self: *Translator, text: []const u8) !void {
        try self.output.appendNTimes(self.arena, ' ', self.indentLevel * indentWidth);
        try self.output.appendSlice(self.arena, text);
        try self.output.append(self.arena, '\n');
    }

    fn skipNewlines(self: *Translator) void {
        while (self.check(.newline)) _ = self.advance();
    }

    fn endOfStatement(self: *Translator) TranslateError!void {
        if (self.check(.newline)) {
            _ = self.advance();
        } else if (!self.check(.eof)) {
            const found = try self.describe(self.current());
            return self.fail(self.current(), "unexpected {s} at the end of the statement", .{found});
        }
    }

    fn translateProgram(self: *Translator) TranslateError!void {
        self.skipNewlines();
        while (!self.check(.eof)) {
            try self.translateStatement();
            self.skipNewlines();
        }
    }

    fn translateStatement(self: *Translator) TranslateError!void {
        const token = self.current();
        switch (token.kind) {
            .identifier => try self.translateAssignment(),
            else => {
                const found = try self.describe(token);
                return self.fail(token, "unexpected {s}, expected a statement", .{found});
            },
        }
    }

    fn translateAssignment(self: *Translator) TranslateError!void {
        const name = self.advance();
        _ = try self.expect(.arrow, "'<-' or '\u{2190}' after the variable name");
        const value = try self.parseExpression();
        try self.endOfStatement();
        const line = try std.fmt.allocPrint(self.arena, "{s} = {s}", .{ name.text, value });
        try self.emit(line);
    }

    // For now an expression is a single literal or variable name.
    fn parseExpression(self: *Translator) TranslateError![]const u8 {
        const token = self.current();
        switch (token.kind) {
            .integer, .real, .string, .identifier => {
                _ = self.advance();
                return token.text;
            },
            else => {
                const found = try self.describe(token);
                return self.fail(token, "expected a value but found {s}", .{found});
            },
        }
    }
};

/// Translates CIE pseudocode into Python source. Everything is allocated
/// from `arena`, which the caller frees all at once. On a syntax error the
/// position and message are stored in `diagnostic`.
pub fn translate(arena: std.mem.Allocator, source: []const u8, diagnostic: *Diagnostic) TranslateError![]const u8 {
    const tokens = try lexer.tokenize(arena, source);
    var translator = Translator{
        .arena = arena,
        .tokens = tokens,
        .diagnostic = diagnostic,
    };
    try translator.translateProgram();
    return translator.output.items;
}

fn expectPython(source: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic = Diagnostic{};
    const python = translate(arena.allocator(), source, &diagnostic) catch |err| {
        std.debug.print("line {d}: {s}\n", .{ diagnostic.line, diagnostic.message });
        return err;
    };
    try std.testing.expectEqualStrings(expected, python);
}

fn expectError(source: []const u8, expectedLine: usize, expectedMessage: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic = Diagnostic{};
    try std.testing.expectError(error.SyntaxError, translate(arena.allocator(), source, &diagnostic));
    try std.testing.expectEqual(expectedLine, diagnostic.line);
    try std.testing.expectEqualStrings(expectedMessage, diagnostic.message);
}

test "assignment with the ascii arrow" {
    try expectPython("x <- 10\n", "x = 10\n");
}

test "assignment with the unicode arrow" {
    try expectPython("x \u{2190} 10\n", "x = 10\n");
}

test "assignment of a string keeps its text" {
    try expectPython("name <- \"Ada\"\n", "name = \"Ada\"\n");
}

test "blank lines and comments are ignored" {
    try expectPython("\n// set up\nx <- 1\n\n", "x = 1\n");
}

test "missing arrow is reported with its line" {
    try expectError("x <- 1\ny 2\n", 2, "expected '<-' or '\u{2190}' after the variable name but found '2'");
}
