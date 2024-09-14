const std = @import("std");
const Lexer = @import("lexer.zig");
const stmt = @import("statement.zig");
const expr = @import("expression.zig");
const RingBuffer = @import("tokenRingBuffer.zig");

pub const Error = Lexer.Error || error{
    UnexpectedToken,
    RepeatedParsingFailure,
    RepeatedParsingNoElements,
    NumberParsingFailure,
};

tokens: RingBuffer = .{},
lexer: Lexer,
allocator: std.mem.Allocator,
last_expected: ?Kind = null,
last_expected_chars: ?[]const u8 = null,

var parser_diagnostic: bool = false;

const Kind = Lexer.TokenKind;
const Token = Lexer.Token;
const Self = @This();

pub fn init(input: []const u8, allocator: std.mem.Allocator) Self {
    Self.parser_diagnostic = std.process.hasEnvVar(allocator, "DIAG") catch false;
    return Self{
        .lexer = Lexer.init(input),
        .allocator = allocator,
    };
}

fn reset(self: *Self, position: ?usize) void {
    if (position) |p| {
        self.lexer.current_position = p;
        self.tokens.read_index = 0;
        self.tokens.write_index = 0;
    } else {
        self.lexer.current_position = 0;
        self.tokens.read_index = 0;
        self.tokens.write_index = 0;
    }
}

pub fn printLexerContext(self: Self, out: std.io.AnyWriter) !void {
    const t = Token{
        .kind = .Unknown,
        .index = self.lexer.current_position,
        .line = self.lexer.countNewlines(),
        .column = self.lexer.currentColumn(),
        .chars = "",
    };
    const l = self.lexer;
    try out.print(
        "    current lexing position: {}:{} '{s}'\n",
        .{ t.line, t.column, l.data[l.current_position .. l.current_position + 1] },
    );
    try self.lexer.printContext(out, t);
}

fn todo(comptime T: type, msg: []const u8) Error!T {
    std.debug.print("TODO: {s}\n", .{msg});
    return Error.NotImplemented;
}

fn putNextToken(self: *Self) Error!void {
    const t = self.lexer.nextToken() catch |err| {
        handleAndExit(self, err);
        return Error.EndOfFile;
    };

    if (Self.parser_diagnostic) {
        std.debug.print("-----------------------------\n", .{});
        std.debug.print(
            "INFO: ring buffer pos: r {}, w {}\n",
            .{ self.tokens.read_index, self.tokens.write_index },
        );
        std.debug.print(" kind: {}\n", .{t.kind});
        std.debug.print(" writing element...\n", .{});
    }
    self.tokens.write(t) catch return Error.UnknownError;

    if (Self.parser_diagnostic) {
        std.debug.print(
            "INFO: ring buffer pos: r {}, w {}\n",
            .{ self.tokens.read_index, self.tokens.write_index },
        );
    }
}

fn expect(self: *Self, kind: Kind, expected_chars: ?[]const u8) Error!Token {
    if (self.tokens.isEmpty()) {
        try self.putNextToken();
    }

    if (self.tokens.peek()) |token| {
        if (parser_diagnostic) {
            std.debug.print("-----------------------------\n", .{});
            std.debug.print("DEBUG: current ring buffer read: {}\n", .{self.tokens.read_index});
            std.debug.print("DEBUG: kinds are (act, exp): \n    {}\n    {}\n", .{ token.kind, kind });
            std.debug.print("DEBUG: current chars are: {s}\n", .{token.chars});

            const stdout = std.io.getStdErr().writer();
            self.lexer.printContext(stdout.any(), token) catch return Error.UnknownError;
        }

        if (expected_chars) |chars| {
            if (parser_diagnostic) {
                std.debug.print("DEBUG: expected chars: {s}\n", .{chars});
            }

            if (token.kind == kind and std.mem.eql(u8, chars, token.chars)) {
                _ = self.tokens.read() orelse unreachable;
                return token;
            } else {
                self.last_expected = kind;
                self.last_expected_chars = chars;
                return Error.UnexpectedToken;
            }
        } else {
            if (token.kind == kind) {
                _ = self.tokens.read() orelse unreachable;
                return token;
            } else {
                self.last_expected = kind;
                self.last_expected_chars = null;
                return Error.UnexpectedToken;
            }
        }
    } else return Error.EndOfFile;
}

fn handleAndExit(self: *Self, err: Error) void {
    if (err == Lexer.Error.EndOfFile) {
        return;
    } else {
        const stderr = std.io.getStdErr().writer();
        stderr.print("ERROR: failed to read next token: {}\n", .{err}) catch @panic("error during write to stderr");
        self.printLexerContext(stderr.any()) catch @panic("error during write to stderr");
        std.process.exit(1);
    }
}

fn currentToken(self: *Self) ?Token {
    if (self.tokens.isEmpty())
        self.putNextToken() catch return null;

    return self.tokens.peek();
}

fn nextToken(self: *Self) ?Token {
    while (self.tokens.len() < 2) {
        self.putNextToken() catch |err| {
            self.handleAndExit(err);
            return null;
        };
    }
    return self.tokens.peekNext();
}

fn nextNextToken(self: *Self) ?Token {
    while (self.tokens.len() < 3) {
        self.putNextToken() catch |err| {
            self.handleAndExit(err);
            return null;
        };
    }
    return self.tokens.peekNextNext();
}

fn unexpectedToken(lexer: Lexer, actual: Token, expected: []const Kind, expected_chars: ?[]const u8) Error!void {
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const out = bw.writer();

    if (expected_chars) |chars| {
        out.print("ERROR: expected token of {any} with value '{s}'\n", .{ expected, chars }) catch return Error.UnknownError;
        out.print("       but got {} with '{s}' at {}:{}\n", .{
            actual.kind,
            actual.chars,
            actual.line,
            actual.column,
        }) catch return Error.UnknownError;
    } else {
        out.print("ERROR: expected token of the kinds {any}\n", .{expected}) catch return Error.UnknownError;
        out.print("       but got {} '{s}' at {}:{}\n", .{
            actual.kind,
            actual.chars,
            actual.line,
            actual.column,
        }) catch return Error.UnknownError;
    }
    try lexer.printContext(out.any(), actual);
    bw.flush() catch return Error.UnknownError;

    return Error.UnexpectedToken;
}

fn presedenceOf(op: expr.Operator) usize {
    return switch (op) {
        .arithmetic => |a| switch (a) {
            .Add => 5,
            .Sub => 5,
            .Mul => 6,
            .Mod => 6,
            .Div => 6,
            .Expo => 7,
        },
        .compare => 4,
        .boolean => |b| switch (b) {
            .Or => 1,
            .And => 2,
            .Not => 3,
        },
        // else => 0,
    };
}

// Expression parsing
fn parseExpression(self: *Self, presedence: usize) Error!*expr.Expression {
    var value = try self.parseValue();
    while (self.expect(.Operator, null)) |op_token| {
        const op = expr.mapOp(op_token.chars);
        const op_pres = presedenceOf(op);
        // TODO: .Expo is right assosiative. the current implementation does not reflect that.
        if (op_pres > presedence) {
            const ex = try self.parseExpression(op_pres);
            value = try expr.BinaryOp.init(self.allocator, op, value, ex);
        } else {
            self.reset(op_token.index);
            return value;
        }
    } else |err| {
        if (err != Error.UnexpectedToken and err != Error.EndOfFile)
            return err;
        return value;
    }
}

fn parseBoolean(self: *Self) Error!*expr.Expression {
    const b = self.expect(.Boolean, null) catch unreachable;
    if (std.mem.eql(u8, b.chars, "true")) {
        return expr.Boolean.init(self.allocator, true);
    } else if (std.mem.eql(u8, b.chars, "false")) {
        return expr.Boolean.init(self.allocator, false);
    }
    unreachable;
}

fn parseValue(self: *Self) Error!*expr.Expression {
    if (self.currentToken()) |token| {
        switch (token.kind) {
            .Number => return self.parseNumber(),
            .Identifier => {
                if (self.nextToken()) |t| {
                    if (t.kind == .OpenParen and t.chars[0] == '(') {
                        return self.parseFunctionCallExpr();
                    } else if (t.kind == .OpenParen and t.chars[0] == '[') {
                        return self.parseStructAccess();
                    }
                    return self.parseIdentifier();
                }
                return self.parseIdentifier();
            },
            .Boolean => return self.parseBoolean(),
            .String => return self.parseString(),
            .OpenParen => {
                if (std.mem.eql(u8, token.chars, "(")) {
                    return self.parseFunction() catch {
                        self.reset(token.index);
                        return self.parseFunctionCallExpr();
                    };
                } else if (std.mem.eql(u8, token.chars, "[")) {
                    return self.parseArrayLiteral();
                } else if (std.mem.eql(u8, token.chars, "{")) {
                    return self.parseDictionaryLiteral();
                } else unreachable;
            },
            .Operator => return self.parseUnaryOp(),
            else => {
                self.last_expected = .Unknown;
                self.last_expected_chars = "'number', 'boolean', 'string' or 'open paren'";
                return Error.UnexpectedToken;
            },
        }
    } else return Error.EndOfFile;
}

fn parseArrayLiteral(self: *Self) Error!*expr.Expression {
    _ = try self.expect(.OpenParen, "[");
    const elems: []expr.Expression = self.parseRepeated(expr.Expression, Self.parseExpr) catch |err| b: {
        if (err != Error.RepeatedParsingNoElements)
            return err;
        break :b &[_]expr.Expression{};
    };
    _ = try self.expect(.CloseParen, "]");
    return expr.Array.init(self.allocator, elems);
}

fn parseEntry(self: *Self) Error!expr.DictionaryEntry {
    const key = try self.parseExpression(0);
    _ = try self.expect(.KeyValueSep, null);
    const value = try self.parseExpression(0);
    return .{
        .key = key,
        .value = value,
    };
}

fn parseDictionaryLiteral(self: *Self) Error!*expr.Expression {
    _ = try self.expect(.OpenParen, "{");
    while (self.expect(.Newline, null)) |_| {} else |err| {
        if (err != Error.UnexpectedToken) return err;
    }
    const elems: []expr.DictionaryEntry = self.parseRepeated(expr.DictionaryEntry, Self.parseEntry) catch |err| b: {
        if (err != Error.RepeatedParsingNoElements)
            return err;
        break :b &[_]expr.DictionaryEntry{};
    };
    while (self.expect(.Newline, null)) |_| {} else |err| {
        if (err != Error.UnexpectedToken) return err;
    }
    _ = try self.expect(.CloseParen, "}");
    return expr.Dictionary.init(self.allocator, elems);
}

fn parseIdentifier(self: *Self) Error!*expr.Expression {
    const id = try self.expect(.Identifier, null);
    return expr.Identifier.init(self.allocator, id.chars);
}

fn parseUnaryOp(self: *Self) Error!*expr.Expression {
    const op_token = self.expect(.Operator, null) catch unreachable;
    const op = expr.mapOp(op_token.chars);
    if ((op == .arithmetic and op.arithmetic != .Sub) or (op == .boolean and op.boolean != .Not)) {
        self.last_expected = .Operator;
        self.last_expected_chars = "'-' or 'not'";
        return Error.UnexpectedToken;
    }

    if (self.nextNextToken()) |t| {
        if (t.kind == .Operator and std.mem.eql(u8, "^", t.chars)) {
            const v = try self.parseExpression(0);
            return expr.UnaryOp.init(self.allocator, op, v);
        } else {
            const v = try self.parseValue();
            return expr.UnaryOp.init(self.allocator, op, v);
        }
    } else {
        const v = try self.parseValue();
        return expr.UnaryOp.init(self.allocator, op, v);
    }
}

fn parseWrappedExpression(self: *Self) Error!*expr.Expression {
    _ = try self.expect(.OpenParen, "(");
    const ex = try self.parseExpression(0);
    _ = try self.expect(.CloseParen, ")");
    const out = try self.allocator.create(expr.Expression);
    out.* = .{ .wrapped = ex };
    return out;
}

fn parseString(self: *Self) Error!*expr.Expression {
    const str = self.expect(.String, null) catch unreachable;
    return expr.String.init(self.allocator, str.chars);
}

fn parseFunctionCallExpr(self: *Self) Error!*expr.Expression {
    const func_name = self.parseIdentifier() catch try self.parseWrappedExpression();
    _ = self.expect(.OpenParen, "(") catch |err| {
        if (err != Error.UnexpectedToken)
            return err;
        return func_name;
    };

    const args = self.parseRepeated(expr.Expression, Self.parseExpr) catch |err| {
        if (err != Error.RepeatedParsingNoElements)
            return err;

        _ = try self.expect(.CloseParen, ")");
        return expr.FunctionCall.init(self.allocator, func_name, &[_]expr.Expression{});
    };

    _ = try self.expect(.CloseParen, ")");

    return expr.FunctionCall.init(self.allocator, func_name, args);
}

fn parseIdent(self: *Self) Error!expr.Identifier {
    const id = try self.expect(.Identifier, null);
    return expr.identifier(id.chars);
}

fn parseFunction(self: *Self) Error!*expr.Expression {
    _ = try self.expect(.OpenParen, "(");
    const args = self.parseRepeated(expr.Identifier, Self.parseIdent) catch |err| b: {
        if (err == Error.RepeatedParsingNoElements) {
            break :b &[_]expr.Identifier{};
        }
        return err;
    };
    _ = try self.expect(.CloseParen, ")");
    _ = try self.expect(.LambdaArrow, null);
    const pos = self.lexer.current_position;

    if (self.parseCodeblock()) |body| {
        return expr.Function.init(self.allocator, args, body);
    } else |err| {
        if (err != Error.UnexpectedToken) {
            self.allocator.free(args);
            return err;
        }
        self.reset(pos);
        const ex = try self.parseExpression(0);
        const ret: stmt.Return = .{ .value = ex };
        var statemants = try self.allocator.alloc(stmt.Statement, 1);
        statemants[0] = .{ .ret = ret };
        return expr.Function.init(self.allocator, args, statemants);
    }
}

fn parseStructAccess(self: *Self) Error!*expr.Expression {
    const id = self.parseIdentifier() catch unreachable;
    _ = self.expect(.OpenParen, "[") catch unreachable;
    const ex = try self.parseExpression(0);
    _ = try self.expect(.CloseParen, "]");
    var out = try expr.StructureAccess.init(self.allocator, id, ex);
    while (self.expect(.OpenParen, "[")) |_| {
        const tmp = try self.parseExpression(0);
        _ = try self.expect(.CloseParen, "]");
        out = try expr.StructureAccess.init(self.allocator, out, tmp);
    } else |err| {
        if (err != Error.UnexpectedToken) {
            return err;
        }
    }
    return out;
}

fn baseOf(digits: []const u8) u8 {
    if (digits.len < 3)
        return 10;

    return switch (digits[1]) {
        'x' => 16,
        'o' => 8,
        'b' => 2,
        else => 10,
    };
}

fn parseNumber(self: *Self) Error!*expr.Expression {
    const digits = self.expect(.Number, null) catch unreachable;
    const base = baseOf(digits.chars);

    if (std.mem.count(u8, digits.chars, ".") > 0) {
        var parts = std.mem.split(u8, digits.chars, ".");
        const tmp = parts.next() orelse unreachable;
        const int_part = if (base == 10) tmp else tmp[2..];
        const fraction_part = parts.next() orelse unreachable;

        const int = std.fmt.parseInt(i64, int_part, base) catch return Error.NumberParsingFailure;
        const fraction = std.fmt.parseInt(i64, fraction_part, base) catch return Error.NumberParsingFailure;
        const frac: f64 = @as(f64, @floatFromInt(fraction)) / std.math.pow(f64, @floatFromInt(base), @floatFromInt(fraction_part.len));
        const composite = @as(f64, @floatFromInt(int)) + frac;
        return expr.Number.init(self.allocator, f64, composite);
    } else {
        const int_part = if (base == 10) digits.chars else digits.chars[2..];
        const num = std.fmt.parseInt(i64, int_part, base) catch return Error.NumberParsingFailure;
        return expr.Number.init(self.allocator, i64, num);
    }
}

// Statement parsing
fn parseCondition(self: *Self) Error!*expr.Expression {
    _ = try self.expect(.OpenParen, "(");
    const condition = try self.parseExpression(0);
    _ = try self.expect(.CloseParen, ")");
    return condition;
}

fn parseCodeblock(self: *Self) Error![]stmt.Statement {
    _ = try self.expect(.OpenParen, "{");
    _ = try self.expect(.Newline, null);
    if (Self.parser_diagnostic) {
        std.debug.print("DEBUG: read initial newline in code block\n", .{});
    }
    const code = try self.parseStatements(true);
    _ = try self.expect(.CloseParen, "}");
    return code;
}

fn parseBranch(self: *Self) Error!stmt.Branch {
    const condition = try self.parseCondition();
    const code = try self.parseCodeblock();

    return .{
        .condition = condition,
        .body = code,
    };
}

fn parseIfStatement(self: *Self, is_initial_branch: bool) Error!stmt.Statement {
    if (is_initial_branch) {
        _ = self.expect(.Keyword, "if") catch unreachable;
    }

    const branch = try self.parseBranch();

    _ = self.expect(.Newline, null) catch {};
    if (self.expect(.Keyword, "elif")) |_| {
        const tmp = try self.parseIfStatement(false);
        const stmts = try self.allocator.alloc(stmt.Statement, 1);
        stmts[0] = tmp;
        return .{ .if_statement = .{
            .ifBranch = branch,
            .elseBranch = stmts,
        } };
    } else |e| {
        if (e != Error.UnexpectedToken and e != Error.EndOfFile) return e;

        _ = self.expect(.Keyword, "else") catch |err| {
            if (err != Error.UnexpectedToken and err != Error.EndOfFile)
                return err;

            return .{ .if_statement = .{
                .ifBranch = branch,
                .elseBranch = null,
            } };
        };

        const elseCode = try self.parseCodeblock();

        return .{ .if_statement = .{
            .ifBranch = branch,
            .elseBranch = elseCode,
        } };
    }
}

fn parseWhileloop(self: *Self) Error!stmt.Statement {
    _ = self.expect(.Keyword, "while") catch unreachable;
    const condition = try self.parseCondition();
    const code = try self.parseCodeblock();
    return stmt.whileloop(condition, code);
}

fn parseReturn(self: *Self) Error!stmt.Statement {
    _ = try self.expect(.Keyword, "return");
    const ex = try self.parseExpression(0);
    return .{ .ret = .{ .value = ex } };
}

fn parseRepeated(self: *Self, comptime T: type, f: fn (*Self) Error!T) Error![]T {
    var elements = std.ArrayList(T).init(self.allocator);
    var ex = f(self) catch return Error.RepeatedParsingNoElements;
    try elements.append(ex);
    while (self.expect(.ArgSep, null)) |_| {
        while (self.expect(.Newline, null)) |_| {} else |err| {
            if (err != Error.UnexpectedToken) return err;
        }
        ex = try f(self);
        try elements.append(ex);
    } else |err| {
        if (err == Error.UnexpectedToken or err == Error.EndOfFile)
            return elements.toOwnedSlice();

        std.debug.print("ERROR: failure during repeated parsing: {}\n", .{err});
        return err;
    }
    return elements.toOwnedSlice();
}

fn parseExpr(self: *Self) Error!expr.Expression {
    const ex = try self.parseExpression(0);
    const out = ex.*;
    defer self.allocator.destroy(ex);
    return out;
}

fn parseFunctionCall(self: *Self) Error!stmt.Statement {
    const func_name = try self.parseIdentifier();
    _ = try self.expect(.OpenParen, "(");

    const args = self.parseRepeated(expr.Expression, Self.parseExpr) catch |err| {
        if (err == Error.RepeatedParsingNoElements) {
            _ = try self.expect(.CloseParen, ")");
            return .{ .functioncall = .{
                .func = func_name,
                .args = &[_]expr.Expression{},
            } };
        }
        return err;
    };

    _ = try self.expect(.CloseParen, ")");

    return .{ .functioncall = .{
        .func = func_name,
        .args = args,
    } };
}

fn parseAssignment(self: *Self) Error!stmt.Statement {
    const id = self.expect(.Identifier, null) catch unreachable;
    _ = try self.expect(.Operator, "=");
    const expression = try self.parseExpression(0);
    return stmt.assignment(id.chars, expression);
}

fn parseStructAssignment(self: *Self) Error!stmt.Statement {
    const strct = try self.parseStructAccess();
    _ = try self.expect(.Operator, "=");
    const ex = try self.parseExpression(0);

    return .{ .struct_assignment = .{
        .access = strct,
        .value = ex,
    } };
}

fn parseStatement(self: *Self) Error!stmt.Statement {
    self.last_expected = null;
    self.last_expected_chars = null;
    if (self.currentToken()) |token| {
        if (Self.parser_diagnostic) {
            std.debug.print("DEBUG: current token kind at statement parse: {}\n", .{token.kind});
        }

        const st = try switch (token.kind) {
            .Keyword => if (token.chars[0] == 'r')
                self.parseReturn()
            else if (token.chars[0] == 'i')
                self.parseIfStatement(true)
            else
                self.parseWhileloop(),
            .Identifier => if (self.nextToken()) |t| (if (t.kind == .OpenParen and t.chars[0] == '(')
                self.parseFunctionCall()
            else if (t.kind == .OpenParen and t.chars[0] == '[')
                self.parseStructAssignment()
            else
                self.parseAssignment()) else Error.UnexpectedToken,
            .OpenParen => todo(stmt.Statement, "parse statement => case open paren"),
            .Newline => {
                _ = self.expect(.Newline, null) catch unreachable;
                if (Self.parser_diagnostic) {
                    std.debug.print("DEBUG: read newline as statement\n", .{});
                }
                return self.parseStatement();
            },
            else => Error.UnexpectedToken,
        };
        _ = self.expect(.Newline, null) catch |err| {
            if (err != Error.EndOfFile)
                return err;

            if (Self.parser_diagnostic) {
                std.debug.print("DEBUG: failed to read newline: end of file\n", .{});
            }

            return st;
        };
        if (Self.parser_diagnostic) {
            std.debug.print("DEBUG: read newline after statement\n", .{});
        }
        return st;
    } else return Error.EndOfFile;

    unreachable;
}

fn parseStatements(self: *Self, should_ignore_paran: bool) Error![]stmt.Statement {
    var stmts = std.ArrayList(stmt.Statement).init(self.allocator);
    while (self.parseStatement()) |statement| {
        try stmts.append(statement);
    } else |err| {
        if (Self.parser_diagnostic) {
            std.debug.print("INFO: error: {}\n", .{err});
        }

        if (err != Error.EndOfFile and err != Error.UnexpectedToken)
            return err;

        if (err == Error.UnexpectedToken and !should_ignore_paran) {
            const token = self.currentToken() orelse unreachable;
            if (std.mem.eql(u8, token.chars, "}") and should_ignore_paran)
                return stmts.toOwnedSlice();

            if (self.last_expected) |kind| {
                try unexpectedToken(
                    self.lexer,
                    token,
                    &[_]Lexer.TokenKind{kind},
                    self.last_expected_chars,
                );
            } else {
                try unexpectedToken(
                    self.lexer,
                    token,
                    &[_]Lexer.TokenKind{ .Identifier, .Keyword },
                    null,
                );
            }
        }
    }
    return stmts.toOwnedSlice();
}

/// Returns an owned slice of Statements which must be
/// freed with `fn free(std.mem.Allocator, Statement)` in statements.zig
pub fn parse(self: *Self) Error![]stmt.Statement {
    return self.parseStatements(false);
}

test "simple assignment" {
    const input =
        \\aoeu = aoeu
        \\
    ;
    var ident = .{ .identifier = .{ .name = "aoeu" } };
    const expected: stmt.Statement = .{ .assignment = .{
        .varName = .{ .name = "aoeu" },
        .value = &ident,
    } };

    var parser = Self.init(input, std.testing.allocator);
    const result = parser.parse() catch unreachable;
    defer std.testing.allocator.free(result);
    defer for (result) |st| {
        stmt.free(std.testing.allocator, st);
    };

    try std.testing.expectEqual(1, result.len);
    const result_stmt = result[0];
    try std.testing.expect(result_stmt == .assignment);
    try std.testing.expectEqualStrings(expected.assignment.varName.name, result_stmt.assignment.varName.name);
    try std.testing.expect(result_stmt.assignment.value.* == .identifier);
    try std.testing.expectEqualStrings(expected.assignment.value.identifier.name, result_stmt.assignment.value.identifier.name);
}

test "function" {
    const input =
        \\aoeu = ( x ) => {
        \\    return x
        \\}
        \\
    ;
    var ident = .{ .identifier = .{ .name = "x" } };
    const ret_value = .{ .value = &ident };
    var fun = .{ .function = .{
        .args = &[_]expr.Identifier{.{ .name = "x" }},
        .body = &[_]stmt.Statement{
            .{ .ret = ret_value },
        },
    } };
    const expected: stmt.Statement = .{ .assignment = .{
        .varName = .{ .name = "aoeu" },
        .value = &fun,
    } };

    var parser = Self.init(input, std.testing.allocator);
    const result = parser.parse() catch unreachable;
    defer std.testing.allocator.free(result);
    defer for (result) |st| {
        stmt.free(std.testing.allocator, st);
    };

    try std.testing.expectEqual(1, result.len);
    const result_stmt = result[0];
    try std.testing.expect(result_stmt == .assignment);
    try std.testing.expectEqualStrings(expected.assignment.varName.name, result_stmt.assignment.varName.name);
    try std.testing.expect(result_stmt.assignment.value.* == .function);
    const function = result_stmt.assignment.value.function;
    try std.testing.expectEqual(expected.assignment.value.function.args.len, function.args.len);
    try std.testing.expectEqual(expected.assignment.value.function.body.len, function.body.len);
}

test "function - no args" {
    const input =
        \\aoeu = () => {
        \\    return x
        \\}
        \\
    ;
    var ident = .{ .identifier = .{ .name = "x" } };
    const ret_value = .{ .value = &ident };
    var fun = .{ .function = .{
        .args = &[_]expr.Identifier{},
        .body = &[_]stmt.Statement{
            .{ .ret = ret_value },
        },
    } };
    const expected: stmt.Statement = .{ .assignment = .{
        .varName = .{ .name = "aoeu" },
        .value = &fun,
    } };

    var parser = Self.init(input, std.testing.allocator);
    const result = parser.parse() catch unreachable;
    defer std.testing.allocator.free(result);
    defer for (result) |st| {
        stmt.free(std.testing.allocator, st);
    };

    try std.testing.expectEqual(1, result.len);
    const result_stmt = result[0];
    try std.testing.expect(result_stmt == .assignment);
    try std.testing.expect(result_stmt.assignment.value.* == .function);
    const function = result_stmt.assignment.value.function;
    try std.testing.expectEqual(expected.assignment.value.function.args.len, function.args.len);
    try std.testing.expectEqual(expected.assignment.value.function.body.len, function.body.len);
}

test "simple assignment - no newline" {
    const input = "aoeu = aoeu";
    var ident = .{ .identifier = .{ .name = "aoeu" } };
    const expected: stmt.Statement = .{ .assignment = .{
        .varName = .{ .name = "aoeu" },
        .value = &ident,
    } };

    var parser = Self.init(input, std.testing.allocator);
    const result = parser.parse() catch unreachable;
    defer std.testing.allocator.free(result);
    defer for (result) |st| {
        stmt.free(std.testing.allocator, st);
    };

    try std.testing.expectEqual(1, result.len);
    const result_stmt = result[0];
    try std.testing.expect(result_stmt == .assignment);
    try std.testing.expectEqualStrings(expected.assignment.varName.name, result_stmt.assignment.varName.name);
    try std.testing.expect(result_stmt.assignment.value.* == .identifier);
    try std.testing.expectEqualStrings(expected.assignment.value.identifier.name, result_stmt.assignment.value.identifier.name);
}

test "function call No args" {
    const input = "aoeu = aoeu()\n";
    var funCall: expr.Expression = .{ .functioncall = .{
        .func = &.{ .identifier = .{ .name = "aoeu" } },
        .args = &[_]expr.Expression{},
    } };
    const expected: stmt.Statement = .{ .assignment = .{
        .varName = .{ .name = "aoeu" },
        .value = &funCall,
    } };

    var parser = Self.init(input, std.testing.allocator);
    const result = parser.parse() catch unreachable;
    defer std.testing.allocator.free(result);
    defer for (result) |st| {
        stmt.free(std.testing.allocator, st);
    };

    try std.testing.expectEqual(1, result.len);
    const result_stmt = result[0];
    try std.testing.expect(result_stmt == .assignment);
    try std.testing.expectEqualStrings(expected.assignment.varName.name, result_stmt.assignment.varName.name);
    try std.testing.expect(result_stmt.assignment.value.* == .functioncall);
    const result_fc = result_stmt.assignment.value.functioncall;
    try std.testing.expectEqualStrings(funCall.functioncall.func.identifier.name, result_fc.func.identifier.name);
    try std.testing.expectEqualSlices(expr.Expression, funCall.functioncall.args, result_fc.args);
}

test "function call" {
    const input = "aoeu = aoeu(1, 2)";
    var args = [2]expr.Expression{
        .{ .number = .{ .integer = 1 } },
        .{ .number = .{ .integer = 2 } },
    };
    var funCall: expr.Expression = .{ .functioncall = .{
        .func = &.{ .identifier = .{ .name = "aoeu" } },
        .args = &args,
    } };
    const expected: stmt.Statement = .{ .assignment = .{
        .varName = .{ .name = "aoeu" },
        .value = &funCall,
    } };

    var parser = Self.init(input, std.testing.allocator);
    const result = parser.parse() catch unreachable;
    defer std.testing.allocator.free(result);
    defer for (result) |st| {
        stmt.free(std.testing.allocator, st);
    };

    try std.testing.expectEqual(1, result.len);
    const result_stmt = result[0];
    try std.testing.expect(result_stmt == .assignment);
    try std.testing.expectEqualStrings(expected.assignment.varName.name, result_stmt.assignment.varName.name);
    try std.testing.expect(result_stmt.assignment.value.* == .functioncall);
    const result_fc = result_stmt.assignment.value.functioncall;
    try std.testing.expectEqualStrings(funCall.functioncall.func.identifier.name, result_fc.func.identifier.name);
    try std.testing.expectEqualSlices(expr.Expression, funCall.functioncall.args, result_fc.args);
}

test "dictionary" {
    const input = "aoeu = { 1 : 1 }";
    var exp: expr.Expression = .{ .number = .{ .integer = 1 } };
    var entries: [1]expr.DictionaryEntry = undefined;
    entries[0] = .{ .key = &exp, .value = &exp };
    var dict: expr.Expression = .{ .dictionary = .{ .entries = &entries } };
    const expected_: stmt.Statement = .{ .assignment = .{
        .varName = .{ .name = "aoeu" },
        .value = &dict,
    } };

    var parser = Self.init(input, std.testing.allocator);
    const result = parser.parse() catch unreachable;
    defer std.testing.allocator.free(result);
    defer for (result) |st| {
        stmt.free(std.testing.allocator, st);
    };

    try std.testing.expectEqual(1, result.len);
    const result_stmt = result[0];
    try std.testing.expect(result_stmt == .assignment);
    try std.testing.expectEqualStrings(expected_.assignment.varName.name, result_stmt.assignment.varName.name);
    try std.testing.expect(result_stmt.assignment.value.* == .dictionary);
    const result_arr = result_stmt.assignment.value.dictionary;
    try std.testing.expectEqual(dict.dictionary.entries.len, result_arr.entries.len);
    for (dict.dictionary.entries, result_arr.entries) |expected, actual| {
        try std.testing.expectEqual(expected.key.*, actual.key.*);
        try std.testing.expectEqual(expected.value.*, actual.value.*);
    }
}

test "dictionary 3 entries" {
    const input = "aoeu = { 1 : 1, 2:2   , 3   :   3 }";
    var exp1: expr.Expression = .{ .number = .{ .integer = 1 } };
    var exp2: expr.Expression = .{ .number = .{ .integer = 2 } };
    var exp3: expr.Expression = .{ .number = .{ .integer = 3 } };
    var entries: [3]expr.DictionaryEntry = undefined;
    entries[0] = .{ .key = &exp1, .value = &exp1 };
    entries[1] = .{ .key = &exp2, .value = &exp2 };
    entries[2] = .{ .key = &exp3, .value = &exp3 };
    var dict: expr.Expression = .{ .dictionary = .{ .entries = &entries } };
    const expected_: stmt.Statement = .{ .assignment = .{
        .varName = .{ .name = "aoeu" },
        .value = &dict,
    } };

    var parser = Self.init(input, std.testing.allocator);
    const result = parser.parse() catch unreachable;
    defer std.testing.allocator.free(result);
    defer for (result) |st| {
        stmt.free(std.testing.allocator, st);
    };

    try std.testing.expectEqual(1, result.len);
    const result_stmt = result[0];
    try std.testing.expect(result_stmt == .assignment);
    try std.testing.expectEqualStrings(expected_.assignment.varName.name, result_stmt.assignment.varName.name);
    try std.testing.expect(result_stmt.assignment.value.* == .dictionary);
    const result_arr = result_stmt.assignment.value.dictionary;
    try std.testing.expectEqual(dict.dictionary.entries.len, result_arr.entries.len);
    for (dict.dictionary.entries, result_arr.entries) |expected, actual| {
        try std.testing.expectEqual(expected.key.*, actual.key.*);
        try std.testing.expectEqual(expected.value.*, actual.value.*);
    }
}

test "dictionary empty" {
    const input = "aoeu = { }";
    const entries: []expr.DictionaryEntry = &[_]expr.DictionaryEntry{};
    var dict: expr.Expression = .{ .dictionary = .{ .entries = entries } };
    const expected_: stmt.Statement = .{ .assignment = .{
        .varName = .{ .name = "aoeu" },
        .value = &dict,
    } };

    var parser = Self.init(input, std.testing.allocator);
    const result = parser.parse() catch unreachable;
    defer std.testing.allocator.free(result);
    defer for (result) |st| {
        stmt.free(std.testing.allocator, st);
    };

    try std.testing.expectEqual(1, result.len);
    const result_stmt = result[0];
    try std.testing.expect(result_stmt == .assignment);
    try std.testing.expectEqualStrings(expected_.assignment.varName.name, result_stmt.assignment.varName.name);
    try std.testing.expect(result_stmt.assignment.value.* == .dictionary);
    const result_arr = result_stmt.assignment.value.dictionary;
    try std.testing.expectEqual(dict.dictionary.entries.len, result_arr.entries.len);
}

test "assign after array" {
    const input =
        \\aoeu = [ 1, 2,3,4]
        \\aoeu = [ 1, 2,   3 ,4 ]
        \\aoeu = [ 1, 2 ]
    ;
    // NOTE: we assume that the assignment parsing is working correctly
    var tmp = expr.Expression{ .number = .{ .integer = 1 } };
    var elements: [4]expr.Expression = undefined;
    elements[0] = tmp;
    tmp.number.integer = 2;
    elements[1] = tmp;
    tmp.number.integer = 3;
    elements[2] = tmp;
    tmp.number.integer = 4;
    elements[3] = tmp;
    const arr: expr.Expression = .{ .array = .{ .elements = &elements } };

    var parser = Self.init(input, std.testing.allocator);
    const result = parser.parse() catch unreachable;
    defer std.testing.allocator.free(result);
    defer for (result) |st| {
        stmt.free(std.testing.allocator, st);
    };

    try std.testing.expectEqual(3, result.len);
    const result_stmt_1 = result[0];
    const result_stmt_2 = result[0];
    try std.testing.expect(result_stmt_1 == .assignment);
    try std.testing.expect(result_stmt_2 == .assignment);
    try std.testing.expect(result_stmt_1.assignment.value.* == .array);
    try std.testing.expect(result_stmt_2.assignment.value.* == .array);
    const result_arr_1 = result_stmt_1.assignment.value.array;
    const result_arr_2 = result_stmt_2.assignment.value.array;
    try std.testing.expectEqualSlices(expr.Expression, arr.array.elements, result_arr_1.elements);
    try std.testing.expectEqualSlices(expr.Expression, arr.array.elements, result_arr_2.elements);
}

test "comment" {
    const input =
        \\ // commment
        \\aoeu = [ 1, 2,3,4]
        \\aoeu = [ 1, 2,   3 ,4 ]
    ;
    // NOTE: we assume that the assignment parsing is working correctly
    var tmp = expr.Expression{ .number = .{ .integer = 1 } };
    var elements: [4]expr.Expression = undefined;
    elements[0] = tmp;
    tmp.number.integer = 2;
    elements[1] = tmp;
    tmp.number.integer = 3;
    elements[2] = tmp;
    tmp.number.integer = 4;
    elements[3] = tmp;
    const arr: expr.Expression = .{ .array = .{ .elements = &elements } };

    var parser = Self.init(input, std.testing.allocator);
    const result = parser.parse() catch unreachable;
    defer std.testing.allocator.free(result);
    defer for (result) |st| {
        stmt.free(std.testing.allocator, st);
    };

    try std.testing.expectEqual(2, result.len);
    const result_stmt_1 = result[0];
    const result_stmt_2 = result[0];
    try std.testing.expect(result_stmt_1 == .assignment);
    try std.testing.expect(result_stmt_2 == .assignment);
    try std.testing.expect(result_stmt_1.assignment.value.* == .array);
    try std.testing.expect(result_stmt_2.assignment.value.* == .array);
    const result_arr_1 = result_stmt_1.assignment.value.array;
    const result_arr_2 = result_stmt_2.assignment.value.array;
    try std.testing.expectEqualSlices(expr.Expression, arr.array.elements, result_arr_1.elements);
    try std.testing.expectEqualSlices(expr.Expression, arr.array.elements, result_arr_2.elements);
}

test "newline + assign after array" {
    const input =
        \\aoeu = [ 1, 2 ]
        \\
        \\aoeu = [ 1, 2 ]
    ;
    // NOTE: we assume that the assignment parsing is working correctly
    var tmp = expr.Expression{ .number = .{ .integer = 1 } };
    var elements: [2]expr.Expression = undefined;
    elements[0] = tmp;
    tmp.number.integer = 2;
    elements[1] = tmp;
    const arr: expr.Expression = .{ .array = .{ .elements = &elements } };

    var parser = Self.init(input, std.testing.allocator);
    const result = parser.parse() catch unreachable;
    defer std.testing.allocator.free(result);
    defer for (result) |st| {
        stmt.free(std.testing.allocator, st);
    };

    try std.testing.expectEqual(2, result.len);
    const result_stmt_1 = result[0];
    const result_stmt_2 = result[0];
    try std.testing.expect(result_stmt_1 == .assignment);
    try std.testing.expect(result_stmt_2 == .assignment);
    try std.testing.expect(result_stmt_1.assignment.value.* == .array);
    try std.testing.expect(result_stmt_2.assignment.value.* == .array);
    const result_arr_1 = result_stmt_1.assignment.value.array;
    const result_arr_2 = result_stmt_2.assignment.value.array;
    try std.testing.expectEqualSlices(expr.Expression, arr.array.elements, result_arr_1.elements);
    try std.testing.expectEqualSlices(expr.Expression, arr.array.elements, result_arr_2.elements);
}

test "empty array" {
    const input = "aoeu = [ ] \n";
    var arr: expr.Expression = .{ .array = .{ .elements = &[_]expr.Expression{} } };
    const expected: stmt.Statement = .{ .assignment = .{
        .varName = .{ .name = "aoeu" },
        .value = &arr,
    } };

    var parser = Self.init(input, std.testing.allocator);
    const result = parser.parse() catch unreachable;
    defer std.testing.allocator.free(result);
    defer for (result) |st| {
        stmt.free(std.testing.allocator, st);
    };

    try std.testing.expectEqual(1, result.len);
    const result_stmt = result[0];
    try std.testing.expect(result_stmt == .assignment);
    try std.testing.expectEqualStrings(expected.assignment.varName.name, result_stmt.assignment.varName.name);
    try std.testing.expect(result_stmt.assignment.value.* == .array);
    const result_arr = result_stmt.assignment.value.array;
    try std.testing.expectEqualSlices(expr.Expression, arr.array.elements, result_arr.elements);
}

test "simple if statement" {
    const input =
        \\if (true) {
        \\    aoeu = aoeu
        \\}
        \\
    ;
    var cond = .{ .boolean = .{ .value = true } };
    var ident = .{ .identifier = .{ .name = "aoeu" } };
    const ass = .{ .assignment = .{
        .varName = .{ .name = "aoeu" },
        .value = &ident,
    } };
    const branch: stmt.Branch = .{
        .condition = &cond,
        .body = &[_]stmt.Statement{
            ass,
        },
    };
    const expected: stmt.Statement = .{ .if_statement = .{
        .ifBranch = branch,
        .elseBranch = null,
    } };

    var parser = Self.init(input, std.testing.allocator);
    const result = parser.parse() catch unreachable;
    defer std.testing.allocator.free(result);
    defer for (result) |st| {
        stmt.free(std.testing.allocator, st);
    };

    try std.testing.expectEqual(1, result.len);
    const result_stmt = result[0];
    try std.testing.expect(result_stmt == .if_statement);

    const expected_branch = expected.if_statement.ifBranch;
    const result_branch = result_stmt.if_statement.ifBranch;

    try std.testing.expect(result_branch.condition.* == .boolean);
    try std.testing.expectEqual(expected_branch.condition.boolean.value, result_branch.condition.boolean.value);

    const expected_body_statement = expected_branch.body[0];
    const result_body_statement = result_branch.body[0];

    try std.testing.expect(result_body_statement == .assignment);
    try std.testing.expectEqualStrings(expected_body_statement.assignment.value.identifier.name, result_body_statement.assignment.value.identifier.name);
    try std.testing.expectEqualStrings(expected_body_statement.assignment.varName.name, result_body_statement.assignment.varName.name);
}
