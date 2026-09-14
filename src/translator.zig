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
            .kw_output => try self.translateOutput(),
            .kw_input => try self.translateInput(),
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

    fn translateInput(self: *Translator) TranslateError!void {
        _ = self.advance(); // INPUT
        const name = try self.expect(.identifier, "a variable name after INPUT");
        try self.endOfStatement();
        const line = try std.fmt.allocPrint(self.arena, "{s} = input()", .{name.text});
        try self.emit(line);
    }

    // OUTPUT a, b prints the values with nothing between them, so a single
    // value can use plain print() but several need sep="".
    fn translateOutput(self: *Translator) TranslateError!void {
        _ = self.advance(); // OUTPUT
        var arguments: std.ArrayList(u8) = .empty;
        try arguments.appendSlice(self.arena, try self.parseExpression());
        var count: usize = 1;
        while (self.check(.comma)) {
            _ = self.advance();
            try arguments.appendSlice(self.arena, ", ");
            try arguments.appendSlice(self.arena, try self.parseExpression());
            count += 1;
        }
        try self.endOfStatement();

        const separator = if (count > 1) ", sep=\"\"" else "";
        const line = try std.fmt.allocPrint(self.arena, "print({s}{s})", .{ arguments.items, separator });
        try self.emit(line);
    }

    // Expressions are parsed by precedence climbing, one function per
    // level, lowest precedence first. Each one returns the Python text.
    fn parseExpression(self: *Translator) TranslateError![]const u8 {
        return self.parseAdditive();
    }

    fn joinBinary(self: *Translator, left: []const u8, operator: []const u8, right: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena, "{s} {s} {s}", .{ left, operator, right });
    }

    fn parseAdditive(self: *Translator) TranslateError![]const u8 {
        var left = try self.parseTerm();
        while (self.check(.plus) or self.check(.minus)) {
            const operator = self.advance();
            const right = try self.parseTerm();
            left = try self.joinBinary(left, operator.text, right);
        }
        return left;
    }

    fn parseTerm(self: *Translator) TranslateError![]const u8 {
        var left = try self.parseUnary();
        while (self.check(.star) or self.check(.slash) or self.check(.kw_div) or self.check(.kw_mod)) {
            const operator = self.advance();
            const right = try self.parseUnary();
            const pythonOperator = switch (operator.kind) {
                .kw_div => "//",
                .kw_mod => "%",
                else => operator.text,
            };
            left = try self.joinBinary(left, pythonOperator, right);
        }
        return left;
    }

    fn parseUnary(self: *Translator) TranslateError![]const u8 {
        if (self.check(.minus)) {
            _ = self.advance();
            const operand = try self.parseUnary();
            return std.fmt.allocPrint(self.arena, "-{s}", .{operand});
        }
        return self.parsePower();
    }

    // ^ binds tighter than unary minus and groups to the right
    fn parsePower(self: *Translator) TranslateError![]const u8 {
        const base = try self.parsePrimary();
        if (self.check(.caret)) {
            _ = self.advance();
            const exponent = try self.parseUnary();
            return self.joinBinary(base, "**", exponent);
        }
        return base;
    }

    // CIE strings have no escapes but Python strings do, so a backslash in
    // the pseudocode must be doubled to stay a plain backslash.
    fn pythonString(self: *Translator, text: []const u8) ![]const u8 {
        if (std.mem.indexOfScalar(u8, text, '\\') == null) return text;
        var escaped: std.ArrayList(u8) = .empty;
        for (text) |c| {
            if (c == '\\') try escaped.append(self.arena, '\\');
            try escaped.append(self.arena, c);
        }
        return escaped.items;
    }

    fn parsePrimary(self: *Translator) TranslateError![]const u8 {
        const token = self.current();
        switch (token.kind) {
            .string => {
                _ = self.advance();
                return self.pythonString(token.text);
            },
            .integer, .real, .identifier => {
                _ = self.advance();
                return token.text;
            },
            .l_paren => {
                _ = self.advance();
                const inner = try self.parseExpression();
                _ = try self.expect(.r_paren, "')'");
                return std.fmt.allocPrint(self.arena, "({s})", .{inner});
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

test "output of a single value" {
    try expectPython("OUTPUT \"hello\"\n", "print(\"hello\")\n");
}

test "output of several values has no separator" {
    try expectPython("OUTPUT \"x = \", x\n", "print(\"x = \", x, sep=\"\")\n");
}

test "output without a value is an error" {
    try expectError("OUTPUT\n", 1, "expected a value but found end of line");
}

test "input reads into a variable" {
    try expectPython("INPUT name\n", "name = input()\n");
}

test "input needs a variable name" {
    try expectError("INPUT 5\n", 1, "expected a variable name after INPUT but found '5'");
}

test "arithmetic keeps operators and brackets" {
    try expectPython("x <- (a + 2) * 3 - b / 4\n", "x = (a + 2) * 3 - b / 4\n");
}

test "unary minus" {
    try expectPython("x <- -5 + -y\n", "x = -5 + -y\n");
}

test "real numbers" {
    try expectPython("pi <- 3.14159\n", "pi = 3.14159\n");
}

test "missing closing bracket" {
    try expectError("x <- (1 + 2\n", 1, "expected ')' but found end of line");
}

test "div and mod become integer division and remainder" {
    try expectPython("q <- a DIV 3\nr <- a MOD 3\n", "q = a // 3\nr = a % 3\n");
}

test "power operator" {
    try expectPython("x <- 2 ^ 3 ^ 2\n", "x = 2 ** 3 ** 2\n");
    try expectPython("x <- 2 * n ^ 2\n", "x = 2 * n ** 2\n");
}

test "operator words inside strings are left alone" {
    try expectPython("OUTPUT \"a <> b AND c MOD 2 <- 1\"\n", "print(\"a <> b AND c MOD 2 <- 1\")\n");
}

test "backslashes in strings are escaped for python" {
    try expectPython("OUTPUT \"C:\\new\"\n", "print(\"C:\\\\new\")\n");
}

test "missing arrow is reported with its line" {
    try expectError("x <- 1\ny 2\n", 2, "expected '<-' or '\u{2190}' after the variable name but found '2'");
}
