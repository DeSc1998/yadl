const std = @import("std");

const expression = @import("../expression.zig");
const interpreter = @import("../interpreter.zig");
const data = @import("data.zig");
const Scope = @import("../scope.zig");
const Expression = expression.Expression;

pub const Error = @import("error.zig").Error;

pub fn length(args: []const Expression, scope: *Scope) Error!void {
    switch (args[0]) {
        .array => |a| {
            scope.return_result = try expression.Number.init(
                scope.allocator,
                i64,
                @intCast(a.elements.len),
            );
        },
        .dictionary => |d| {
            scope.return_result = try expression.Number.init(
                scope.allocator,
                i64,
                @intCast(d.entries.len),
            );
        },
        else => unreachable,
    }
}

pub fn _type(args: []const Expression, scope: *Scope) Error!void {
    const out = try scope.allocator.create(Expression);
    out.* = .{ .string = .{ .value = @tagName(args[0]) } };
    scope.return_result = out;
}

pub fn load_data(args: []const Expression, scope: *Scope) Error!void {
    const file_path = args[0];
    const data_format = args[1];
    std.debug.assert(file_path == .string);
    std.debug.assert(data_format == .string);
    if (std.mem.eql(u8, data_format.string.value, "lines")) {
        const lines = data.load_lines(file_path.string.value, scope.allocator) catch |err| {
            std.debug.print("ERROR: loading file failed: {}\n", .{err});
            return Error.NotImplemented;
        };
        defer scope.allocator.free(lines);
        const out = try scope.allocator.alloc(Expression, lines.len);
        for (lines, out) |line, *elem| {
            elem.* = .{ .string = .{ .value = line } };
        }
        const tmp = try scope.allocator.create(Expression);
        tmp.* = .{ .array = .{ .elements = out } };
        scope.return_result = tmp;
    } else if (std.mem.eql(u8, data_format.string.value, "json")) {
        scope.return_result = data.load_json(file_path.string.value, scope.allocator) catch |err| {
            std.debug.print("ERROR: loading file failed: {}\n", .{err});
            return Error.NotImplemented;
        };
    } else if (std.mem.eql(u8, data_format.string.value, "csv")) {
        scope.return_result = data.load_csv(file_path.string.value, scope.allocator) catch |err| {
            std.debug.print("ERROR: loading file failed: {}\n", .{err});
            return Error.NotImplemented;
        };
    } else return Error.NotImplemented;
}

pub fn map(args: []const Expression, scope: *Scope) Error!void {
    const elements = args[0];
    const callable = args[1];
    std.debug.assert(callable == .function);

    switch (elements) {
        .array => |a| {
            const tmp = try scope.allocator.alloc(Expression, a.elements.len);
            const func = callable.function;
            for (a.elements, tmp) |e, *t| {
                var tmp2 = try scope.allocator.alloc(Expression, 1);
                defer scope.allocator.free(tmp2);
                tmp2[0] = e;
                var tmpScope = try Scope.init(scope.allocator, scope.out, scope, func.args, tmp2);
                for (func.body) |st| {
                    try interpreter.evalStatement(st, &tmpScope);
                }
                if (tmpScope.result()) |r| {
                    t.* = r;
                } else {
                    return Error.ValueNotFound;
                }
            }
            scope.return_result = try expression.Array.init(scope.allocator, tmp);
        },
        else => return Error.NotImplemented,
    }
}

pub fn flatten(args: []const Expression, scope: *Scope) Error!void {
    const lists = args[0];
    switch (lists) {
        .array => |a| {
            const slices = a.elements;
            if (slices.len == 0) {
                const out = try scope.allocator.create(Expression);
                out.* = .{ .array = .{
                    .elements = &[0]Expression{},
                } };
                scope.return_result = out;
            }

            const total_len = blk: {
                var sum: usize = 0;
                for (slices) |slice| sum += if (slice == .array) slice.array.elements.len else 1;
                break :blk sum;
            };

            const buf = try scope.allocator.alloc(Expression, total_len);
            errdefer scope.allocator.free(buf);

            var buffer_index: usize = 0;
            for (slices) |elem| {
                if (elem == .array) {
                    for (elem.array.elements) |e| {
                        buf[buffer_index] = e;
                        buffer_index += 1;
                    }
                } else {
                    buf[buffer_index] = elem;
                    buffer_index += 1;
                }
            }

            // No need for shrink since buf is exactly the correct size.
            const out = try scope.allocator.create(Expression);
            out.* = .{ .array = .{
                .elements = buf,
            } };
            scope.return_result = out;
        },
        else => scope.return_result = try lists.clone(scope.allocator),
    }
}

pub fn flatmap(args: []const Expression, scope: *Scope) Error!void {
    const elements = args[0];
    const callable = args[1];
    std.debug.assert(callable == .function);
    switch (elements) {
        .array => {
            try map(args, scope);
            const map_result = scope.result() orelse unreachable;
            try flatten(&[_]Expression{map_result}, scope);
        },
        else => return Error.NotImplemented,
    }
}

pub fn reduce(args: []const Expression, scope: *Scope) Error!void {
    const elements = args[0];
    const callable = args[1];
    std.debug.assert(callable == .function);
    if (callable.function.args.len != 2) {
        std.debug.print("ERROR: the provided function has {} arguments\n", .{callable.function.args.len});
        std.debug.print("   needed are {}\n", .{2});
        std.process.exit(1);
    }
    const func = callable.function;

    switch (elements) {
        .array => |a| {
            var acc = a.elements[0];
            for (a.elements[1..]) |e| {
                var tmp = try scope.allocator.alloc(Expression, 2);
                tmp[0] = acc;
                tmp[1] = e;
                var tmpScope = try Scope.init(scope.allocator, scope.out, scope, func.args, tmp);
                for (func.body) |st| {
                    try interpreter.evalStatement(st, &tmpScope);
                }
                if (tmpScope.result()) |r| {
                    acc = r;
                } else {
                    return Error.ValueNotFound;
                }
                scope.allocator.free(tmp);
            }
            const out = try scope.allocator.create(Expression);
            out.* = acc;
            scope.return_result = out;
        },
        else => return Error.NotImplemented,
    }
}

pub fn group_by(args: []const Expression, scope: *Scope) Error!void {
    const elements = args[0];
    const callable = args[1];
    std.debug.assert(callable == .function);
    switch (elements) {
        .array => |a| {
            var out_map = std.StringHashMap(std.ArrayList(Expression)).init(scope.allocator);
            // TODO: hard coded slice size. May overfilled by 'callable' if it returns large arrays/dictionaries
            var buffer: [2048]u8 = undefined;
            var fixedStream = std.io.fixedBufferStream(&buffer);
            const writer = fixedStream.writer().any();
            for (a.elements) |elem| {
                fixedStream.reset();
                const tmp: []Expression = try scope.allocator.alloc(Expression, 1);
                tmp[0] = elem;
                var local = try Scope.init(scope.allocator, scope.out, scope, callable.function.args, tmp);
                for (callable.function.body) |st| {
                    try interpreter.evalStatement(st, &local);
                }
                const result = local.result() orelse return Error.ValueNotFound;
                var out_scope = Scope.empty(scope.allocator, writer);
                // NOTE: praying that only simple values are printed
                try interpreter.printValue(result, &out_scope);
                const written: []const u8 = fixedStream.getWritten();
                if (out_map.getPtr(written)) |value| {
                    try value.append(elem);
                } else {
                    var value = std.ArrayList(Expression).init(scope.allocator);
                    try value.append(elem);
                    const key = try scope.allocator.dupe(u8, written);
                    defer scope.allocator.free(written);
                    try out_map.put(key, value);
                }
            }

            var entries = std.ArrayList(expression.DictionaryEntry).init(scope.allocator);
            var iter = out_map.iterator();
            while (iter.next()) |entry| {
                // TODO: We may want to prefer the original value over it's string representation
                const key_str = try scope.allocator.dupe(u8, entry.key_ptr.*);
                const key = try expression.String.init(scope.allocator, key_str);
                const value_entries = try entry.value_ptr.toOwnedSlice();
                const value = try expression.Array.init(scope.allocator, value_entries);
                try entries.append(.{ .key = key, .value = value });
            }
            scope.return_result = try expression.Dictionary.init(scope.allocator, try entries.toOwnedSlice());
        },
        else => |e| {
            std.debug.print("ERROR: unable to elements: '{s}' has no elements or is a single value\n", .{@tagName(e)});
            return Error.InvalidExpressoinType;
        },
    }
}

const Context = struct {
    operation: *const fn (OutType, bool) OutType,
    initial: OutType,

    const OutType = union(enum) {
        number: i64,
        boolean: bool,
    };
};

fn count_op(acc: Context.OutType, value: bool) Context.OutType {
    std.debug.assert(acc == .number);
    return .{ .number = acc.number + @intFromBool(value) };
}
const Count_context: Context = .{
    .operation = &count_op,
    .initial = .{ .number = 0 },
};

fn check_all_op(acc: Context.OutType, value: bool) Context.OutType {
    std.debug.assert(acc == .boolean);
    return .{ .boolean = acc.boolean and value };
}
const All_context: Context = .{
    .operation = &check_all_op,
    .initial = .{ .boolean = true },
};

fn check_any_op(acc: Context.OutType, value: bool) Context.OutType {
    std.debug.assert(acc == .boolean);
    return .{ .boolean = acc.boolean or value };
}
const Any_context: Context = .{
    .operation = &check_any_op,
    .initial = .{ .boolean = false },
};

fn check_none_op(acc: Context.OutType, value: bool) Context.OutType {
    std.debug.assert(acc == .boolean);
    return .{ .boolean = acc.boolean and !value };
}
const None_context: Context = .{
    .operation = &check_none_op,
    .initial = .{ .boolean = true },
};

fn check(context: Context, args: []const Expression, scope: *Scope) Error!void {
    const elements = args[0];
    const callable = args[1];

    std.debug.assert(callable == .function);
    if (callable.function.args.len != 1) {
        std.debug.print("ERROR: the provided function has {} arguments\n", .{callable.function.args.len});
        std.debug.print("   needed are {}\n", .{1});
        std.process.exit(1);
    }
    const func = callable.function;

    switch (elements) {
        .array => |a| {
            var acc: Context.OutType = context.initial;
            for (a.elements) |e| {
                var tmp = try scope.allocator.alloc(Expression, 1);
                tmp[0] = e;
                var tmpScope = try Scope.init(scope.allocator, scope.out, scope, func.args, tmp);
                for (func.body) |st| {
                    try interpreter.evalStatement(st, &tmpScope);
                }
                if (tmpScope.result()) |r| {
                    if (r == .boolean) {
                        acc = context.operation(acc, r.boolean.value);
                    } else if (r != .boolean) {
                        std.debug.print("ERROR: returned value of function is not a boolean\n", .{});
                        return Error.InvalidExpressoinType;
                    }
                } else {
                    return Error.ValueNotFound;
                }
                scope.allocator.free(tmp);
            }
            scope.return_result = switch (acc) {
                .boolean => |v| try expression.Boolean.init(scope.allocator, v),
                .number => |v| try expression.Number.init(scope.allocator, i64, v),
            };
        },
        else => return Error.NotImplemented,
    }
}

pub fn count(args: []const Expression, scope: *Scope) Error!void {
    try check(Count_context, args, scope);
}

pub fn check_all(args: []const Expression, scope: *Scope) Error!void {
    try check(All_context, args, scope);
}

pub fn check_any(args: []const Expression, scope: *Scope) Error!void {
    try check(Any_context, args, scope);
}

pub fn check_none(args: []const Expression, scope: *Scope) Error!void {
    try check(None_context, args, scope);
}

pub fn filter(args: []const Expression, scope: *Scope) Error!void {
    const elements = args[0];
    const callable = args[1];
    std.debug.assert(callable == .function);

    switch (elements) {
        .array => |a| {
            try count(args, scope);
            const element_count = (scope.result() orelse unreachable).number.integer;
            const tmp = try scope.allocator.alloc(Expression, @intCast(element_count));
            var current_index: usize = 0;
            const func = callable.function;
            for (a.elements) |e| {
                var tmp2 = try scope.allocator.alloc(Expression, 1);
                defer scope.allocator.free(tmp2);
                tmp2[0] = e;
                var tmpScope = try Scope.init(scope.allocator, scope.out, scope, func.args, tmp2);
                for (func.body) |st| {
                    try interpreter.evalStatement(st, &tmpScope);
                }
                if (tmpScope.result()) |r| {
                    if (r == .boolean and r.boolean.value) {
                        tmp[current_index] = e;
                        current_index += 1;
                    }
                } else {
                    return Error.ValueNotFound;
                }
            }
            scope.return_result = try expression.Array.init(scope.allocator, tmp);
        },
        else => return Error.NotImplemented,
    }
}

pub fn zip(args: []const Expression, scope: *Scope) Error!void {
    const left_elements = args[0];
    const right_elements = args[1];

    if (left_elements == .array and right_elements == .array) {
        const left = left_elements.array.elements;
        const right = right_elements.array.elements;
        const element_count = if (left.len < right.len) left.len else right.len;
        const tmp = try scope.allocator.alloc(Expression, element_count);
        for (left[0..element_count], right[0..element_count], tmp) |l, r, *t| {
            const out = try scope.allocator.alloc(Expression, 2);
            out[0] = l;
            out[1] = r;
            t.* = .{ .array = expression.Array{ .elements = out } };
        }
        scope.return_result = try expression.Array.init(scope.allocator, tmp);
        return;
    }

    return Error.NotImplemented;
}

fn swap(left: *Expression, right: *Expression) void {
    const tmp = left.*;
    left.* = right.*;
    right.* = tmp;
}

fn partition(elements: []Expression, binary_op: expression.Function, scope: *Scope) Error!usize {
    var pivot = elements.len - 1;
    var left: usize = 0;
    while (left < pivot) {
        var tmp = try scope.allocator.alloc(Expression, 2);
        defer scope.allocator.free(tmp);
        tmp[0] = elements[left];
        tmp[1] = elements[pivot];
        var local = try Scope.init(scope.allocator, scope.out, scope, binary_op.args, tmp);
        for (binary_op.body) |st| {
            // std.debug.print("INFO: in partition current statement type: {s}\n", .{@tagName(st)});
            try interpreter.evalStatement(st, &local);
        }
        const result = local.result() orelse return Error.ValueNotFound;
        if (result == .number and result.number.asFloat() == -1) {
            left += 1;
        } else if (result == .boolean and result.boolean.value) {
            left += 1;
        } else if (result != .number and result != .boolean) {
            return Error.InvalidExpressoinType;
        } else {
            swap(&elements[left], &elements[pivot]);
            if (left != pivot - 1)
                swap(&elements[pivot - 1], &elements[left]);
            pivot -= 1;
        }
    }
    return pivot;
}

fn sort_impl(elements: []Expression, binary_op: expression.Function, scope: *Scope) Error!void {
    if (elements.len < 2) return;
    const partition_point = try partition(elements, binary_op, scope);
    const left: []Expression = elements[0..partition_point];
    const right: []Expression = elements[partition_point + 1 .. elements.len];
    try sort_impl(left, binary_op, scope);
    try sort_impl(right, binary_op, scope);
}

pub fn sort(args: []const Expression, scope: *Scope) Error!void {
    const elements = args[0];
    const callable = args[1];
    std.debug.assert(callable == .function);
    std.debug.assert(callable.function.args.len == 2);

    switch (elements) {
        .array => |a| {
            try sort_impl(a.elements, callable.function, scope);
            scope.return_result = try expression.Array.init(scope.allocator, a.elements);
        },
        else => |e| {
            std.debug.print("ERROR: `sort` is not defined for '{s}'\n", .{@tagName(e)});
            return Error.InvalidExpressoinType;
        },
    }
}

pub fn last(args: []const Expression, scope: *Scope) Error!void {
    const elements = args[0];
    const callback = args[1];
    const default_value = args[2];
    std.debug.assert(callback == .function);

    const func = callback.function;
    switch (elements) {
        .array => |a| {
            var iter = std.mem.reverseIterator(a.elements);
            while (iter.next()) |e| {
                var tmp2 = try scope.allocator.alloc(Expression, 1);
                defer scope.allocator.free(tmp2);
                tmp2[0] = e;
                var tmpScope = try Scope.init(scope.allocator, scope.out, scope, func.args, tmp2);
                for (func.body) |st| {
                    try interpreter.evalStatement(st, &tmpScope);
                }
                if (tmpScope.result()) |r| {
                    if (r == .boolean and r.boolean.value) {
                        scope.return_result = try e.clone(scope.allocator);
                        return;
                    }
                } else {
                    return Error.ValueNotFound;
                }
            }
            scope.return_result = try default_value.clone(scope.allocator);
        },
        else => return Error.NotImplemented,
    }
}

pub fn first(args: []const Expression, scope: *Scope) Error!void {
    const elements = args[0];
    const callback = args[1];
    const default_value = args[2];
    std.debug.assert(callback == .function);

    const func = callback.function;
    switch (elements) {
        .array => |a| {
            for (a.elements) |e| {
                var tmp2 = try scope.allocator.alloc(Expression, 1);
                defer scope.allocator.free(tmp2);
                tmp2[0] = e;
                var tmpScope = try Scope.init(scope.allocator, scope.out, scope, func.args, tmp2);
                for (func.body) |st| {
                    try interpreter.evalStatement(st, &tmpScope);
                }
                if (tmpScope.result()) |r| {
                    if (r == .boolean and r.boolean.value) {
                        scope.return_result = try e.clone(scope.allocator);
                        return;
                    }
                } else {
                    return Error.ValueNotFound;
                }
            }
            scope.return_result = try default_value.clone(scope.allocator);
        },
        else => return Error.NotImplemented,
    }
}

pub fn print3(args: []const Expression, scope: *Scope) Error!void {
    try interpreter.printValue(args[0], scope);
    _ = scope.out.write("\n") catch return Error.IOWrite;
}

pub fn iterator(args: []const Expression, scope: *Scope) Error!void {
    const next_fn = args[0];
    const has_next_fn = args[1];
    const data_local = args[2];

    if (next_fn != .function and has_next_fn != .function) {
        return Error.InvalidExpressoinType;
    }

    scope.return_result = try expression.Iterator.init(
        scope.allocator,
        next_fn.function,
        has_next_fn.function,
        try data_local.clone(scope.allocator),
    );
}

pub fn iter_next(args: []const Expression, scope: *Scope) Error!void {
    _ = scope;
    const iter = args[0];
    std.debug.assert(iter == .iterator);

    switch (iter.iterator.next_fn) {
        else => |f| {
            std.debug.print("ERROR: not implemented case in iter_next: {s}\n", .{@tagName(f)});
            return Error.NotImplemented;
        },
    }
}

pub fn iter_has_next(args: []const Expression, scope: *Scope) Error!void {
    _ = scope;
    const iter = args[0];
    std.debug.assert(iter == .iterator);

    switch (iter.iterator.next_fn) {
        else => |f| {
            std.debug.print("ERROR: not implemented case in iter_next: {s}\n", .{@tagName(f)});
            return Error.NotImplemented;
        },
    }
}
