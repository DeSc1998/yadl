const std = @import("std");
const Parser = @import("parser.zig");
const stmt = @import("statement.zig");
const interpreter = @import("interpreter.zig");
const stdlib = @import("stdlib.zig");

const Scope = @import("scope.zig");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

fn readFile(alloc: std.mem.Allocator, filepath: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(filepath, .{});
    defer file.close();
    const stat = try file.stat();
    const contents = try file.readToEndAlloc(alloc, stat.size);
    return contents;
}

pub fn main() !void {
    defer arena.deinit();

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    var args = try std.process.argsWithAllocator(allocator);
    _ = args.next() orelse unreachable; // program name

    while (args.next()) |filepath| {
        const input = readFile(allocator, filepath) catch |err| {
            try stdout.print("ERROR: reading file '{s}' failed: {}\n", .{ filepath, err });
            continue;
        };

        var parser = Parser.init(input, allocator);

        const stmts = parser.parse() catch |err| {
            if (err == Parser.Error.EndOfFile) {
                try stdout.print("ERROR: unexpected end of file\n", .{});
            }
            return err;
        };

        var scope = Scope.empty(allocator, stdout.any());
        // std.debug.print("INFO: memory usage (byte): {}\n", .{arena.queryCapacity()});

        for (stmts) |st| {
            interpreter.evalStatement(st, &scope) catch |err| {
                try bw.flush();
                return err;
            };
            // std.debug.print("INFO: memory usage (byte): {\n", .{arena.queryCapacity()});
        }
        try bw.flush();

        if (!arena.reset(.retain_capacity)) {
            for (stmts) |st| {
                stmt.free(allocator, st);
            }
            allocator.free(stmts);
        }
    }
}
