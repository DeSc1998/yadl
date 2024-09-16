const std = @import("std");
const stmt = @import("statement.zig");
const expr = @import("expression.zig");

const Scope = @import("scope.zig");
const stdlib = @import("stdlib.zig");

const Expression = expr.Expression;
const Statement = stmt.Statement;

pub const Error = error{
    NotImplemented,
    FunctionNotFound,
    ValueNotFound,
    NoEntryForKey,
    IOWrite,
    InvalidExpressoinType,
    ArityMismatch,
} || Scope.Error;

pub fn evalStatement(statement: Statement, scope: *Scope) Error!void {
    if (scope.hasResult() and !scope.isGlobal()) {
        return;
    }

    switch (statement) {
        .assignment => |a| {
            try evalExpression(a.value, scope);
            try scope.update(a.varName, scope.result_ref() orelse unreachable);
        },
        .functioncall => |fc| {
            var tmp = fc;
            try evalFunctionCall(&tmp, scope);
            scope.return_result = null;
        },
        .@"return" => |r| {
            try evalExpression(r.value, scope);
            const result = scope.result_ref() orelse unreachable;
            scope.return_result = result;
        },
        .whileloop => |w| {
            var cond = false;
            try evalExpression(w.loop.condition, scope);
            var tmp = scope.result() orelse unreachable;
            cond = tmp == .boolean and tmp.boolean.value;
            while (cond) {
                for (w.loop.body) |st| {
                    try evalStatement(st, scope);
                }

                try evalExpression(w.loop.condition, scope);
                tmp = scope.result() orelse unreachable;
                cond = tmp == .boolean and tmp.boolean.value;
            }
        },
        .if_statement => |i| {
            try evalExpression(i.ifBranch.condition, scope);
            const tmp = scope.result() orelse unreachable;
            if (tmp == .boolean and tmp.boolean.value) {
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
        .struct_assignment => |sa| {
            try modify(sa.access, sa.value, scope);
        },
    }
}

fn modify(strct: *Expression, value: *Expression, scope: *Scope) Error!void {
    std.debug.assert(strct.* == .struct_access);
    try evalExpression(value, scope);
    const ex = scope.result_ref() orelse unreachable;
    try evalExpression(strct.struct_access.strct, scope);
    const contianer = scope.result_ref() orelse unreachable;
    try evalExpression(strct.struct_access.key, scope);
    const key = scope.result_ref() orelse unreachable;

    switch (contianer.*) {
        .array => |*a| {
            if (key.* != .number or key.number != .integer or key.number.integer >= a.elements.len and key.number.integer < 0) {
                std.debug.print("ERROR: invalid expressoin type: {s}\n", .{@tagName(key.*)});
                return Error.InvalidExpressoinType;
            }
            const index = @as(usize, @intCast(key.number.integer));
            expr.free_local(scope.allocator, a.elements[index]);
            a.elements[index] = ex.*;
        },
        .dictionary => |*d| {
            if (key.* != .number and key.* != .string and key.* != .boolean) {
                return Error.InvalidExpressoinType;
            }
            for (d.entries) |*e| {
                if (key.eql(e.key.*)) {
                    expr.free(scope.allocator, e.value);
                    e.value = ex;
                    return;
                }
            }
            const new_entries = try scope.allocator.alloc(expr.DictionaryEntry, d.entries.len + 1);
            for (d.entries, new_entries[0..d.entries.len]) |e, *new| {
                new.* = e;
            }
            new_entries[d.entries.len] = .{
                .key = key,
                .value = ex,
            };
            scope.allocator.free(d.entries);
            d.entries = new_entries;
        },
        else => return Error.InvalidExpressoinType,
    }
}

fn evalStdlibCall(context: stdlib.FunctionContext, evaled_args: []const Expression, scope: *Scope) Error!void {
    if (context.arity != evaled_args.len) {
        std.debug.print(
            "ERROR: incorrect number of arguments: expected {}, but got {}\n",
            .{ context.arity, evaled_args.len },
        );
        return Error.ArityMismatch;
    }
    context.function(evaled_args, scope) catch unreachable; // TODO: handle error once error values are added
}

pub fn evalFunctionCall(fc: *expr.FunctionCall, scope: *Scope) Error!void {
    const tmpArgs = try scope.allocator.alloc(Expression, fc.args.len);
    defer scope.allocator.free(tmpArgs);

    for (fc.args, tmpArgs) |*arg, *tmparg| {
        try evalExpression(arg, scope);
        const tmp = scope.result() orelse unreachable;
        tmparg.* = tmp;
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
            } else if (stdlib.getBuiltin(id.name)) |fn_ctxt| {
                try evalStdlibCall(fn_ctxt, tmpArgs, scope);
            } else |err| {
                if (err == stdlib.Error.BuiltinsNotInitialized) {
                    stdlib.initBuiltins(scope.allocator) catch return Error.OutOfMemory;
                }

                if (stdlib.getBuiltin(id.name)) |fn_ctxt| {
                    try evalStdlibCall(fn_ctxt, tmpArgs, scope);
                    return;
                } else |e| if (e != stdlib.Error.FunctionNotFound) return Error.OutOfMemory;

                if (scope.lookupFunction(id)) |f| {
                    var localScope = try Scope.init(scope.allocator, scope.out, scope, f.args, tmpArgs);
                    for (f.body) |st| {
                        try evalStatement(st, &localScope);
                    }
                    const result = localScope.result_ref();
                    scope.return_result = result;
                } else {
                    std.debug.print("ERROR: no function found under the name '{s}'\n", .{id.name});
                    return Error.FunctionNotFound;
                }
            }
        },
        .wrapped => |e| {
            var tmp = .{ .func = e, .args = fc.args };
            try evalFunctionCall(&tmp, scope);
        },
        .functioncall => {
            var tmp = fc.func.*;
            try evalExpression(&tmp, scope);
            const f = scope.result_ref() orelse unreachable;
            // if (f != .function) {
            //     std.debug.print("ERROR: returned expression from function call is not a function but '{s}'\n", .{@tagName(f)});
            //     return Error.InvalidExpressoinType;
            // }
            var tmp2 = .{ .func = f, .args = fc.args };
            try evalFunctionCall(&tmp2, scope);
        },
        .function => |f| {
            var localScope = try Scope.init(scope.allocator, scope.out, scope, f.args, tmpArgs);
            for (f.body) |st| {
                try evalStatement(st, &localScope);
            }
            const result = localScope.result_ref();
            scope.return_result = result;
        },
        else => |e| {
            std.debug.print("ERROR: unhandled expression case in function call: {s}\n", .{@tagName(e)});
            return Error.NotImplemented;
        },
    }
}

pub fn printValue(value: Expression, scope: *Scope) Error!void {
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
        .array => |v| {
            scope.out.print("[", .{}) catch return Error.IOWrite;
            var has_printed = false;
            for (v.elements) |val| {
                if (has_printed) {
                    scope.out.print(", ", .{}) catch return Error.IOWrite;
                } else has_printed = true;
                try printValue(val, scope);
            }
            scope.out.print("]", .{}) catch return Error.IOWrite;
        },
        .dictionary => |v| {
            _ = scope.out.write("{") catch return Error.IOWrite;
            var has_printed = false;
            for (v.entries) |val| {
                if (has_printed) {
                    _ = scope.out.write(", ") catch return Error.IOWrite;
                } else has_printed = true;
                try printValue(val.key.*, scope);
                _ = scope.out.write(": ") catch return Error.IOWrite;
                try printValue(val.value.*, scope);
            }
            _ = scope.out.write("}") catch return Error.IOWrite;
        },
        else => |v| {
            std.debug.print("TODO: printing of value: {s}\n", .{@tagName(v)});
            return Error.NotImplemented;
        },
    }
}

fn evalStructAccess(strct: *Expression, key: *Expression, scope: *Scope) Error!void {
    switch (strct.*) {
        .struct_access => |sa| {
            try evalStructAccess(sa.strct, sa.key, scope);
            const st = scope.result_ref() orelse unreachable;
            try evalStructAccess(st, key, scope);
        },
        .identifier => {
            try evalExpression(strct, scope);
            const st = scope.result_ref() orelse unreachable;
            try evalStructAccess(st, key, scope);
        },
        .array => |a| {
            if (key.* != .number or key.number != .integer or key.number.integer >= a.elements.len and key.number.integer < 0) {
                std.debug.print("INFO: expr: {}\n", .{key});
                return Error.InvalidExpressoinType;
            }
            const index = key.number.integer;
            scope.return_result = &a.elements[@intCast(index)];
        },
        .dictionary => |d| {
            if (key.* != .number and key.* != .string and key.* != .boolean) {
                return Error.InvalidExpressoinType;
            }
            for (d.entries) |e| {
                if (key.eql(e.key.*)) {
                    scope.return_result = e.value;
                    return;
                }
            }
            return Error.NoEntryForKey;
        },
        else => |v| {
            const value = @tagName(v);
            std.debug.print("ERROR: Invalid structure to access: {s}\n", .{value});
            return Error.InvalidExpressoinType;
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
            var tmp = fc;
            try evalFunctionCall(&tmp, scope);
        },
        .struct_access => |sa| try evalStructAccess(sa.strct, sa.key, scope),
        .array => {
            scope.return_result = value;
        },
        .dictionary => {
            scope.return_result = value;
        },
        .function => |f| {
            const new_body = try scope.captureExternals(&[_]expr.Identifier{}, f.body);
            const out = try scope.allocator.create(Expression);
            out.* = .{ .function = .{
                .args = f.args,
                .body = new_body,
            } };
            scope.return_result = out;
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
        .Add => switch (leftEval) {
            .string => |l| switch (rightEval) {
                .string => |r| {
                    const out = try scope.allocator.create(Expression);
                    const tmp = try std.mem.join(scope.allocator, "", &[_][]const u8{ l.value, r.value });
                    out.* = .{ .string = .{ .value = tmp } };
                    scope.return_result = out;
                },
                .boolean => {
                    try stdlib.conversions.toString(&[_]Expression{rightEval}, scope);
                    const r = scope.result() orelse unreachable;
                    const out = try scope.allocator.create(Expression);
                    const inner = try std.mem.join(scope.allocator, "", &[_][]const u8{ l.value, r.string.value });
                    out.* = .{ .string = .{ .value = inner } };
                    scope.return_result = out;
                },
                .number => {
                    try stdlib.conversions.toString(&[_]Expression{rightEval}, scope);
                    const r = scope.result() orelse unreachable;
                    const out = try scope.allocator.create(Expression);
                    const inner = try std.mem.join(scope.allocator, "", &[_][]const u8{ l.value, r.string.value });
                    out.* = .{ .string = .{ .value = inner } };
                    scope.return_result = out;
                },
                else => return Error.NotImplemented,
            },
            .number => |l| switch (rightEval) {
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
            else => |e| {
                try stdlib.conversions.toNumber(&[_]Expression{e}, scope);
                const l = scope.result() orelse unreachable;
                try stdlib.conversions.toNumber(&[_]Expression{rightEval}, scope);
                const r = scope.result() orelse unreachable;
                const res = l.number.add(r.number);
                if (res == .float) {
                    const tmp = try expr.Number.init(scope.allocator, f64, res.float);
                    scope.return_result = tmp;
                } else {
                    const tmp = try expr.Number.init(scope.allocator, i64, res.integer);
                    scope.return_result = tmp;
                }
            },
        },
        .Mul => switch (leftEval) {
            .number => |l| switch (rightEval) {
                .number => |r| {
                    const n = l.mul(r);
                    if (n == .float) {
                        const tmp = try expr.Number.init(scope.allocator, f64, n.float);
                        scope.return_result = tmp;
                    } else {
                        const tmp = try expr.Number.init(scope.allocator, i64, n.integer);
                        scope.return_result = tmp;
                    }
                },
                else => |v| {
                    std.debug.print("ERROR: unhandled case in arith. Mul - number: {}\n", .{v});
                    return Error.NotImplemented;
                },
            },
            else => |e| {
                try stdlib.conversions.toNumber(&[_]Expression{e}, scope);
                const l = scope.result() orelse unreachable;
                try stdlib.conversions.toNumber(&[_]Expression{rightEval}, scope);
                const r = scope.result() orelse unreachable;
                const res = l.number.mul(r.number);
                if (res == .float) {
                    const tmp = try expr.Number.init(scope.allocator, f64, res.float);
                    scope.return_result = tmp;
                } else {
                    const tmp = try expr.Number.init(scope.allocator, i64, res.integer);
                    scope.return_result = tmp;
                }
            },
        },
        .Sub => switch (leftEval) {
            .number => |l| switch (rightEval) {
                .number => |r| {
                    const n = l.sub(r);
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
            else => |e| {
                try stdlib.conversions.toNumber(&[_]Expression{e}, scope);
                const l = scope.result() orelse unreachable;
                try stdlib.conversions.toNumber(&[_]Expression{rightEval}, scope);
                const r = scope.result() orelse unreachable;
                const res = l.number.sub(r.number);
                if (res == .float) {
                    const tmp = try expr.Number.init(scope.allocator, f64, res.float);
                    scope.return_result = tmp;
                } else {
                    const tmp = try expr.Number.init(scope.allocator, i64, res.integer);
                    scope.return_result = tmp;
                }
            },
        },
        .Div => switch (leftEval) {
            .number => |l| switch (rightEval) {
                .number => |r| {
                    const n = l.div(r);
                    if (n == .float) {
                        const tmp = try expr.Number.init(scope.allocator, f64, n.float);
                        scope.return_result = tmp;
                    } else {
                        const tmp = try expr.Number.init(scope.allocator, i64, n.integer);
                        scope.return_result = tmp;
                    }
                },
                else => |v| {
                    std.debug.print("ERROR: unhandled case in arith. Div - number: {}\n", .{v});
                    return Error.NotImplemented;
                },
            },
            else => |e| {
                try stdlib.conversions.toNumber(&[_]Expression{e}, scope);
                const l = scope.result() orelse unreachable;
                try stdlib.conversions.toNumber(&[_]Expression{rightEval}, scope);
                const r = scope.result() orelse unreachable;
                const res = l.number.div(r.number);
                if (res == .float) {
                    const tmp = try expr.Number.init(scope.allocator, f64, res.float);
                    scope.return_result = tmp;
                } else {
                    const tmp = try expr.Number.init(scope.allocator, i64, res.integer);
                    scope.return_result = tmp;
                }
            },
        },
        .Expo => switch (leftEval) {
            .number => |l| switch (rightEval) {
                .number => |r| {
                    const n = l.expo(r);
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
                std.debug.print("ERROR: can not add value of type '{s}'\n", .{@tagName(leftEval)});
                return Error.NotImplemented;
            },
        },
        .Mod => switch (leftEval) {
            .number => |l| switch (rightEval) {
                .number => |r| {
                    if (r == .integer and l == .integer) {
                        const tmp = std.math.mod(i64, l.integer, r.integer) catch return Error.InvalidExpressoinType;
                        scope.return_result = try expr.Number.init(scope.allocator, i64, tmp);
                    } else {
                        const leftmp = if (l == .integer) @as(f64, @floatFromInt(l.integer)) else l.float;
                        const rightmp = if (r == .integer) @as(f64, @floatFromInt(r.integer)) else r.float;

                        const tmp = std.math.mod(f64, leftmp, rightmp) catch return Error.InvalidExpressoinType;
                        scope.return_result = try expr.Number.init(scope.allocator, f64, tmp);
                    }
                },
                else => return Error.NotImplemented,
            },
            else => return Error.NotImplemented,
        },
    }
}

fn evalCompareOps(op: expr.CompareOps, left: *Expression, right: *Expression, scope: *Scope) !void {
    try evalExpression(left, scope);
    const leftEval = scope.result() orelse unreachable;
    try evalExpression(right, scope);
    const rightEval = scope.result() orelse unreachable;

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
        .Less => switch (leftEval) {
            .number => |l| switch (rightEval) {
                .number => |r| {
                    const out = try scope.allocator.create(Expression);
                    const tmp: bool = if (l == .integer and r == .integer) l.integer < r.integer else l.asFloat() < r.asFloat();
                    out.* = .{ .boolean = .{ .value = tmp } };
                    scope.return_result = out;
                },
                else => return Error.NotImplemented,
            },
            else => return Error.NotImplemented,
        },
        .LessEqual => {
            try evalCompareOps(.Less, left, right, scope);
            const less = scope.result_ref() orelse unreachable;
            try evalCompareOps(.Equal, left, right, scope);
            var out = scope.result_ref() orelse unreachable;
            out.boolean.value = out.boolean.value or less.boolean.value;
            expr.free(scope.allocator, less);
            scope.return_result = out;
        },
        .Greater => {
            try evalCompareOps(.LessEqual, left, right, scope);
            var out = scope.result_ref() orelse unreachable;
            out.boolean.value = !out.boolean.value;
            scope.return_result = out;
        },
        .GreaterEqual => {
            try evalCompareOps(.Less, left, right, scope);
            var out = scope.result_ref() orelse unreachable;
            out.boolean.value = !out.boolean.value;
            scope.return_result = out;
        },
    }
}

fn evalBooleanOps(op: expr.BooleanOps, left: *Expression, right: *Expression, scope: *Scope) !void {
    try evalExpression(left, scope);
    const leftEval = scope.result() orelse unreachable;
    try evalExpression(right, scope);
    const rightEval = scope.result() orelse unreachable;

    if (leftEval != .boolean or rightEval != .boolean) {
        std.debug.print("ERROR: boolean operators are only allowed for booleans\n", .{});
        return Error.InvalidExpressoinType;
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
