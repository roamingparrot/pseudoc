const std = @import("std");

pub const TokenKind = enum {
    identifier,
    integer,
    real,
    string,
    newline,
    eof,
    invalid,

    // operators and punctuation
    arrow,
    plus,
    minus,
    star,
    slash,
    caret,
    ampersand,
    equals,
    not_equals,
    less,
    less_equal,
    greater,
    greater_equal,
    l_paren,
    r_paren,
    l_bracket,
    r_bracket,
    comma,
    colon,

    // keywords
    kw_declare,
    kw_constant,
    kw_input,
    kw_output,
    kw_if,
    kw_then,
    kw_else,
    kw_endif,
    kw_for,
    kw_to,
    kw_step,
    kw_next,
    kw_while,
    kw_do,
    kw_endwhile,
    kw_repeat,
    kw_until,
    kw_case,
    kw_of,
    kw_otherwise,
    kw_endcase,
    kw_procedure,
    kw_endprocedure,
    kw_function,
    kw_endfunction,
    kw_returns,
    kw_return,
    kw_call,
    kw_and,
    kw_or,
    kw_not,
    kw_div,
    kw_mod,
    kw_true,
    kw_false,
    kw_array,
    kw_byref,
    kw_byval,
};

// CIE keywords are written in capitals, so lookup is case sensitive
const keywords = std.StaticStringMap(TokenKind).initComptime(.{
    .{ "DECLARE", .kw_declare },
    .{ "CONSTANT", .kw_constant },
    .{ "INPUT", .kw_input },
    .{ "OUTPUT", .kw_output },
    .{ "IF", .kw_if },
    .{ "THEN", .kw_then },
    .{ "ELSE", .kw_else },
    .{ "ENDIF", .kw_endif },
    .{ "FOR", .kw_for },
    .{ "TO", .kw_to },
    .{ "STEP", .kw_step },
    .{ "NEXT", .kw_next },
    .{ "WHILE", .kw_while },
    .{ "DO", .kw_do },
    .{ "ENDWHILE", .kw_endwhile },
    .{ "REPEAT", .kw_repeat },
    .{ "UNTIL", .kw_until },
    .{ "CASE", .kw_case },
    .{ "OF", .kw_of },
    .{ "OTHERWISE", .kw_otherwise },
    .{ "ENDCASE", .kw_endcase },
    .{ "PROCEDURE", .kw_procedure },
    .{ "ENDPROCEDURE", .kw_endprocedure },
    .{ "FUNCTION", .kw_function },
    .{ "ENDFUNCTION", .kw_endfunction },
    .{ "RETURNS", .kw_returns },
    .{ "RETURN", .kw_return },
    .{ "CALL", .kw_call },
    .{ "AND", .kw_and },
    .{ "OR", .kw_or },
    .{ "NOT", .kw_not },
    .{ "DIV", .kw_div },
    .{ "MOD", .kw_mod },
    .{ "TRUE", .kw_true },
    .{ "FALSE", .kw_false },
    .{ "ARRAY", .kw_array },
    .{ "BYREF", .kw_byref },
    .{ "BYVAL", .kw_byval },
});

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
    line: usize,
    column: usize,
};

pub const Lexer = struct {
    source: []const u8,
    position: usize = 0,
    line: usize = 1,
    lineStart: usize = 0, // index where the current line begins, for columns

    pub fn init(source: []const u8) Lexer {
        return Lexer{ .source = source };
    }

    fn peek(self: *Lexer) u8 {
        if (self.position >= self.source.len) return 0;
        return self.source[self.position];
    }

    fn peekNext(self: *Lexer) u8 {
        if (self.position + 1 >= self.source.len) return 0;
        return self.source[self.position + 1];
    }

    fn skipSpacesAndComments(self: *Lexer) void {
        while (self.position < self.source.len) {
            const c = self.peek();
            if (c == ' ' or c == '\t' or c == '\r') {
                self.position += 1;
            } else if (c == '/' and self.peekNext() == '/') {
                while (self.position < self.source.len and self.peek() != '\n') {
                    self.position += 1;
                }
            } else {
                break;
            }
        }
    }

    fn isLetter(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn makeToken(self: *Lexer, kind: TokenKind, start: usize) Token {
        return Token{
            .kind = kind,
            .text = self.source[start..self.position],
            .line = self.line,
            .column = start - self.lineStart + 1,
        };
    }

    pub fn next(self: *Lexer) Token {
        self.skipSpacesAndComments();
        const start = self.position;

        if (self.position >= self.source.len) {
            return self.makeToken(.eof, start);
        }

        const c = self.peek();

        if (c == '\n') {
            self.position += 1;
            const token = self.makeToken(.newline, start);
            self.line += 1;
            self.lineStart = self.position;
            return token;
        }

        if (isLetter(c)) {
            while (isLetter(self.peek()) or isDigit(self.peek())) self.position += 1;
            const word = self.source[start..self.position];
            const kind = keywords.get(word) orelse TokenKind.identifier;
            return self.makeToken(kind, start);
        }

        if (isDigit(c)) return self.readNumber(start);

        if (c == '"' or c == '\'') return self.readString(start, c);

        // the unicode arrow is three bytes in utf-8
        if (std.mem.startsWith(u8, self.source[self.position..], "\u{2190}")) {
            self.position += 3;
            return self.makeToken(.arrow, start);
        }

        return self.readOperator(start);
    }

    fn readOperator(self: *Lexer, start: usize) Token {
        const c = self.peek();
        const following = self.peekNext();
        self.position += 1;

        const kind: TokenKind = switch (c) {
            '+' => .plus,
            '-' => .minus,
            '*' => .star,
            '/' => .slash,
            '^' => .caret,
            '&' => .ampersand,
            '=' => .equals,
            '(' => .l_paren,
            ')' => .r_paren,
            '[' => .l_bracket,
            ']' => .r_bracket,
            ',' => .comma,
            ':' => .colon,
            '<' => blk: {
                if (following == '-') {
                    self.position += 1;
                    break :blk .arrow;
                } else if (following == '>') {
                    self.position += 1;
                    break :blk .not_equals;
                } else if (following == '=') {
                    self.position += 1;
                    break :blk .less_equal;
                }
                break :blk .less;
            },
            '>' => blk: {
                if (following == '=') {
                    self.position += 1;
                    break :blk .greater_equal;
                }
                break :blk .greater;
            },
            else => .invalid,
        };
        return self.makeToken(kind, start);
    }

    // The token text includes both quotes. CIE strings have no escape
    // sequences, so the string simply ends at the next matching quote.
    fn readString(self: *Lexer, start: usize, quote: u8) Token {
        self.position += 1; // opening quote
        while (self.position < self.source.len and self.peek() != quote and self.peek() != '\n') {
            self.position += 1;
        }
        if (self.peek() != quote) return self.makeToken(.invalid, start); // unterminated
        self.position += 1; // closing quote
        return self.makeToken(.string, start);
    }

    fn readNumber(self: *Lexer, start: usize) Token {
        while (isDigit(self.peek())) self.position += 1;
        // only treat '.' as a decimal point if a digit follows it
        if (self.peek() == '.' and isDigit(self.peekNext())) {
            self.position += 1;
            while (isDigit(self.peek())) self.position += 1;
            return self.makeToken(.real, start);
        }
        return self.makeToken(.integer, start);
    }
};

pub fn tokenize(gpa: std.mem.Allocator, source: []const u8) ![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    var lexer = Lexer.init(source);
    while (true) {
        const token = lexer.next();
        try tokens.append(gpa, token);
        if (token.kind == .eof) break;
    }
    return tokens.toOwnedSlice(gpa);
}

fn expectKinds(source: []const u8, expected: []const TokenKind) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try tokenize(arena.allocator(), source);
    try std.testing.expectEqual(expected.len, tokens.len);
    for (expected, tokens) |expectedKind, token| {
        try std.testing.expectEqual(expectedKind, token.kind);
    }
}

test "lexer reads identifiers and numbers" {
    try expectKinds("count 42 3.14", &.{ .identifier, .integer, .real, .eof });
}

test "lexer skips spaces and comments but keeps newlines" {
    try expectKinds("x  // note\ny", &.{ .identifier, .newline, .identifier, .eof });
}

test "lexer tracks line and column" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try tokenize(arena.allocator(), "ab\n  cd");
    try std.testing.expectEqual(@as(usize, 2), tokens[2].line);
    try std.testing.expectEqual(@as(usize, 3), tokens[2].column);
}

test "a dot without digits after it is not part of the number" {
    try expectKinds("7.", &.{ .integer, .invalid, .eof });
}

test "keywords are recognised in capitals only" {
    try expectKinds("IF THEN ELSE ENDIF", &.{ .kw_if, .kw_then, .kw_else, .kw_endif, .eof });
    try expectKinds("if Then", &.{ .identifier, .identifier, .eof });
}

test "keyword prefixes are still identifiers" {
    try expectKinds("IFFY ENDIFX", &.{ .identifier, .identifier, .eof });
}

test "string contents are not split into operators" {
    try expectKinds("\"a <> b AND c\"", &.{ .string, .eof });
}

test "single quoted characters are strings too" {
    try expectKinds("'x'", &.{ .string, .eof });
}

test "unterminated string is invalid" {
    try expectKinds("\"oops\nx", &.{ .invalid, .newline, .identifier, .eof });
}

test "assignment arrows" {
    try expectKinds("x \u{2190} 1", &.{ .identifier, .arrow, .integer, .eof });
    try expectKinds("x <- 1", &.{ .identifier, .arrow, .integer, .eof });
}

test "comparison operators" {
    try expectKinds("< <= > >= = <>", &.{ .less, .less_equal, .greater, .greater_equal, .equals, .not_equals, .eof });
}

test "arithmetic and brackets" {
    try expectKinds("a[1] + (2 * 3) ^ 2 / 4 - 5 & b", &.{
        .identifier, .l_bracket, .integer, .r_bracket, .plus,  .l_paren, .integer,   .star,       .integer, .r_paren,
        .caret,      .integer,   .slash,   .integer,   .minus, .integer, .ampersand, .identifier, .eof,
    });
}
