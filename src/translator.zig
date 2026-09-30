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

const VarType = enum {
    integer,
    real,
    string,
    char,
    boolean,

    fn fromName(name: []const u8) ?VarType {
        const names = [_]struct { []const u8, VarType }{
            .{ "INTEGER", .integer },
            .{ "REAL", .real },
            .{ "STRING", .string },
            .{ "CHAR", .char },
            .{ "BOOLEAN", .boolean },
        };
        for (names) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return null;
    }

    // value a freshly declared variable starts with
    fn defaultValue(self: VarType) []const u8 {
        return switch (self) {
            .integer => "0",
            .real => "0.0",
            .string, .char => "\"\"",
            .boolean => "False",
        };
    }
};

// The left hand side of an assignment or INPUT: a variable or an array element
const Target = struct {
    name: Token,
    text: []const u8,
};

const Translator = struct {
    arena: std.mem.Allocator,
    tokens: []const Token,
    position: usize = 0,
    output: std.ArrayList(u8) = .empty,
    indentLevel: usize = 0,
    diagnostic: *Diagnostic,
    declaredTypes: std.StringHashMapUnmanaged(VarType) = .empty,

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

    // Error for a token that cannot start whatever is being parsed. Bad
    // characters and unterminated strings get a message of their own.
    fn failUnexpected(self: *Translator, token: Token, expectation: []const u8) TranslateError {
        if (token.kind == .invalid) {
            const first = token.text[0];
            if (first == '"' or first == '\'') {
                return self.fail(token, "unterminated string literal", .{});
            }
            return self.fail(token, "unexpected character '{s}'", .{token.text});
        }
        const found = try self.describe(token);
        return self.fail(token, "expected {s} but found {s}", .{ expectation, found });
    }

    fn expect(self: *Translator, kind: TokenKind, what: []const u8) TranslateError!Token {
        if (!self.check(kind)) return self.failUnexpected(self.current(), what);
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
        } else if (self.check(.invalid)) {
            return self.failUnexpected(self.current(), "the end of the statement");
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
            .kw_declare => try self.translateDeclare(),
            .kw_if => try self.translateIf(),
            .kw_for => try self.translateFor(),
            .kw_while => try self.translateWhile(),
            .kw_repeat => try self.translateRepeat(),
            .kw_case => try self.translateCase(),
            .kw_else, .kw_endif => {
                return self.fail(token, "{s} without a matching IF", .{token.text});
            },
            .kw_endcase => return self.fail(token, "ENDCASE without a matching CASE", .{}),
            .kw_otherwise => return self.fail(token, "OTHERWISE outside of a CASE statement", .{}),
            .kw_until => return self.fail(token, "UNTIL without a matching REPEAT", .{}),
            .kw_endwhile => return self.fail(token, "ENDWHILE without a matching WHILE", .{}),
            .kw_next => return self.fail(token, "NEXT without a matching FOR", .{}),
            else => return self.failUnexpected(token, "a statement"),
        }
    }

    fn atAny(self: *Translator, kinds: []const TokenKind) bool {
        for (kinds) |kind| {
            if (self.check(kind)) return true;
        }
        return false;
    }

    // Translates statements one indent level deeper until one of the
    // `closers` tokens is next. The closer itself is left for the caller.
    fn translateBlock(self: *Translator, opener: Token, closers: []const TokenKind, closerName: []const u8) TranslateError!void {
        self.indentLevel += 1;
        const outputBefore = self.output.items.len;
        self.skipNewlines();
        while (!self.atAny(closers)) {
            if (self.check(.eof)) {
                return self.fail(self.current(), "{s} on line {d} is missing its {s}", .{ opener.text, opener.line, closerName });
            }
            try self.translateStatement();
            self.skipNewlines();
        }
        // python does not allow an empty block
        if (self.output.items.len == outputBefore) try self.emit("pass");
        self.indentLevel -= 1;
    }

    fn translateIf(self: *Translator) TranslateError!void {
        const ifToken = self.advance();
        const condition = try self.parseExpression();
        _ = try self.expect(.kw_then, "THEN after the condition");
        try self.endOfStatement();
        try self.emit(try std.fmt.allocPrint(self.arena, "if {s}:", .{condition}));

        try self.translateBlock(ifToken, &.{ .kw_else, .kw_endif }, "ENDIF");

        if (self.check(.kw_else)) {
            _ = self.advance(); // ELSE
            try self.endOfStatement();
            try self.emit("else:");
            try self.translateBlock(ifToken, &.{.kw_endif}, "ENDIF");
        }
        _ = self.advance(); // ENDIF
        try self.endOfStatement();
    }

    fn isIntegerText(text: []const u8) bool {
        if (text.len == 0) return false;
        for (text) |c| {
            if (c < '0' or c > '9') return false;
        }
        return true;
    }

    // Python text for "bound + offset" where offset is +1 or -1. A plain
    // number is added up directly so the generated code reads
    // range(1, 11) instead of range(1, 10 + 1).
    fn shiftBound(self: *Translator, bound: []const u8, offset: i64) ![]const u8 {
        if (isIntegerText(bound)) {
            if (std.fmt.parseInt(i64, bound, 10)) |value| {
                return std.fmt.allocPrint(self.arena, "{d}", .{value + offset});
            } else |_| {}
        }
        const sign: u8 = if (offset > 0) '+' else '-';
        return std.fmt.allocPrint(self.arena, "{s} {c} 1", .{ bound, sign });
    }

    // The range stops one past the bound when counting up and one before it
    // when counting down. With a literal step the direction is known now;
    // otherwise python has to work it out from the sign of the step.
    fn loopStop(self: *Translator, end: []const u8, step: ?[]const u8) ![]const u8 {
        const stepText = step orelse return self.shiftBound(end, 1);

        if (isIntegerText(stepText)) return self.shiftBound(end, 1);
        if (std.mem.startsWith(u8, stepText, "-") and isIntegerText(stepText[1..])) {
            return self.shiftBound(end, -1);
        }
        return std.fmt.allocPrint(self.arena, "{s} + (1 if {s} > 0 else -1)", .{ end, stepText });
    }

    // FOR i <- 1 TO 10 includes 10, but range() stops before its end value,
    // so the generated range ends one past the CIE upper bound.
    fn translateFor(self: *Translator) TranslateError!void {
        const forToken = self.advance();
        const variable = try self.expect(.identifier, "a loop variable after FOR");
        _ = try self.expect(.arrow, "'<-' or '\u{2190}' after the loop variable");
        const start = try self.parseExpression();
        _ = try self.expect(.kw_to, "TO after the start value");
        const end = try self.parseExpression();

        var step: ?[]const u8 = null;
        if (self.check(.kw_step)) {
            _ = self.advance(); // STEP
            step = try self.parseExpression();
        }
        try self.endOfStatement();

        const stop = try self.loopStop(end, step);

        var header: []const u8 = undefined;
        if (step) |stepText| {
            header = try std.fmt.allocPrint(self.arena, "for {s} in range({s}, {s}, {s}):", .{ variable.text, start, stop, stepText });
        } else {
            header = try std.fmt.allocPrint(self.arena, "for {s} in range({s}, {s}):", .{ variable.text, start, stop });
        }
        try self.emit(header);

        try self.translateBlock(forToken, &.{.kw_next}, "NEXT");
        _ = self.advance(); // NEXT
        if (self.check(.identifier)) {
            const named = self.advance();
            if (!std.mem.eql(u8, named.text, variable.text)) {
                return self.fail(named, "NEXT {s} does not match the loop variable {s} from line {d}", .{ named.text, variable.text, forToken.line });
            }
        }
        try self.endOfStatement();
    }

    fn translateWhile(self: *Translator) TranslateError!void {
        const whileToken = self.advance();
        const condition = try self.parseExpression();
        if (self.check(.kw_do)) _ = self.advance(); // DO is optional
        try self.endOfStatement();
        try self.emit(try std.fmt.allocPrint(self.arena, "while {s}:", .{condition}));

        try self.translateBlock(whileToken, &.{.kw_endwhile}, "ENDWHILE");
        _ = self.advance(); // ENDWHILE
        try self.endOfStatement();
    }

    // Python has no do-while, so REPEAT becomes an endless loop that
    // breaks out at the end of the body once the UNTIL condition is true.
    fn translateRepeat(self: *Translator) TranslateError!void {
        const repeatToken = self.advance();
        try self.endOfStatement();
        try self.emit("while True:");

        try self.translateBlock(repeatToken, &.{.kw_until}, "UNTIL");
        _ = self.advance(); // UNTIL
        const condition = try self.parseExpression();
        try self.endOfStatement();

        self.indentLevel += 1;
        try self.emit(try std.fmt.allocPrint(self.arena, "if {s}:", .{condition}));
        self.indentLevel += 1;
        try self.emit("break");
        self.indentLevel -= 2;
    }

    // Tokens that end the statements of one CASE branch: the start of the
    // next branch (a value or OTHERWISE) or ENDCASE. No statement can start
    // with a value, so this is unambiguous.
    const caseBranchEnd = [_]TokenKind{ .integer, .real, .string, .minus, .kw_true, .kw_false, .kw_otherwise, .kw_endcase };

    fn isPlainName(text: []const u8) bool {
        for (text) |c| {
            const isNameChar = std.ascii.isAlphanumeric(c) or c == '_' or c == '[' or c == ']';
            if (!isNameChar) return false;
        }
        return text.len > 0;
    }

    // CASE OF x becomes an if / elif / else chain comparing x with each value
    fn translateCase(self: *Translator) TranslateError!void {
        const caseToken = self.advance();
        _ = try self.expect(.kw_of, "OF after CASE");
        var selector = try self.parseExpression();
        try self.endOfStatement();

        // an expression is worked out once instead of in every comparison
        if (!isPlainName(selector)) {
            try self.emit(try std.fmt.allocPrint(self.arena, "_caseValue = {s}", .{selector}));
            selector = "_caseValue";
        }

        self.skipNewlines();
        var isFirstBranch = true;
        while (!self.check(.kw_endcase)) {
            if (self.check(.eof)) {
                return self.fail(self.current(), "CASE on line {d} is missing its ENDCASE", .{caseToken.line});
            }

            if (self.check(.kw_otherwise)) {
                _ = self.advance(); // OTHERWISE
                if (self.check(.colon)) _ = self.advance();
                try self.emit(if (isFirstBranch) "if True:" else "else:");
                try self.translateBlock(caseToken, &caseBranchEnd, "ENDCASE");
                if (!self.check(.kw_endcase)) {
                    return self.fail(self.current(), "OTHERWISE must be the last branch of the CASE", .{});
                }
                break;
            }

            if (!self.atAny(&caseBranchEnd)) return self.failUnexpected(self.current(), "a case value or OTHERWISE");
            const value = try self.parseAdditive();
            _ = try self.expect(.colon, "':' after the case value");
            const keyword = if (isFirstBranch) "if" else "elif";
            try self.emit(try std.fmt.allocPrint(self.arena, "{s} {s} == {s}:", .{ keyword, selector, value }));
            isFirstBranch = false;
            try self.translateBlock(caseToken, &caseBranchEnd, "ENDCASE");
        }
        _ = self.advance(); // ENDCASE
        try self.endOfStatement();
    }

    fn translateAssignment(self: *Translator) TranslateError!void {
        const target = try self.parseTarget("a variable name");
        _ = try self.expect(.arrow, "'<-' or '\u{2190}' after the variable name");
        const value = try self.parseExpression();
        try self.endOfStatement();
        const line = try std.fmt.allocPrint(self.arena, "{s} = {s}", .{ target.text, value });
        try self.emit(line);
    }

    // CIE arrays are usually indexed from 1. Arrays are created one element
    // longer than declared, so the CIE index can be used unchanged and
    // element 0 is simply never used.
    fn parseIndexSuffix(self: *Translator, base: []const u8) TranslateError![]const u8 {
        _ = self.advance(); // [
        const index = try self.parseExpression();
        if (self.check(.comma)) {
            return self.fail(self.current(), "two dimensional arrays are not supported", .{});
        }
        _ = try self.expect(.r_bracket, "']' after the index");
        return std.fmt.allocPrint(self.arena, "{s}[{s}]", .{ base, index });
    }

    fn parseTarget(self: *Translator, what: []const u8) TranslateError!Target {
        const name = try self.expect(.identifier, what);
        if (self.check(.l_bracket)) {
            return Target{ .name = name, .text = try self.parseIndexSuffix(name.text) };
        }
        return Target{ .name = name, .text = name.text };
    }

    fn parseTypeName(self: *Translator) TranslateError!VarType {
        const token = try self.expect(.identifier, "a type name such as INTEGER");
        return VarType.fromName(token.text) orelse
            self.fail(token, "unknown type '{s}' (supported: INTEGER, REAL, STRING, CHAR, BOOLEAN)", .{token.text});
    }

    // DECLARE count : INTEGER   or   DECLARE a, b : REAL
    fn translateDeclare(self: *Translator) TranslateError!void {
        _ = self.advance(); // DECLARE
        var names: std.ArrayList(Token) = .empty;
        try names.append(self.arena, try self.expect(.identifier, "a variable name after DECLARE"));
        while (self.check(.comma)) {
            _ = self.advance();
            try names.append(self.arena, try self.expect(.identifier, "a variable name"));
        }
        _ = try self.expect(.colon, "':' and a type");

        // an array declaration gives the element type and a size
        var arraySize: ?[]const u8 = null;
        if (self.check(.kw_array)) arraySize = try self.parseArrayBounds();

        const varType = try self.parseTypeName();
        try self.endOfStatement();

        for (names.items) |name| {
            // an array is remembered by its element type, which is what
            // INPUT needs when it reads into one element
            try self.declaredTypes.put(self.arena, name.text, varType);
            const initial = if (arraySize) |size|
                try std.fmt.allocPrint(self.arena, "[{s}] * {s}", .{ varType.defaultValue(), size })
            else
                varType.defaultValue();
            try self.emit(try std.fmt.allocPrint(self.arena, "{s} = {s}", .{ name.text, initial }));
        }
    }

    // Reads ARRAY[1:10] OF and returns the python text for the list length.
    fn parseArrayBounds(self: *Translator) TranslateError![]const u8 {
        _ = self.advance(); // ARRAY
        _ = try self.expect(.l_bracket, "'[' after ARRAY");
        const lower = try self.expect(.integer, "a whole number as the lower bound");
        _ = try self.expect(.colon, "':' between the array bounds");
        const upper = try self.parseExpression();
        if (self.check(.comma)) {
            return self.fail(self.current(), "two dimensional arrays are not supported", .{});
        }
        _ = try self.expect(.r_bracket, "']' after the array bounds");
        _ = try self.expect(.kw_of, "OF and the element type");
        _ = lower; // slots below the lower bound are unused, so it needs no code

        const size = try self.shiftBound(upper, 1);
        if (isIntegerText(size)) return size;
        return std.fmt.allocPrint(self.arena, "({s})", .{size});
    }

    fn translateInput(self: *Translator) TranslateError!void {
        _ = self.advance(); // INPUT
        const target = try self.parseTarget("a variable name after INPUT");
        try self.endOfStatement();

        // input() always returns text, so numbers need converting. That is
        // only possible when the variable was declared with a type.
        const reader = switch (self.declaredTypes.get(target.name.text) orelse .string) {
            .integer => "int(input())",
            .real => "float(input())",
            else => "input()",
        };
        const line = try std.fmt.allocPrint(self.arena, "{s} = {s}", .{ target.text, reader });
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
        return self.parseOr();
    }

    fn parseOr(self: *Translator) TranslateError![]const u8 {
        var left = try self.parseAnd();
        while (self.check(.kw_or)) {
            _ = self.advance();
            const right = try self.parseAnd();
            left = try self.joinBinary(left, "or", right);
        }
        return left;
    }

    fn parseAnd(self: *Translator) TranslateError![]const u8 {
        var left = try self.parseNot();
        while (self.check(.kw_and)) {
            _ = self.advance();
            const right = try self.parseNot();
            left = try self.joinBinary(left, "and", right);
        }
        return left;
    }

    fn parseNot(self: *Translator) TranslateError![]const u8 {
        if (self.check(.kw_not)) {
            _ = self.advance();
            const operand = try self.parseNot();
            return std.fmt.allocPrint(self.arena, "not {s}", .{operand});
        }
        return self.parseComparison();
    }

    fn comparisonOperator(kind: TokenKind) ?[]const u8 {
        return switch (kind) {
            .equals => "==",
            .not_equals => "!=",
            .less => "<",
            .less_equal => "<=",
            .greater => ">",
            .greater_equal => ">=",
            else => null,
        };
    }

    fn parseComparison(self: *Translator) TranslateError![]const u8 {
        const left = try self.parseAdditive();
        if (comparisonOperator(self.current().kind)) |pythonOperator| {
            _ = self.advance();
            const right = try self.parseAdditive();
            return self.joinBinary(left, pythonOperator, right);
        }
        return left;
    }

    fn joinBinary(self: *Translator, left: []const u8, operator: []const u8, right: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena, "{s} {s} {s}", .{ left, operator, right });
    }

    fn parseAdditive(self: *Translator) TranslateError![]const u8 {
        var left = try self.parseTerm();
        while (self.check(.plus) or self.check(.minus) or self.check(.ampersand)) {
            const operator = self.advance();
            const right = try self.parseTerm();
            // & joins strings, which is + in python
            const pythonOperator = if (operator.kind == .ampersand) "+" else operator.text;
            left = try self.joinBinary(left, pythonOperator, right);
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
            .integer, .real => {
                _ = self.advance();
                return token.text;
            },
            .identifier => {
                _ = self.advance();
                if (self.check(.l_bracket)) return self.parseIndexSuffix(token.text);
                return token.text;
            },
            .kw_true => {
                _ = self.advance();
                return "True";
            },
            .kw_false => {
                _ = self.advance();
                return "False";
            },
            .l_paren => {
                _ = self.advance();
                const inner = try self.parseExpression();
                _ = try self.expect(.r_paren, "')'");
                return std.fmt.allocPrint(self.arena, "({s})", .{inner});
            },
            else => return self.failUnexpected(token, "a value"),
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

test "input into a declared integer is converted" {
    try expectPython("DECLARE age : INTEGER\nINPUT age\n", "age = 0\nage = int(input())\n");
}

test "input into a declared real is converted" {
    try expectPython("DECLARE price : REAL\nINPUT price\n", "price = 0.0\nprice = float(input())\n");
}

test "input into a declared string stays text" {
    try expectPython("DECLARE name : STRING\nINPUT name\n", "name = \"\"\nname = input()\n");
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

test "equals and not equals become python comparisons" {
    try expectPython("a <- x = 3\nb <- x <> 3\n", "a = x == 3\nb = x != 3\n");
}

test "ordering comparisons" {
    try expectPython("a <- x < 1\nb <- x <= 2\nc <- x > 3\nd <- x >= 4\n", "a = x < 1\nb = x <= 2\nc = x > 3\nd = x >= 4\n");
}

test "boolean operators and literals" {
    try expectPython("ok <- NOT done AND (x > 1 OR TRUE)\n", "ok = not done and (x > 1 or True)\n");
    try expectPython("ok <- FALSE\n", "ok = False\n");
}

test "and binds tighter than or" {
    try expectPython("ok <- a OR b AND c\n", "ok = a or b and c\n");
}

test "boolean operator words in strings are untouched" {
    try expectPython("ok <- s = \"A AND B\"\n", "ok = s == \"A AND B\"\n");
}

test "if statement indents its body" {
    try expectPython(
        "IF x > 5 THEN\n  OUTPUT \"big\"\nENDIF\nOUTPUT \"done\"\n",
        "if x > 5:\n    print(\"big\")\nprint(\"done\")\n",
    );
}

test "else branch" {
    try expectPython(
        "IF x > 5 THEN\n  OUTPUT \"big\"\nELSE\n  OUTPUT \"small\"\nENDIF\n",
        "if x > 5:\n    print(\"big\")\nelse:\n    print(\"small\")\n",
    );
}

test "nested if inside if" {
    try expectPython(
        "IF a THEN\n  IF b THEN\n    OUTPUT 1\n  ELSE\n    OUTPUT 2\n  ENDIF\nELSE\n  OUTPUT 3\nENDIF\nOUTPUT 4\n",
        "if a:\n    if b:\n        print(1)\n    else:\n        print(2)\nelse:\n    print(3)\nprint(4)\n",
    );
}

test "if nested in an else branch gives an else-if chain" {
    try expectPython(
        "IF x = 1 THEN\n  OUTPUT \"one\"\nELSE\n  IF x = 2 THEN\n    OUTPUT \"two\"\n  ELSE\n    OUTPUT \"many\"\n  ENDIF\nENDIF\n",
        "if x == 1:\n    print(\"one\")\nelse:\n    if x == 2:\n        print(\"two\")\n    else:\n        print(\"many\")\n",
    );
}

test "empty blocks get a pass statement" {
    try expectPython(
        "IF x THEN\nELSE\n  OUTPUT 1\nENDIF\n",
        "if x:\n    pass\nelse:\n    print(1)\n",
    );
}

test "for loop includes its upper bound" {
    try expectPython(
        "FOR i <- 1 TO n\n  OUTPUT i\nNEXT i\n",
        "for i in range(1, n + 1):\n    print(i)\n",
    );
}

test "literal upper bound is folded into the range" {
    try expectPython("FOR i <- 1 TO 10\n  OUTPUT i\nNEXT i\n", "for i in range(1, 11):\n    print(i)\n");
}

test "computed upper bound keeps the expression" {
    try expectPython("FOR i <- 0 TO n - 1\n  OUTPUT i\nNEXT i\n", "for i in range(0, n - 1 + 1):\n    print(i)\n");
}

test "step with a positive number" {
    try expectPython("FOR i <- 0 TO 10 STEP 2\n  OUTPUT i\nNEXT i\n", "for i in range(0, 11, 2):\n    print(i)\n");
}

test "descending loop stops one below its lower bound" {
    try expectPython("FOR i <- 10 TO 1 STEP -1\n  OUTPUT i\nNEXT i\n", "for i in range(10, 0, -1):\n    print(i)\n");
}

test "descending loop down to zero" {
    try expectPython("FOR i <- 5 TO 0 STEP -1\n  OUTPUT i\nNEXT i\n", "for i in range(5, -1, -1):\n    print(i)\n");
}

test "descending loop with a variable bound and a bigger step" {
    try expectPython("FOR i <- n TO low STEP -2\n  OUTPUT i\nNEXT i\n", "for i in range(n, low - 1, -2):\n    print(i)\n");
}

test "while loop" {
    try expectPython("WHILE n > 0 DO\n  n <- n - 1\nENDWHILE\n", "while n > 0:\n    n = n - 1\n");
}

test "while without DO" {
    try expectPython("WHILE n > 0\n  n <- n - 1\nENDWHILE\n", "while n > 0:\n    n = n - 1\n");
}

test "while without ENDWHILE" {
    try expectError("WHILE TRUE DO\nOUTPUT 1\n", 3, "WHILE on line 1 is missing its ENDWHILE");
}

test "stray endwhile" {
    try expectError("ENDWHILE\n", 1, "ENDWHILE without a matching WHILE");
}

test "repeat until breaks when the condition is true" {
    try expectPython(
        "REPEAT\n  n <- n + 1\nUNTIL n = 3\n",
        "while True:\n    n = n + 1\n    if n == 3:\n        break\n",
    );
}

test "repeat without UNTIL" {
    try expectError("REPEAT\nOUTPUT 1\n", 3, "REPEAT on line 1 is missing its UNTIL");
}

test "stray until" {
    try expectError("UNTIL x\n", 1, "UNTIL without a matching REPEAT");
}

test "next with the wrong variable" {
    try expectError(
        "FOR i <- 1 TO 3\n  FOR j <- 1 TO 3\n    OUTPUT j\n  NEXT i\nNEXT j\n",
        4,
        "NEXT i does not match the loop variable j from line 2",
    );
}

test "nested loops of different kinds" {
    try expectPython(
        "FOR i <- 1 TO 2\n  WHILE x < i DO\n    x <- x + 1\n  ENDWHILE\nNEXT i\n",
        "for i in range(1, 3):\n    while x < i:\n        x = x + 1\n",
    );
}

test "ampersand joins strings" {
    try expectPython("full <- first & \" \" & last\n", "full = first + \" \" + last\n");
}

test "ampersand inside a string is not an operator" {
    try expectPython("OUTPUT \"fish & chips\"\n", "print(\"fish & chips\")\n");
}

test "step held in a variable works out its direction at run time" {
    try expectPython(
        "FOR i <- 1 TO 9 STEP s\n  OUTPUT i\nNEXT i\n",
        "for i in range(1, 9 + (1 if s > 0 else -1), s):\n    print(i)\n",
    );
}

test "negated variable is not assumed to be a descending step" {
    try expectPython(
        "FOR i <- 1 TO 9 STEP -s\n  OUTPUT i\nNEXT i\n",
        "for i in range(1, 9 + (1 if -s > 0 else -1), -s):\n    print(i)\n",
    );
}

test "declare gives a default value" {
    try expectPython(
        "DECLARE count : INTEGER\nDECLARE name : STRING\nDECLARE flag : BOOLEAN\nDECLARE ratio : REAL\n",
        "count = 0\nname = \"\"\nflag = False\nratio = 0.0\n",
    );
}

test "declare several variables at once" {
    try expectPython("DECLARE a, b : INTEGER\n", "a = 0\nb = 0\n");
}

test "declare with an unknown type" {
    try expectError("DECLARE d : DATE\n", 1, "unknown type 'DATE' (supported: INTEGER, REAL, STRING, CHAR, BOOLEAN)");
}

test "declare an array" {
    try expectPython("DECLARE marks : ARRAY[1:5] OF INTEGER\n", "marks = [0] * 6\n");
}

test "declare an array of strings with a variable size" {
    try expectPython("DECLARE names : ARRAY[1:n] OF STRING\n", "names = [\"\"] * (n + 1)\n");
}

test "array elements can be assigned and read" {
    try expectPython("marks[2] <- marks[1] + 1\n", "marks[2] = marks[1] + 1\n");
}

test "array index can be an expression" {
    try expectPython("x <- marks[i + 1] * 2\n", "x = marks[i + 1] * 2\n");
}

test "input into an array element uses the element type" {
    try expectPython(
        "DECLARE marks : ARRAY[1:3] OF INTEGER\nINPUT marks[2]\n",
        "marks = [0] * 4\nmarks[2] = int(input())\n",
    );
}

test "two dimensional arrays are rejected" {
    try expectError("DECLARE grid : ARRAY[1:3, 1:3] OF INTEGER\n", 1, "two dimensional arrays are not supported");
    try expectError("x <- grid[1, 2]\n", 1, "two dimensional arrays are not supported");
}

test "array index is missing its bracket" {
    try expectError("x <- marks[1\n", 1, "expected ']' after the index but found end of line");
}

test "case becomes an if elif else chain" {
    try expectPython(
        "CASE OF x\n  1 : OUTPUT \"one\"\n  2 : OUTPUT \"two\"\n  OTHERWISE : OUTPUT \"many\"\nENDCASE\n",
        "if x == 1:\n    print(\"one\")\nelif x == 2:\n    print(\"two\")\nelse:\n    print(\"many\")\n",
    );
}

test "case branch with several statements" {
    try expectPython(
        "CASE OF c\n  'a' :\n    OUTPUT 1\n    OUTPUT 2\n  'b' : OUTPUT 3\nENDCASE\n",
        "if c == 'a':\n    print(1)\n    print(2)\nelif c == 'b':\n    print(3)\n",
    );
}

test "case on an expression evaluates it once" {
    try expectPython(
        "CASE OF n MOD 3\n  0 : OUTPUT 0\nENDCASE\n",
        "_caseValue = n % 3\nif _caseValue == 0:\n    print(0)\n",
    );
}

test "case on a string" {
    try expectPython("CASE OF s\n  \"hi\" : OUTPUT 1\nENDCASE\n", "if s == \"hi\":\n    print(1)\n");
}

test "case without ENDCASE" {
    try expectError("CASE OF x\n  1 : OUTPUT 1\n", 3, "CASE on line 1 is missing its ENDCASE");
}

test "otherwise must come last" {
    try expectError("CASE OF x\n  OTHERWISE : OUTPUT 1\n  2 : OUTPUT 2\nENDCASE\n", 3, "OTHERWISE must be the last branch of the CASE");
}

test "case value must be a literal" {
    try expectError("CASE OF x\n  y : OUTPUT 1\nENDCASE\n", 2, "expected a case value or OTHERWISE but found 'y'");
}

test "stray endcase" {
    try expectError("ENDCASE\n", 1, "ENDCASE without a matching CASE");
}

test "next may leave out the variable" {
    try expectPython("FOR i <- 1 TO n\n  OUTPUT i\nNEXT\n", "for i in range(1, n + 1):\n    print(i)\n");
}

test "for without NEXT" {
    try expectError("FOR i <- 1 TO 3\nOUTPUT i\n", 3, "FOR on line 1 is missing its NEXT");
}

test "stray next" {
    try expectError("NEXT i\n", 1, "NEXT without a matching FOR");
}

test "if without THEN" {
    try expectError("IF x > 5\nENDIF\n", 1, "expected THEN after the condition but found end of line");
}

test "if without ENDIF names the line of the IF" {
    try expectError("IF x > 5 THEN\nOUTPUT x\n", 3, "IF on line 1 is missing its ENDIF");
}

test "else and endif on their own" {
    try expectError("x <- 1\nENDIF\n", 2, "ENDIF without a matching IF");
    try expectError("ELSE\n", 1, "ELSE without a matching IF");
}

test "unterminated string" {
    try expectError("OUTPUT \"oops\n", 1, "unterminated string literal");
}

test "unexpected character" {
    try expectError("x <- 3 @ 4\n", 1, "unexpected character '@'");
}

test "missing arrow is reported with its line" {
    try expectError("x <- 1\ny 2\n", 2, "expected '<-' or '\u{2190}' after the variable name but found '2'");
}
