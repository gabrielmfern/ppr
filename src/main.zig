const std = @import("std");
const builtin = @import("builtin");

fn promptText(
    prompt: []const u8,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    output_buffer: []u8,
) ![]u8 {
    try writer.writeAll(prompt);
    try writer.flush();

    var collecting = std.Io.Writer.fixed(output_buffer);
    _ = reader.streamDelimiterEnding(&collecting, '\n') catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.WriteFailed => return error.StreamTooLong,
    };

    if (reader.bufferedLen() > 0 and reader.buffered()[0] == '\n') {
        reader.toss(1);
    } else if (collecting.buffered().len == 0) {
        return error.EndOfStream;
    }

    return collecting.buffered();
}

fn promptYesNo(
    prompt: []const u8,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
) !bool {
    var input_buffer: [16]u8 = undefined;
    const text = try promptText(prompt, reader, writer, &input_buffer);
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    return std.ascii.eqlIgnoreCase(trimmed, "y") or std.ascii.eqlIgnoreCase(trimmed, "yes");
}

fn copyTrimmed(input: []const u8, output_buffer: []u8) ![]u8 {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
    if (trimmed.len > output_buffer.len) return error.StreamTooLong;
    @memcpy(output_buffer[0..trimmed.len], trimmed);
    return output_buffer[0..trimmed.len];
}

fn worktreeIsClean(status_sb_output: []const u8) bool {
    var lines = std.mem.tokenizeScalar(u8, status_sb_output, '\n');
    _ = lines.next() orelse return false;
    return lines.next() == null;
}

fn promptEditor(text_buffer: []u8) ![]u8 {
    return promptEditorWithScript("${EDITOR:-vi} \"$1\"", text_buffer);
}

fn promptEditorWithScript(script: []const u8, text_buffer: []u8) ![]u8 {
    if (builtin.os.tag == .windows) return error.UnsupportedOperatingSystem;

    var path_storage: [128]u8 = undefined;
    const temp_path = try createTempEditorFile(&path_storage);
    defer std.fs.deleteFileAbsolute(temp_path) catch {};

    var child = std.process.Child.init(
        &.{ "/bin/sh", "-c", script, "ppr-editor", temp_path },
        std.heap.page_allocator,
    );
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.EditorFailed,
        else => return error.EditorFailed,
    }

    var file = try std.fs.openFileAbsolute(temp_path, .{});
    defer file.close();

    const n = try file.readAll(text_buffer);
    var extra: [1]u8 = undefined;
    if (try file.read(&extra) != 0) return error.StreamTooLong;
    return text_buffer[0..n];
}

fn createTempEditorFile(path_storage: []u8) ![]u8 {
    for (0..32) |_| {
        const random_suffix = std.crypto.random.int(u64);
        const temp_path = try std.fmt.bufPrint(path_storage, "/tmp/ppr-editor-{x}.md", .{random_suffix});

        const file = std.fs.createFileAbsolute(temp_path, .{
            .read = true,
            .exclusive = true,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        file.close();
        return temp_path;
    }
    return error.UnableToCreateTempFile;
}

const Shell = struct {
    child: std.process.Child,
    stdout_buffer: [stdout_buffer_size]u8,
    stdout_len: usize,
    next_marker_id: u64,
    closed: bool,

    const stdout_buffer_size = 16 * 1024;
    const marker_buffer_size = 64;
    const marker_command_buffer_size = 256;

    const CommandResult = struct {
        output: []u8,
        exit_code: u8,
    };

    const MarkerParse = struct {
        marker_start: usize,
        consumed_end: usize,
        exit_code: u8,
    };

    pub fn init(allocator: std.mem.Allocator) !Shell {
        if (builtin.os.tag == .windows) return error.UnsupportedOperatingSystem;

        var child = std.process.Child.init(&.{"/bin/sh"}, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;
        try child.spawn();

        return .{
            .child = child,
            .stdout_buffer = undefined,
            .stdout_len = 0,
            .next_marker_id = 0,
            .closed = false,
        };
    }

    pub fn deinit(self: *Shell) void {
        if (!self.closed) {
            if (self.child.stdin) |*stdin| {
                stdin.writeAll("exit\n") catch {};
                stdin.close();
                self.child.stdin = null;
            }
            _ = self.child.wait() catch {};
            self.closed = true;
        }
    }

    pub fn runCommand(self: *Shell, command: []const u8, output_buffer: []u8) !CommandResult {
        if (self.closed) return error.ProcessAlreadyClosed;

        self.next_marker_id += 1;
        var marker_storage: [marker_buffer_size]u8 = undefined;
        const marker = try std.fmt.bufPrint(&marker_storage, "__PPR_DONE_{d}__", .{self.next_marker_id});

        try self.writeCommand(command, marker);

        var chunk: [1024]u8 = undefined;

        while (true) {
            if (findMarker(self.stdout_buffer[0..self.stdout_len], marker)) |marker_parse| {
                const output = self.stdout_buffer[0..marker_parse.marker_start];
                if (output.len > output_buffer.len) return error.OutputBufferTooSmall;
                @memcpy(output_buffer[0..output.len], output);
                self.consumeStdout(marker_parse.consumed_end);
                return .{
                    .output = output_buffer[0..output.len],
                    .exit_code = marker_parse.exit_code,
                };
            }

            const n = try self.child.stdout.?.read(&chunk);
            if (n == 0) return error.UnexpectedEndOfStream;
            try self.appendStdout(chunk[0..n]);
        }
    }

    fn writeCommand(self: *Shell, command: []const u8, marker: []const u8) !void {
        try self.child.stdin.?.writeAll(command);
        if (command.len == 0 or command[command.len - 1] != '\n') {
            try self.child.stdin.?.writeAll("\n");
        }

        var marker_command_storage: [marker_command_buffer_size]u8 = undefined;
        const marker_command = try std.fmt.bufPrint(
            &marker_command_storage,
            "printf '{s}:%d\\n' $?\n",
            .{marker},
        );
        try self.child.stdin.?.writeAll(marker_command);
    }

    fn appendStdout(self: *Shell, bytes: []const u8) !void {
        const next_len = self.stdout_len + bytes.len;
        if (next_len > self.stdout_buffer.len) return error.StreamTooLong;
        @memcpy(self.stdout_buffer[self.stdout_len..next_len], bytes);
        self.stdout_len = next_len;
    }

    fn consumeStdout(self: *Shell, consumed: usize) void {
        if (consumed == 0) return;
        const remaining = self.stdout_len - consumed;
        std.mem.copyForwards(u8, self.stdout_buffer[0..remaining], self.stdout_buffer[consumed..self.stdout_len]);
        self.stdout_len = remaining;
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

fn runCommandExpectSuccess(
    shell: *Shell,
    command: []const u8,
    output_buffer: []u8,
    check_name: []const u8,
) !Shell.CommandResult {
    const result = try shell.runCommand(command, output_buffer);
    if (result.exit_code != 0) {
        std.log.err("Safety check failed: {s} (exit code {d})", .{ check_name, result.exit_code });
        const err_output = std.mem.trim(u8, result.output, &std.ascii.whitespace);
        if (err_output.len != 0) {
            std.log.err("{s}", .{err_output});
        }
        return error.SafetyCheckFailed;
    }
    return result;
}

fn runSafetyChecks(shell: *Shell, writer: *std.Io.Writer) !void {
    var output_buffer: [32 * 1024]u8 = undefined;

    _ = try runCommandExpectSuccess(
        shell,
        "gh auth status",
        &output_buffer,
        "gh auth status",
    );

    const base_result = try runCommandExpectSuccess(
        shell,
        "gh repo view --json defaultBranchRef -q .defaultBranchRef.name",
        &output_buffer,
        "gh repo view --json defaultBranchRef",
    );
    var base_storage: [128]u8 = undefined;
    const base = try copyTrimmed(base_result.output, &base_storage);
    if (base.len == 0) return error.SafetyCheckFailed;

    const branch_result = try runCommandExpectSuccess(
        shell,
        "git rev-parse --abbrev-ref HEAD",
        &output_buffer,
        "git rev-parse --abbrev-ref HEAD",
    );
    var branch_storage: [128]u8 = undefined;
    const branch = try copyTrimmed(branch_result.output, &branch_storage);
    if (branch.len == 0 or std.mem.eql(u8, branch, "HEAD")) return error.DetachedHead;

    const status_result = try runCommandExpectSuccess(
        shell,
        "git status -sb",
        &output_buffer,
        "git status -sb",
    );
    if (!worktreeIsClean(status_result.output)) return error.WorktreeNotClean;

    var existing_pr_cmd_storage: [512]u8 = undefined;
    const existing_pr_cmd = try std.fmt.bufPrint(
        &existing_pr_cmd_storage,
        "gh pr list --head '{s}' --base '{s}' --state open --json url --jq '.[0].url // \"\"'",
        .{ branch, base },
    );
    const existing_pr_result = try runCommandExpectSuccess(
        shell,
        existing_pr_cmd,
        &output_buffer,
        "gh pr list --head <branch> --base <base> --state open",
    );
    var existing_pr_storage: [512]u8 = undefined;
    const existing_pr_url = try copyTrimmed(existing_pr_result.output, &existing_pr_storage);
    if (existing_pr_url.len != 0) {
        try writer.print("An open PR already exists: {s}\n", .{existing_pr_url});
        try writer.flush();
        return error.OpenPullRequestAlreadyExists;
    }

    var commit_range_cmd_storage: [256]u8 = undefined;
    const commit_range_cmd = try std.fmt.bufPrint(
        &commit_range_cmd_storage,
        "git log --oneline 'origin/{s}..HEAD'",
        .{base},
    );
    const commit_range_result = try runCommandExpectSuccess(
        shell,
        commit_range_cmd,
        &output_buffer,
        "git log --oneline origin/<base>..HEAD",
    );
    if (std.mem.trim(u8, commit_range_result.output, &std.ascii.whitespace).len == 0) {
        return error.NoCommitsToPullRequest;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        std.log.err("Memory leak detected", .{});
    };

    const allocator = gpa.allocator();

    var shell = try Shell.init(allocator);
    defer shell.deinit();

    var stdin_buffer: [1024]u8 = undefined;
    var stdout_buffer: [1024]u8 = undefined;
    var stdin = std.fs.File.stdin().reader(&stdin_buffer);
    var stdout = std.fs.File.stdout().writer(&stdout_buffer);

    const reader = &stdin.interface;
    const writer = &stdout.interface;

    try runSafetyChecks(&shell, writer);

    var titleBuffer: [512]u8 = undefined;
    const title = try promptText("Title: ", reader, writer, &titleBuffer);
    if (std.mem.trim(u8, title, " ").len == 0) {
        std.debug.print("Title is empty, exiting\n", .{});
        return;
    }

    const willWriteBody = try promptYesNo("Write the body (y/N): ", reader, writer);
    var bodyBuffer: [1_048_576]u8 = undefined;
    var body: []u8 = &.{};
    if (willWriteBody) {
        body = try promptEditor(&bodyBuffer);
    }
}

test "Shell keeps child shell alive between commands" {
    var shell = try Shell.init(std.testing.allocator);
    defer shell.deinit();

    var first_output_buffer: [64]u8 = undefined;
    const first = try shell.runCommand("keep_alive_var=42", &first_output_buffer);
    try std.testing.expectEqual(@as(u8, 0), first.exit_code);
    try std.testing.expectEqualStrings("", first.output);

    var second_output_buffer: [64]u8 = undefined;
    const second = try shell.runCommand("echo \"$keep_alive_var\"", &second_output_buffer);
    try std.testing.expectEqual(@as(u8, 0), second.exit_code);
    try std.testing.expectEqualStrings("42\n", second.output);
}

test "promptText reads one line and writes prompt" {
    var reader = std.Io.Reader.fixed("octocat\nextra");
    var output_storage: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_storage);
    var input_storage: [32]u8 = undefined;

    const text = try promptText("GitHub username: ", &reader, &writer, &input_storage);

    try std.testing.expectEqualStrings("GitHub username: ", writer.buffered());
    try std.testing.expectEqualStrings("octocat", text);
}

test "promptText returns EndOfStream when no input is available" {
    var reader = std.Io.Reader.fixed("");
    var output_storage: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_storage);
    var input_storage: [32]u8 = undefined;

    try std.testing.expectError(
        error.EndOfStream,
        promptText("> ", &reader, &writer, &input_storage),
    );
    try std.testing.expectEqualStrings("> ", writer.buffered());
}

test "promptText returns StreamTooLong when input exceeds fixed buffer" {
    var reader = std.Io.Reader.fixed("this-input-is-too-long\n");
    var output_storage: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_storage);
    var input_storage: [4]u8 = undefined;

    try std.testing.expectError(
        error.StreamTooLong,
        promptText("Title: ", &reader, &writer, &input_storage),
    );
}

test "promptEditor reads text written by editor" {
    var text_buffer: [64]u8 = undefined;
    const text = try promptEditorWithScript("printf 'body from editor' > \"$1\"", &text_buffer);
    try std.testing.expectEqualStrings("body from editor", text);
}

test "promptEditor returns StreamTooLong for oversized text" {
    var text_buffer: [4]u8 = undefined;
    try std.testing.expectError(
        error.StreamTooLong,
        promptEditorWithScript("printf 'abcdef' > \"$1\"", &text_buffer),
    );
}

test "promptEditor returns EditorFailed on non-zero exit" {
    var text_buffer: [32]u8 = undefined;
    try std.testing.expectError(
        error.EditorFailed,
        promptEditorWithScript("exit 2", &text_buffer),
    );
}

test "promptYesNo accepts yes" {
    var reader = std.Io.Reader.fixed("YeS\n");
    var output_storage: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_storage);

    const accepted = try promptYesNo("Continue? (y/N): ", &reader, &writer);
    try std.testing.expect(accepted);
    try std.testing.expectEqualStrings("Continue? (y/N): ", writer.buffered());
}

test "promptYesNo defaults to no on empty input" {
    var reader = std.Io.Reader.fixed("\n");
    var output_storage: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_storage);

    const accepted = try promptYesNo("Continue? (y/N): ", &reader, &writer);
    try std.testing.expect(!accepted);
    try std.testing.expectEqualStrings("Continue? (y/N): ", writer.buffered());
}

test "promptYesNo returns false for invalid answer" {
    var reader = std.Io.Reader.fixed("maybe\n");
    var output_storage: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_storage);

    const accepted = try promptYesNo("Continue? (y/N): ", &reader, &writer);
    try std.testing.expect(!accepted);
    try std.testing.expectEqualStrings("Continue? (y/N): ", writer.buffered());
}

test "copyTrimmed trims and copies into fixed buffer" {
    var out: [16]u8 = undefined;
    const copied = try copyTrimmed("  abc \n", &out);
    try std.testing.expectEqualStrings("abc", copied);
}

test "worktreeIsClean returns true when status has only branch line" {
    try std.testing.expect(worktreeIsClean("## main...origin/main\n"));
}

test "worktreeIsClean returns false when status has file changes" {
    try std.testing.expect(!worktreeIsClean("## main...origin/main\n M src/main.zig\n"));
}
