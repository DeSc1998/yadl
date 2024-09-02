const std = @import("std");
const stmt = @import("statement.zig");
const expr = @import("expression.zig");

const Scope = @import("scope.zig");

const Expression = expr.Expression;
const Statement = stmt.Statement;

pub const Error = error{
    NotImplemented,
    FunctionNotFound,
    ValueNotFound,
    IOWrite,
    InvalidExpressoinType,
} || Scope.Error;

pub fn evalStatement(statement: Statement, scope: *Scope) Error!void {
    if (scope.hasResult() and !scope.isGlobal()) {
        return;
    }

    switch (statement) {
        .assignment => |a| {
            try evalExpression(a.value, scope);
            try scope.update(a.varName, scope.result() orelse unreachable);
        },
        .functioncall => |fc| {
            try evalFunctionCall(fc, scope);
            scope.return_result = null;
        },
        .ret => |r| {
            try evalExpression(r.value, scope);
            const result = scope.result() orelse unreachable;
            scope.return_result = result;
        },
        .whileloop => |w| {
            var cond = false;
            try evalExpression(w.loop.condition, scope);
            var tmp = scope.result() orelse unreachable;
            cond = tmp.* == .boolean and tmp.boolean.value;
            while (cond) {
                for (w.loop.body) |st| {
                    try evalStatement(st, scope);
                }

                try evalExpression(w.loop.condition, scope);
                tmp = scope.result() orelse unreachable;
                cond = tmp.* == .boolean and tmp.boolean.value;
            }
        },
        .if_statement => |i| {
            try evalExpression(i.ifBranch.condition, scope);
            const tmp = scope.result() orelse unreachable;
            if (tmp.* == .boolean and tmp.boolean.value) {
                for (i.ifBranch.body) |st| {
                    try evalStatement(st, scope);
                }
            } else {
                if (i.elseBranch) |b| {
                    for (b) |st| {
                        try evalStatement(st, scope);
                    }
                }
            }
        },
        else => |st| {
            std.debug.print("TODO: unhandled case in eval statement: {}\n", .{st});
            return Error.NotImplemented;
        },
    }
}

fn evalFunctionCall(fc: expr.FunctionCall, scope: *Scope) Error!void {
    const tmpArgs = try scope.allocator.alloc(Expression, fc.args.len);
    defer scope.allocator.free(tmpArgs);

    for (fc.args, tmpArgs) |*arg, *tmparg| {
        try evalExpression(arg, scope);
        const tmp = scope.result() orelse unreachable;
        tmparg.* = tmp.*;
    }

    switch (fc.func.*) {
        .identifier => |id| {
            if (std.mem.eql(u8, id.name, "print")) {
                var has_printed = false;
                for (tmpArgs) |*value| {
                    if (has_printed) {
                        scope.out.print(" ", .{}) catch return Error.IOWrite;
                    } else has_printed = true;
                    try printValue(value.*, scope);
                }
                scope.out.print("\n", .{}) catch return Error.IOWrite;
            } else if (false) { // stdlib functions
                return Error.NotImplemented;
            } else if (scope.lookupFunction(id)) |f| {
                var localScope = try Scope.init(scope.allocator, scope.out, scope, f.args, tmpArgs);
                for (f.body) |st| {
                    try evalStatement(st, &localScope);
                }
                const result = localScope.result();
                scope.return_result = result;
            }
        },
        else => |e| {
            std.debug.print("ERROR: unhandled case in function call: {}\n", .{e});
            return Error.NotImplemented;
        },
    }
}

fn printValue(value: Expression, scope: *Scope) Error!void {
    switch (value) {
        .number => |n| {
            if (n == .float) {
                scope.out.print("{}", .{n.float}) catch return Error.IOWrite;
            } else scope.out.print("{}", .{n.integer}) catch return Error.IOWrite;
        },
        .boolean => |v| {
            scope.out.print("{}", .{v.value}) catch return Error.IOWrite;
        },
        .string => |v| {
            scope.out.print("{s}", .{v.value}) catch return Error.IOWrite;
        },
        else => |v| {
            std.debug.print("TODO: printing of value: {}\n", .{v});
            return Error.NotImplemented;
        },
    }
}

fn evalExpression(value: *Expression, scope: *Scope) Error!void {
    switch (value.*) {
        .identifier => |id| {
            var v = try scope.lookup(id) orelse {
                std.debug.print("ERROR: no value found for '{s}'\n", .{id.name});
                return Error.ValueNotFound;
            };
            while (v.* == .identifier) {
                v = try scope.lookup(id) orelse {
                    std.debug.print("ERROR: no value found for '{s}'\n", .{id.name});
                    return Error.ValueNotFound;
                };
            }
            scope.return_result = v;
        },
        .binary_op => |bin| try evalBinaryOp(bin.op, bin.left, bin.right, scope),
        .unary_op => |un| try evalUnaryOp(un.op, un.operant, scope),
        .wrapped => |w| {
            try evalExpression(w, scope);
        },
        .functioncall => |fc| {
            try evalFunctionCall(fc, scope);
        },
        .array => {
            scope.return_result = value;
        },
        .dictionary => {
            scope.return_result = value;
        },
        .function => {
            scope.return_result = value;
        },
        .number => {
            scope.return_result = value;
        },
        .string => {
            scope.return_result = value;
        },
        .boolean => {
            scope.return_result = value;
        },
        else => |v| {
            std.debug.print("TODO: unhandled case in eval expr: {}\n", .{v});
            return Error.NotImplemented;
        },
    }
}

fn evalUnaryOp(op: expr.Operator, operant: *Expression, scope: *Scope) !void {
    switch (op) {
        .arithmetic => |ops| {
            if (ops != .Sub) unreachable;
            switch (operant.*) {
                .number => |num| {
                    if (num == .float) {
                        const tmp = try expr.Number.init(scope.allocator, f64, -num.float);
                        scope.return_result = tmp;
                    } else {
                        const tmp = try expr.Number.init(scope.allocator, i64, -num.integer);
                        scope.return_result = tmp;
                    }
                },
                else => return Error.NotImplemented,
            }
        },
        .boolean => |ops| {
            if (ops != .Not) unreachable;
            switch (operant.*) {
                .boolean => |b| {
                    const tmp = try expr.Boolean.init(scope.allocator, !b.value);
                    scope.return_result = tmp;
                },
                else => return Error.NotImplemented,
            }
        },
        else => unreachable,
    }
}

fn evalBinaryOp(op: expr.Operator, left: *Expression, right: *Expression, scope: *Scope) !void {
    switch (op) {
        .arithmetic => |ops| try evalArithmeticOps(ops, left, right, scope),
        .compare => |ops| try evalCompareOps(ops, left, right, scope),
        .boolean => |ops| try evalBooleanOps(ops, left, right, scope),
    }
}

fn evalArithmeticOps(op: expr.ArithmeticOps, left: *Expression, right: *Expression, scope: *Scope) !void {
    try evalExpression(left, scope);
    const leftEval = scope.result() orelse unreachable;
    try evalExpression(right, scope);
    const rightEval = scope.result() orelse unreachable;

    switch (op) {
        .Add => switch (leftEval.*) {
            .string => |l| switch (rightEval.*) {
                .string => |r| {
                    const out = try scope.allocator.create(Expression);
                    const tmp = try std.mem.join(scope.allocator, "", &[_][]const u8{ l.value, r.value });
                    out.* = .{ .string = .{ .value = tmp } };
                    scope.return_result = out;
                },
                else => return Error.NotImplemented,
            },
            .number => |l| switch (rightEval.*) {
                .number => |r| {
                    const n = l.add(r);
                    if (n == .float) {
                        const tmp = try expr.Number.init(scope.allocator, f64, n.float);
                        scope.return_result = tmp;
                    } else {
                        const tmp = try expr.Number.init(scope.allocator, i64, n.integer);
                        scope.return_result = tmp;
                    }
                },
                else => return Error.NotImplemented,
            },
            else => {
                std.debug.print("ERROR: can not add value of type '{}'\n", .{leftEval});
                return Error.NotImplemented;
            },
        },
        else => |v| {
            std.debug.print("ERROR: unhandled case in arith. bin. op.: {}\n", .{v});
            return Error.NotImplemented;
        },
    }
}

fn asNumber(ex: *Expression) expr.Number {
    return switch (ex.*) {
        .number => ex.number,
        .boolean => |bl| expr.Number{ .integer = @intFromBool(bl.value) },
        else => {
            std.debug.print("ERROR: value not convertable to number: {}\n", .{ex});
            unreachable;
        },
    };
}

fn evalCompareOps(op: expr.CompareOps, left: *Expression, right: *Expression, scope: *Scope) !void {
    try evalExpression(left, scope);
    const leftEval = if (scope.result()) |tmp| asNumber(tmp) else unreachable;
    try evalExpression(right, scope);
    const rightEval = if (scope.result()) |tmp| asNumber(tmp) else unreachable;

    switch (op) {
        .Equal => {
            const tmp = try scope.allocator.create(Expression);
            tmp.* = .{ .boolean = .{ .value = leftEval.eql(rightEval) } };
            scope.return_result = tmp;
        },
        .NotEqual => {
            const tmp = try scope.allocator.create(Expression);
            tmp.* = .{ .boolean = .{ .value = !leftEval.eql(rightEval) } };
            scope.return_result = tmp;
        },
        .Less => {
            const out = try scope.allocator.create(Expression);
            const tmp: bool = switch (leftEval) {
                .float => |l| switch (rightEval) {
                    .float => |r| l < r,
                    .integer => |r| l < @as(f64, @floatFromInt(r)),
                },
                .integer => |l| switch (rightEval) {
                    .float => |r| @as(f64, @floatFromInt(l)) < r,
                    .integer => |r| l < r,
                },
            };
            out.* = .{ .boolean = .{ .value = tmp } };
            scope.return_result = out;
        },
        .LessEqual => {
            const out = try scope.allocator.create(Expression);
            const tmp: bool = switch (leftEval) {
                .float => |l| switch (rightEval) {
                    .float => |r| l <= r,
                    .integer => |r| l <= @as(f64, @floatFromInt(r)),
                },
                .integer => |l| switch (rightEval) {
                    .float => |r| @as(f64, @floatFromInt(l)) <= r,
                    .integer => |r| l <= r,
                },
            };
            out.* = .{ .boolean = .{ .value = tmp } };
            scope.return_result = out;
        },
        else => return Error.NotImplemented,
    }
}

fn evalBooleanOps(op: expr.BooleanOps, left: *Expression, right: *Expression, scope: *Scope) !void {
    try evalExpression(left, scope);
    const leftEval = scope.result() orelse unreachable;
    try evalExpression(right, scope);
    const rightEval = scope.result() orelse unreachable;

    if (leftEval.* != .boolean or rightEval.* != .boolean) {
        std.debug.print("ERROR: boolean operators are only allowed for booleans\n", .{});
        return Error.NotImplemented;
    }

    const l = leftEval.boolean.value;
    const r = rightEval.boolean.value;

    switch (op) {
        .And => {
            const out = try scope.allocator.create(Expression);
            out.* = .{ .boolean = .{ .value = l and r } };
            scope.return_result = out;
        },
        .Or => {
            const out = try scope.allocator.create(Expression);
            out.* = .{ .boolean = .{ .value = l or r } };
            scope.return_result = out;
        },
        else => {
            unreachable;
        },
    }
}
