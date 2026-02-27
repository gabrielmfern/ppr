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

fn promptConfirmation(
    prompt: []const u8,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
) !?bool {
    var input_buffer: [16]u8 = undefined;
    const text = try promptText(prompt, reader, writer, &input_buffer);
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (std.ascii.eqlIgnoreCase(trimmed, "y") or std.ascii.eqlIgnoreCase(trimmed, "yes")) {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "n") or std.ascii.eqlIgnoreCase(trimmed, "no")) {
        return false;
    }
    return null;
}

fn copyTrimmed(input: []const u8, output_buffer: []u8) ![]u8 {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
    if (trimmed.len > output_buffer.len) return error.StreamTooLong;
    @memcpy(output_buffer[0..trimmed.len], trimmed);
    return output_buffer[0..trimmed.len];
}

fn normalizeCommaSeparated(input: []const u8, output_buffer: []u8) ![]u8 {
    var cursor: usize = 0;
    var parts = std.mem.splitScalar(u8, input, ',');

    while (parts.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, &std.ascii.whitespace);
        if (part.len == 0) continue;

        if (cursor != 0) {
            if (cursor >= output_buffer.len) return error.StreamTooLong;
            output_buffer[cursor] = ',';
            cursor += 1;
        }

        if (cursor + part.len > output_buffer.len) return error.StreamTooLong;
        @memcpy(output_buffer[cursor .. cursor + part.len], part);
        cursor += part.len;
    }

    return output_buffer[0..cursor];
}

fn createPullRequest(
    allocator: std.mem.Allocator,
    base: []const u8,
    head_branch: []const u8,
    title: []const u8,
    body_file_path: []const u8,
    reviewers: []const u8,
) !void {
    var argv: [16][]const u8 = undefined;
    var argc: usize = 0;

    argv[argc] = "gh";
    argc += 1;
    argv[argc] = "pr";
    argc += 1;
    argv[argc] = "create";
    argc += 1;
    argv[argc] = "--base";
    argc += 1;
    argv[argc] = base;
    argc += 1;
    argv[argc] = "--head";
    argc += 1;
    argv[argc] = head_branch;
    argc += 1;
    argv[argc] = "--title";
    argc += 1;
    argv[argc] = title;
    argc += 1;
    argv[argc] = "--body-file";
    argc += 1;
    argv[argc] = body_file_path;
    argc += 1;

    if (reviewers.len != 0) {
        argv[argc] = "--reviewer";
        argc += 1;
        argv[argc] = reviewers;
        argc += 1;
    }

    var child = std.process.Child.init(argv[0..argc], allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.PullRequestCreateFailed,
        else => return error.PullRequestCreateFailed,
    }
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
        exitCode: u8,
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

        std.log.debug("[shell] running {s}", .{command});
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
                    .exitCode = marker_parse.exit_code,
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

    var outputBuffer: [32 * 1024]u8 = undefined;

    const ghAuthStatus = try shell.runCommand("gh auth status", &outputBuffer);
    if (ghAuthStatus.exitCode != 0) {
        try writer.print("You might not be logged in with `gh`. Run `gh auth login`\n", .{});
        try writer.flush();
        return error.SafetyCheckFailed;
    }
    std.log.debug("auth status {s}", .{ghAuthStatus.output});

    const baseBranchResult = try shell.runCommand(
        "gh repo view --json defaultBranchRef -q .defaultBranchRef.name",
        &outputBuffer,
    );
    var baseBuffer: [128]u8 = undefined;
    const base = try copyTrimmed(baseBranchResult.output, &baseBuffer);
    if (base.len == 0) {
        try writer.print("Could not determine repository's default branch\n", .{});
        try writer.flush();
        return error.SafetyCheckFailed;
    }
    std.log.debug("base {s}", .{base});

    const headBranchNameResult = try shell.runCommand("git rev-parse --abbrev-ref HEAD", &outputBuffer);
    if (headBranchNameResult.exitCode != 0) {
        try writer.print("Could not determine current git branch\n", .{});
        try writer.flush();
        return error.SafetyCheckFailed;
    }
    var headBranchBuffer: [128]u8 = undefined;
    const headBranch = try copyTrimmed(headBranchNameResult.output, &headBranchBuffer);
    std.log.debug("head branch {s}", .{headBranch});
    if (headBranch.len == 0 or std.mem.eql(u8, headBranch, "HEAD")) {
        try writer.print("HEAD is deatched, which means you're not checked out to a branch\n", .{});
        try writer.flush();
        return error.SafetyCheckFailed;
    }

    if (std.mem.eql(u8, headBranch, base)) {
        try writer.print("Current branch is the same as the default branch. That can't become a pull request.\n", .{});
        try writer.flush();
        return error.SafetyCheckFailed;
    }

    var branchPushedCommandBuffer: [256]u8 = undefined;
    const branchPushedCommand = try std.fmt.bufPrint(
        &branchPushedCommandBuffer,
        "git ls-remote --exit-code --heads origin '{s}' >/dev/null",
        .{headBranch},
    );
    const branchPushedResult = try shell.runCommand(branchPushedCommand, &outputBuffer);
    if (branchPushedResult.exitCode != 0) {
        try writer.print("Current branch is not pushed to origin. Run `git push -u origin {s}` first.\n", .{headBranch});
        try writer.flush();
        return error.SafetyCheckFailed;
    }

    var commitRangeCommandBuffer: [384]u8 = undefined;
    const commitRangeCommand = try std.fmt.bufPrint(
        &commitRangeCommandBuffer,
        "git log --oneline 'origin/{s}..origin/{s}'",
        .{ base, headBranch },
    );
    const commitRangeResult = try shell.runCommand(commitRangeCommand, &outputBuffer);
    if (commitRangeResult.exitCode != 0) return error.SafetyCheckFailed;
    std.log.debug("commit range {s}", .{commitRangeResult.output});
    if (std.mem.trim(u8, commitRangeResult.output, " ").len == 0) {
        try writer.print("There are no commits on origin/{s} that are not in origin/{s}\n", .{ headBranch, base });
        try writer.flush();
        return error.SafetyCheckFailed;
    }

    var existingPrCommandBuffer: [512]u8 = undefined;
    const existingPrCommand = try std.fmt.bufPrint(
        &existingPrCommandBuffer,
        "gh pr list --head '{s}' --base '{s}' --state open --json url --jq '.[0].url // \"\"'",
        .{ headBranch, base },
    );
    const existingPrResult = try shell.runCommand(existingPrCommand, &outputBuffer);
    if (existingPrResult.exitCode != 0) return error.SafetyCheckFailed;
    if (std.mem.trim(u8, existingPrResult.output, "\n").len != 0) {
        std.log.debug("{s}", .{existingPrResult.output});
        try writer.print("An open PR already exists: {s}\n", .{existingPrResult.output});
        try writer.flush();
        return error.SafetyCheckFailed;
    }

    const worktreeStatusResult = try shell.runCommand("git status -sb", &outputBuffer);
    if (!worktreeIsClean(worktreeStatusResult.output)) {
        const continue_anyway = (try promptConfirmation("You have something to commit. Do it anyway? (Y/n)", reader, writer)) orelse true;
        if (!continue_anyway) {
            return;
        }
    }

    var titleBuffer: [512]u8 = undefined;
    const title = try promptText("Title: ", reader, writer, &titleBuffer);
    if (std.mem.trim(u8, title, " ").len == 0) {
        try writer.print("No title given, cancelling pull request\n", .{});
        try writer.flush();
        return;
    }

    var bodyBuffer: [1_048_576]u8 = undefined;
    var body: []u8 = &.{};
    if (try promptConfirmation("Write the body (y/N): ", reader, writer) orelse false) {
        body = try promptEditor(&bodyBuffer);
    }

    const repoResult = try shell.runCommand(
        "gh repo view --json nameWithOwner -q .nameWithOwner",
        &outputBuffer,
    );
    if (repoResult.exitCode != 0) return error.SafetyCheckFailed;
    var repoBuffer: [256]u8 = undefined;
    const repo = try copyTrimmed(repoResult.output, &repoBuffer);

    var collaboratorsCommandBuffer: [512]u8 = undefined;
    const collaboratorsCommand = try std.fmt.bufPrint(
        &collaboratorsCommandBuffer,
        "gh api 'repos/{s}/collaborators' --paginate --jq '.[].login'",
        .{repo},
    );
    const collaboratorsResult = try shell.runCommand(collaboratorsCommand, &outputBuffer);
    if (collaboratorsResult.exitCode == 0 and std.mem.trim(u8, collaboratorsResult.output, &std.ascii.whitespace).len != 0) {
        try writer.print("Available user reviewers:\n{s}\n", .{std.mem.trimRight(u8, collaboratorsResult.output, &std.ascii.whitespace)});
        try writer.flush();
    }

    var teamsCommandBuffer: [512]u8 = undefined;
    const teamsCommand = try std.fmt.bufPrint(
        &teamsCommandBuffer,
        "gh api 'repos/{s}/teams' --paginate --jq '.[] | .organization.login + \"/\" + .slug'",
        .{repo},
    );
    const teamsResult = try shell.runCommand(teamsCommand, &outputBuffer);
    if (teamsResult.exitCode == 0 and std.mem.trim(u8, teamsResult.output, &std.ascii.whitespace).len != 0) {
        try writer.print("Available team reviewers:\n{s}\n", .{std.mem.trimRight(u8, teamsResult.output, &std.ascii.whitespace)});
        try writer.flush();
    }

    var reviewerInputBuffer: [2048]u8 = undefined;
    const reviewersInput = try promptText("Reviewers (comma-separated, optional): ", reader, writer, &reviewerInputBuffer);
    var reviewersBuffer: [2048]u8 = undefined;
    const reviewers = try normalizeCommaSeparated(reviewersInput, &reviewersBuffer);

    var bodyFilePathBuffer: [128]u8 = undefined;
    const bodyFilePath = try createTempEditorFile(&bodyFilePathBuffer);
    defer std.fs.deleteFileAbsolute(bodyFilePath) catch {};
    var bodyFile = try std.fs.createFileAbsolute(bodyFilePath, .{});
    defer bodyFile.close();
    try bodyFile.writeAll(body);

    try createPullRequest(allocator, base, headBranch, title, bodyFilePath, reviewers);
}

test "Shell keeps child shell alive between commands" {
    var shell = try Shell.init(std.testing.allocator);
    defer shell.deinit();

    var first_output_buffer: [64]u8 = undefined;
    const first = try shell.runCommand("keep_alive_var=42", &first_output_buffer);
    try std.testing.expectEqual(@as(u8, 0), first.exitCode);
    try std.testing.expectEqualStrings("", first.output);

    var second_output_buffer: [64]u8 = undefined;
    const second = try shell.runCommand("echo \"$keep_alive_var\"", &second_output_buffer);
    try std.testing.expectEqual(@as(u8, 0), second.exitCode);
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

test "promptConfirmation accepts yes" {
    var reader = std.Io.Reader.fixed("YeS\n");
    var output_storage: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_storage);

    const accepted = try promptConfirmation("Continue? (y/N): ", &reader, &writer);
    try std.testing.expect(accepted == true);
    try std.testing.expectEqualStrings("Continue? (y/N): ", writer.buffered());
}

test "promptConfirmation null on empty input" {
    var reader = std.Io.Reader.fixed("\n");
    var output_storage: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_storage);

    const accepted = try promptConfirmation("Continue? (y/N): ", &reader, &writer);
    try std.testing.expect(accepted == null);
    try std.testing.expectEqualStrings("Continue? (y/N): ", writer.buffered());
}

test "promptConfirmation returns null for invalid answer" {
    var reader = std.Io.Reader.fixed("maybe\n");
    var output_storage: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_storage);

    const accepted = try promptConfirmation("Continue? (y/N): ", &reader, &writer);
    try std.testing.expect(accepted == null);
    try std.testing.expectEqualStrings("Continue? (y/N): ", writer.buffered());
}

test "worktreeIsClean returns true when status has only branch line" {
    try std.testing.expect(worktreeIsClean("## main...origin/main\n"));
}

test "worktreeIsClean returns false when status has file changes" {
    try std.testing.expect(!worktreeIsClean("## main...origin/main\n M src/main.zig\n"));
}

test "normalizeCommaSeparated trims values and drops empties" {
    var out: [64]u8 = undefined;
    const normalized = try normalizeCommaSeparated(" alice, bob ,,org/team ", &out);
    try std.testing.expectEqualStrings("alice,bob,org/team", normalized);
}
