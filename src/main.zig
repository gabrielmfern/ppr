const std = @import("std");
const builtin = @import("builtin");

fn promptText(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
) ![]u8 {
    try writer.writeAll(prompt);
    try writer.flush();

    var collecting: std.Io.Writer.Allocating = .init(allocator);
    defer collecting.deinit();

    _ = reader.streamDelimiterEnding(&collecting.writer, '\n') catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.WriteFailed => return error.OutOfMemory,
    };

    if (reader.bufferedLen() > 0 and reader.buffered()[0] == '\n') {
        reader.toss(1);
    } else if (collecting.written().len == 0) {
        return error.EndOfStream;
    }

    return collecting.toOwnedSlice();
}

const GitHub = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    stdout_buffer: std.ArrayList(u8),
    next_marker_id: u64,
    closed: bool,

    const CommandResult = struct {
        output: []u8,
        exit_code: u8,

        pub fn deinit(self: *CommandResult, allocator: std.mem.Allocator) void {
            allocator.free(self.output);
            self.* = undefined;
        }
    };

    const MarkerParse = struct {
        marker_start: usize,
        consumed_end: usize,
        exit_code: u8,
    };

    pub fn init(allocator: std.mem.Allocator) !GitHub {
        if (builtin.os.tag == .windows) return error.UnsupportedOperatingSystem;

        var child = std.process.Child.init(&.{ "/bin/sh" }, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;
        try child.spawn();

        return .{
            .allocator = allocator,
            .child = child,
            .stdout_buffer = .empty,
            .next_marker_id = 0,
            .closed = false,
        };
    }

    pub fn deinit(self: *GitHub) void {
        if (!self.closed) {
            if (self.child.stdin) |*stdin| {
                stdin.writeAll("exit\n") catch {};
                stdin.close();
                self.child.stdin = null;
            }
            _ = self.child.wait() catch {};
            self.closed = true;
        }

        self.stdout_buffer.deinit(self.allocator);
    }

    pub fn runCommand(self: *GitHub, command: []const u8) !CommandResult {
        if (self.closed) return error.ProcessAlreadyClosed;

        self.next_marker_id += 1;
        const marker = try std.fmt.allocPrint(self.allocator, "__PPR_DONE_{d}__", .{self.next_marker_id});
        defer self.allocator.free(marker);

        try self.writeCommand(command, marker);

        var chunk: [1024]u8 = undefined;

        while (true) {
            if (findMarker(self.stdout_buffer.items, marker)) |marker_parse| {
                const output = try self.allocator.dupe(u8, self.stdout_buffer.items[0..marker_parse.marker_start]);
                self.consumeStdout(marker_parse.consumed_end);
                return .{
                    .output = output,
                    .exit_code = marker_parse.exit_code,
                };
            }

            const n = try self.child.stdout.?.read(&chunk);
            if (n == 0) return error.UnexpectedEndOfStream;
            try self.stdout_buffer.appendSlice(self.allocator, chunk[0..n]);
        }
    }

    fn writeCommand(self: *GitHub, command: []const u8, marker: []const u8) !void {
        try self.child.stdin.?.writeAll(command);
        if (command.len == 0 or command[command.len - 1] != '\n') {
            try self.child.stdin.?.writeAll("\n");
        }

        const marker_command = try std.fmt.allocPrint(
            self.allocator,
            "printf '{s}:%d\\n' $?\n",
            .{marker},
        );
        defer self.allocator.free(marker_command);
        try self.child.stdin.?.writeAll(marker_command);
    }

    fn consumeStdout(self: *GitHub, consumed: usize) void {
        if (consumed == 0) return;
        const remaining = self.stdout_buffer.items.len - consumed;
        std.mem.copyForwards(u8, self.stdout_buffer.items[0..remaining], self.stdout_buffer.items[consumed..]);
        self.stdout_buffer.items.len = remaining;
    }

    fn findMarker(buffer: []const u8, marker: []const u8) ?MarkerParse {
        var search_from: usize = 0;

        while (std.mem.indexOfPos(u8, buffer, search_from, marker)) |marker_start| {
            const status_start = marker_start + marker.len;
            if (status_start >= buffer.len) return null;
            if (buffer[status_start] != ':') {
                search_from = marker_start + 1;
                continue;
            }

            var status_end = status_start + 1;
            while (status_end < buffer.len and std.ascii.isDigit(buffer[status_end])) : (status_end += 1) {}

            if (status_end == status_start + 1) {
                search_from = marker_start + 1;
                continue;
            }
            if (status_end >= buffer.len) return null;
            if (buffer[status_end] != '\n') {
                search_from = marker_start + 1;
                continue;
            }

            const exit_code = std.fmt.parseInt(u8, buffer[(status_start + 1)..status_end], 10) catch {
                search_from = marker_start + 1;
                continue;
            };

            return .{
                .marker_start = marker_start,
                .consumed_end = status_end + 1,
                .exit_code = exit_code,
            };
        }

        return null;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        std.log.err("Memory leak detected\n", .{});
    };

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdin_buffer: [1024]u8 = undefined;
    var stdout_buffer: [1024]u8 = undefined;
    var stdin = std.fs.File.stdin().reader(&stdin_buffer);
    var stdout = std.fs.File.stdout().writer(&stdout_buffer);

    const title = try promptText(allocator, "Title: ", &stdin.interface, &stdout.interface);
    std.log.info("title: {s}", .{title});
}

test "GitHub keeps child shell alive between commands" {
    var github = try GitHub.init(std.testing.allocator);
    defer github.deinit();

    var first = try github.runCommand("keep_alive_var=42");
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), first.exit_code);
    try std.testing.expectEqualStrings("", first.output);

    var second = try github.runCommand("echo \"$keep_alive_var\"");
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), second.exit_code);
    try std.testing.expectEqualStrings("42\n", second.output);
}

test "promptText reads one line and writes prompt" {
    var reader = std.Io.Reader.fixed("octocat\nextra");
    var output_storage: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_storage);

    const text = try promptText(std.testing.allocator, "GitHub username: ", &reader, &writer);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("GitHub username: ", writer.buffered());
    try std.testing.expectEqualStrings("octocat", text);
}

test "promptText returns EndOfStream when no input is available" {
    var reader = std.Io.Reader.fixed("");
    var output_storage: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_storage);

    try std.testing.expectError(
        error.EndOfStream,
        promptText(std.testing.allocator, "> ", &reader, &writer),
    );
    try std.testing.expectEqualStrings("> ", writer.buffered());
}
