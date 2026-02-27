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

const Config = struct {
    name_storage: [max_name_len]u8,
    name_len: usize,
    path_storage: [max_path_len]u8,
    path_len: usize,
    entries: [max_entries]Entry,
    entries_len: usize,
    created: bool,

    const max_name_len = 64;
    const max_path_len = 1024;
    const max_entries = 256;
    const max_handle_len = 128;
    const max_file_size = 64 * 1024;

    const Entry = struct {
        github_storage: [max_handle_len]u8,
        github_len: usize,
        slack_storage: [max_handle_len]u8,
        slack_len: usize,

        fn github(self: *const Entry) []const u8 {
            return self.github_storage[0..self.github_len];
        }

        fn slack(self: *const Entry) []const u8 {
            return self.slack_storage[0..self.slack_len];
        }
    };

    pub fn init(
        name: []const u8,
        github_reviewers: []const u8,
    ) !Config {
        if (builtin.os.tag == .windows) return error.UnsupportedOperatingSystem;
        const home = std.posix.getenv("HOME") orelse return error.EnvironmentVariableNotFound;
        return initWithHome(name, home, github_reviewers);
    }

    fn initWithHome(
        name: []const u8,
        home: []const u8,
        github_reviewers: []const u8,
    ) !Config {
        var config_dir_storage: [max_path_len]u8 = undefined;
        const config_dir = try std.fmt.bufPrint(&config_dir_storage, "{s}/.config", .{home});

        std.fs.makeDirAbsolute(config_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var config = Config{
            .name_storage = undefined,
            .name_len = 0,
            .path_storage = undefined,
            .path_len = 0,
            .entries = undefined,
            .entries_len = 0,
            .created = false,
        };

        config.name_len = try copyInto(config.name_storage[0..], name);
        const config_path = try std.fmt.bufPrint(&config.path_storage, "{s}/{s}.json", .{ config_dir, name });
        config.path_len = config_path.len;

        const exists = blk: {
            std.fs.accessAbsolute(config.path(), .{}) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => return err,
            };
            break :blk true;
        };

        if (exists) {
            try config.load();
        } else {
            config.created = true;
            try config.seedDefaults(github_reviewers);
            try config.save();
        }

        return config;
    }

    pub fn deinit(self: *Config) void {
        _ = self;
    }

    pub fn path(self: *const Config) []const u8 {
        return self.path_storage[0..self.path_len];
    }

    pub fn getSlackHandle(self: *const Config, github_handle: []const u8) ?[]const u8 {
        for (self.entries[0..self.entries_len]) |*entry| {
            if (std.mem.eql(u8, entry.github(), github_handle)) {
                return entry.slack();
            }
        }
        return null;
    }

    fn copyInto(storage: []u8, value: []const u8) !usize {
        if (value.len > storage.len) return error.StreamTooLong;
        @memcpy(storage[0..value.len], value);
        return value.len;
    }

    fn putMapping(self: *Config, github_handle: []const u8, slack_handle: []const u8) !void {
        if (github_handle.len == 0 or slack_handle.len == 0) return;
        if (self.getSlackHandle(github_handle) != null) return;
        if (self.entries_len >= max_entries) return error.StreamTooLong;

        var entry = &self.entries[self.entries_len];
        entry.github_len = try copyInto(entry.github_storage[0..], github_handle);
        entry.slack_len = try copyInto(entry.slack_storage[0..], slack_handle);
        self.entries_len += 1;
    }

    fn seedDefaults(self: *Config, github_reviewers: []const u8) !void {
        var lines = std.mem.splitScalar(u8, github_reviewers, '\n');
        while (lines.next()) |line_raw| {
            const handle = std.mem.trim(u8, line_raw, &std.ascii.whitespace);
            if (handle.len == 0) continue;
            try self.putMapping(handle, handle);
        }
    }

    fn load(self: *Config) !void {
        self.entries_len = 0;

        var file = try std.fs.openFileAbsolute(self.path(), .{});
        defer file.close();

        var json_text_buffer: [max_file_size]u8 = undefined;
        const n = try file.readAll(&json_text_buffer);
        var extra: [1]u8 = undefined;
        if (try file.read(&extra) != 0) return error.StreamTooLong;
        const json_text = json_text_buffer[0..n];

        const trimmed = std.mem.trim(u8, json_text, &std.ascii.whitespace);
        if (trimmed.len == 0) return;

        try self.parseJsonMap(trimmed);
    }

    fn save(self: *const Config) !void {
        var file = try std.fs.createFileAbsolute(self.path(), .{
            .truncate = true,
        });
        defer file.close();

        var write_buffer: [4096]u8 = undefined;
        var file_writer = file.writer(&write_buffer);
        const writer = &file_writer.interface;

        try writer.writeAll("{");
        for (self.entries[0..self.entries_len], 0..) |*entry, i| {
            if (i == 0) {
                try writer.writeAll("\n");
            } else {
                try writer.writeAll(",\n");
            }
            try writer.writeAll("  ");
            try writeJsonString(writer, entry.github());
            try writer.writeAll(": ");
            try writeJsonString(writer, entry.slack());
        }
        if (self.entries_len != 0) {
            try writer.writeAll("\n");
        }
        try writer.writeAll("}\n");
        try file_writer.interface.flush();
    }

    fn skipWhitespace(json_text: []const u8, index: *usize) void {
        while (index.* < json_text.len and std.ascii.isWhitespace(json_text[index.*])) : (index.* += 1) {}
    }

    fn parseJsonString(json_text: []const u8, index: *usize) ![]const u8 {
        if (index.* >= json_text.len or json_text[index.*] != '"') return error.InvalidConfig;
        index.* += 1;
        const start = index.*;

        while (index.* < json_text.len) : (index.* += 1) {
            const ch = json_text[index.*];
            if (ch == '"') {
                const value = json_text[start..index.*];
                index.* += 1;
                return value;
            }
            if (ch == '\\' or ch < 0x20) return error.InvalidConfig;
        }

        return error.InvalidConfig;
    }

    fn parseJsonMap(self: *Config, json_text: []const u8) !void {
        var index: usize = 0;
        skipWhitespace(json_text, &index);
        if (index >= json_text.len or json_text[index] != '{') return error.InvalidConfig;
        index += 1;

        skipWhitespace(json_text, &index);
        if (index < json_text.len and json_text[index] == '}') {
            index += 1;
            skipWhitespace(json_text, &index);
            if (index != json_text.len) return error.InvalidConfig;
            return;
        }

        while (true) {
            const github_handle = try parseJsonString(json_text, &index);
            skipWhitespace(json_text, &index);
            if (index >= json_text.len or json_text[index] != ':') return error.InvalidConfig;
            index += 1;
            skipWhitespace(json_text, &index);
            const slack_handle = try parseJsonString(json_text, &index);
            try self.putMapping(github_handle, slack_handle);
            skipWhitespace(json_text, &index);
            if (index >= json_text.len) return error.InvalidConfig;

            const ch = json_text[index];
            if (ch == ',') {
                index += 1;
                skipWhitespace(json_text, &index);
                continue;
            }
            if (ch == '}') {
                index += 1;
                break;
            }
            return error.InvalidConfig;
        }

        skipWhitespace(json_text, &index);
        if (index != json_text.len) return error.InvalidConfig;
    }

    fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
        try writer.writeAll("\"");
        for (value) |ch| {
            switch (ch) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => {
                    if (ch < 0x20) return error.InvalidConfig;
                    try writer.writeByte(ch);
                },
            }
        }
        try writer.writeAll("\"");
    }
};

fn worktreeIsClean(status_sb_output: []const u8) bool {
    var lines = std.mem.tokenizeScalar(u8, status_sb_output, '\n');
    _ = lines.next() orelse return false;
    return lines.next() == null;
}

fn promptEditor(path_buffer: []u8) ![]u8 {
    return promptEditorWithScript("${EDITOR:-vi} \"$1\"", path_buffer);
}

fn promptEditorWithScript(script: []const u8, path_buffer: []u8) ![]u8 {
    if (builtin.os.tag == .windows) return error.UnsupportedOperatingSystem;

    var path_storage: [128]u8 = undefined;
    const temp_path = try createTempEditorFile(&path_storage);
    errdefer std.fs.deleteFileAbsolute(temp_path) catch {};

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

    if (temp_path.len > path_buffer.len) return error.StreamTooLong;
    @memcpy(path_buffer[0..temp_path.len], temp_path);
    return path_buffer[0..temp_path.len];
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
    const command_buffer_size = 8192;

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

    pub fn runCommand(
        self: *Shell,
        output_buffer: []u8,
        comptime command_fmt: []const u8,
        args: anytype,
    ) !CommandResult {
        if (self.closed) return error.ProcessAlreadyClosed;

        var command_storage: [command_buffer_size]u8 = undefined;
        const command = try std.fmt.bufPrint(&command_storage, command_fmt, args);

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

fn generateSlackMessage(
    title: []const u8,
    url: []const u8,
    reviewers: [][]const u8,
    config: *const Config,
    buffer: []u8,
) ![]u8 {
    var reviewerMentionBuffer: [1024]u8 = undefined;
    var reviewerMentions = std.ArrayList(u8).initBuffer(&reviewerMentionBuffer);
    for (reviewers, 0..) |githubHandle, i| {
        if (config.getSlackHandle(githubHandle)) |slackHandle| {
            reviewerMentions.appendSliceAssumeCapacity("@");
            reviewerMentions.appendSliceAssumeCapacity(slackHandle);
        } else {
            reviewerMentions.appendSliceAssumeCapacity("@");
            reviewerMentions.appendSliceAssumeCapacity(githubHandle);
        }
        if (i < reviewers.len - 1) {
            reviewerMentions.appendSliceAssumeCapacity(" / ");
        }
    }
    return try std.fmt.bufPrint(
        buffer,
        ":open-pr: [{s}]({s}) {s}",
        .{ title, url, reviewerMentions.items },
    );
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

    var outputBuffer: [32 * 1024]u8 = undefined;

    const ghAuthStatus = try shell.runCommand(&outputBuffer, "gh auth status", .{});
    if (ghAuthStatus.exitCode != 0) {
        try writer.print("You might not be logged in with `gh`. Run `gh auth login`\n", .{});
        try writer.flush();
        return error.SafetyCheckFailed;
    }
    std.log.debug("auth status {s}", .{ghAuthStatus.output});

    const baseBranchResult = try shell.runCommand(
        &outputBuffer,
        "gh repo view --json defaultBranchRef -q .defaultBranchRef.name",
        .{},
    );
    var baseBuffer: [128]u8 = undefined;
    const base = try copyTrimmed(baseBranchResult.output, &baseBuffer);
    if (base.len == 0) {
        try writer.print("Could not determine repository's default branch\n", .{});
        try writer.flush();
        return error.SafetyCheckFailed;
    }
    std.log.debug("base {s}", .{base});

    const headBranchNameResult = try shell.runCommand(&outputBuffer, "git rev-parse --abbrev-ref HEAD", .{});
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

    const branchPushedResult = try shell.runCommand(
        &outputBuffer,
        "git ls-remote --exit-code --heads origin '{s}' >/dev/null",
        .{headBranch},
    );
    if (branchPushedResult.exitCode != 0) {
        try writer.print("Current branch is not pushed to origin. Run `git push -u origin {s}` first.\n", .{headBranch});
        try writer.flush();
        return error.SafetyCheckFailed;
    }

    const commitRangeResult = try shell.runCommand(
        &outputBuffer,
        "git log --oneline 'origin/{s}..origin/{s}'",
        .{ base, headBranch },
    );
    if (commitRangeResult.exitCode != 0) return error.SafetyCheckFailed;
    std.log.debug("commit range {s}", .{commitRangeResult.output});
    if (std.mem.trim(u8, commitRangeResult.output, " ").len == 0) {
        try writer.print("There are no commits on origin/{s} that are not in origin/{s}\n", .{ headBranch, base });
        try writer.flush();
        return error.SafetyCheckFailed;
    }

    const existingPrResult = try shell.runCommand(
        &outputBuffer,
        "gh pr list --head '{s}' --base '{s}' --state open --json url --jq '.[0].url // \"\"'",
        .{ headBranch, base },
    );
    if (existingPrResult.exitCode != 0) return error.SafetyCheckFailed;
    if (std.mem.trim(u8, existingPrResult.output, "\n").len != 0) {
        std.log.debug("{s}", .{existingPrResult.output});
        try writer.print("An open PR already exists: {s}\n", .{existingPrResult.output});
        try writer.flush();
        return error.SafetyCheckFailed;
    }

    const worktreeStatusResult = try shell.runCommand(&outputBuffer, "git status -sb", .{});
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

    var bodyFilePathBuffer: [128]u8 = undefined;
    const bodyFilePath = if (try promptConfirmation("Write the body (y/N): ", reader, writer) orelse false)
        try promptEditor(&bodyFilePathBuffer)
    else
        try createTempEditorFile(&bodyFilePathBuffer);
    defer std.fs.deleteFileAbsolute(bodyFilePath) catch {};

    const repoResult = try shell.runCommand(
        &outputBuffer,
        "gh repo view --json nameWithOwner -q .nameWithOwner",
        .{},
    );
    if (repoResult.exitCode != 0) return error.SafetyCheckFailed;
    var repoBuffer: [256]u8 = undefined;
    const repo = try copyTrimmed(repoResult.output, &repoBuffer);

    const currentUserResult = try shell.runCommand(&outputBuffer, "gh api user --jq .login", .{});
    if (currentUserResult.exitCode != 0) return error.SafetyCheckFailed;
    var currentUserBuffer: [128]u8 = undefined;
    const currentUser = try copyTrimmed(currentUserResult.output, &currentUserBuffer);

    const collaboratorsResult = try shell.runCommand(
        &outputBuffer,
        "gh api 'repos/{s}/collaborators' --paginate --jq '.[] | select(.login != \"{s}\") | .login'",
        .{ repo, currentUser },
    );
    const collaboratorsList = if (collaboratorsResult.exitCode == 0)
        std.mem.trim(u8, collaboratorsResult.output, &std.ascii.whitespace)
    else
        "";

    var config = try Config.init("ppr", collaboratorsList);
    defer config.deinit();
    if (config.created) {
        try writer.print("Created config file: {s}\n", .{config.path()});
        try writer.flush();
    }

    if (collaboratorsList.len != 0) {
        try writer.print("Available user reviewers:\n{s}\n", .{collaboratorsList});
        try writer.flush();
    }

    const teamsResult = try shell.runCommand(
        &outputBuffer,
        "gh api 'repos/{s}/teams' --paginate --jq '.[] | .organization.login + \"/\" + .slug'",
        .{repo},
    );
    const teamsList = if (teamsResult.exitCode == 0)
        std.mem.trim(u8, teamsResult.output, &std.ascii.whitespace)
    else
        "";
    if (teamsList.len != 0) {
        try writer.print("Available team reviewers:\n{s}\n", .{teamsList});
        try writer.flush();
    }

    var reviewersBuffer: [2048]u8 = undefined;
    var reviewers: []const u8 = &.{};
    if (collaboratorsList.len != 0 or teamsList.len != 0) {
        var reviewerInputBuffer: [2048]u8 = undefined;
        const reviewersInput = try promptText("Reviewers (comma-separated, optional): ", reader, writer, &reviewerInputBuffer);
        reviewers = try normalizeCommaSeparated(reviewersInput, &reviewersBuffer);
    }

    const createPrResult = try shell.runCommand(
        &outputBuffer,
        "gh pr create --base '{s}' --head '{s}' --title '{s}' --body-file '{s}' --reviewer '{s}'",
        .{ base, headBranch, title, bodyFilePath, reviewers },
    );
    if (createPrResult.exitCode != 0) return error.PullRequestCreateFailed;

    const createPrOutput = std.mem.trim(u8, createPrResult.output, &std.ascii.whitespace);
    if (createPrOutput.len != 0) {
        try writer.print("{s}\n", .{createPrOutput});
        try writer.flush();
    }
}

test "Shell keeps child shell alive between commands" {
    var shell = try Shell.init(std.testing.allocator);
    defer shell.deinit();

    var first_output_buffer: [64]u8 = undefined;
    const first = try shell.runCommand(&first_output_buffer, "keep_alive_var=42", .{});
    try std.testing.expectEqual(@as(u8, 0), first.exitCode);
    try std.testing.expectEqualStrings("", first.output);

    var second_output_buffer: [64]u8 = undefined;
    const second = try shell.runCommand(&second_output_buffer, "echo \"$keep_alive_var\"", .{});
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

test "promptEditor returns path and editor writes text to file" {
    var path_buffer: [256]u8 = undefined;
    const path = try promptEditorWithScript("printf 'body from editor' > \"$1\"", &path_buffer);
    defer std.fs.deleteFileAbsolute(path) catch {};

    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    var contents: [64]u8 = undefined;
    const n = try file.readAll(&contents);
    try std.testing.expectEqualStrings("body from editor", contents[0..n]);
}

test "promptEditor returns StreamTooLong when path buffer is too small" {
    var path_buffer: [4]u8 = undefined;
    try std.testing.expectError(
        error.StreamTooLong,
        promptEditorWithScript(":", &path_buffer),
    );
}

test "promptEditor returns EditorFailed on non-zero exit" {
    var path_buffer: [128]u8 = undefined;
    try std.testing.expectError(
        error.EditorFailed,
        promptEditorWithScript("exit 2", &path_buffer),
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

test "Config init creates file and defaults github handles to themselves" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var home_storage: [std.fs.max_path_bytes]u8 = undefined;
    const home = try tmp.dir.realpath(".", &home_storage);

    var config = try Config.initWithHome("ppr-test", home, "alice\nbob\n");
    defer config.deinit();

    try std.testing.expect(config.created);
    try std.testing.expectEqualStrings("alice", config.getSlackHandle("alice").?);
    try std.testing.expectEqualStrings("bob", config.getSlackHandle("bob").?);

    var config_path_storage: [1024]u8 = undefined;
    const config_path = try std.fmt.bufPrint(&config_path_storage, "{s}/.config/ppr-test.json", .{home});

    var file = try std.fs.openFileAbsolute(config_path, .{});
    defer file.close();

    var json_text_buffer: [4096]u8 = undefined;
    const n = try file.readAll(&json_text_buffer);
    const json_text = json_text_buffer[0..n];
    try std.testing.expect(std.mem.indexOf(u8, json_text, "\"alice\": \"alice\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_text, "\"bob\": \"bob\"") != null);
}

test "Config init loads existing reviewer to slack map" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var home_storage: [std.fs.max_path_bytes]u8 = undefined;
    const home = try tmp.dir.realpath(".", &home_storage);

    var config_dir_storage: [1024]u8 = undefined;
    const config_dir = try std.fmt.bufPrint(&config_dir_storage, "{s}/.config", .{home});
    std.fs.makeDirAbsolute(config_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var config_path_storage: [1024]u8 = undefined;
    const config_path = try std.fmt.bufPrint(&config_path_storage, "{s}/ppr-test.json", .{config_dir});

    var file = try std.fs.createFileAbsolute(config_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(
        \\{
        \\  "alice": "@alice-in-slack"
        \\}
        \\
    );

    var config = try Config.initWithHome("ppr-test", home, "alice\nbob\n");
    defer config.deinit();

    try std.testing.expect(!config.created);
    try std.testing.expectEqualStrings("@alice-in-slack", config.getSlackHandle("alice").?);
    try std.testing.expect(config.getSlackHandle("bob") == null);
}

test "generateSlackMessage uses slack map and falls back to github handle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var home_storage: [std.fs.max_path_bytes]u8 = undefined;
    const home = try tmp.dir.realpath(".", &home_storage);

    var config = try Config.initWithHome("ppr-test-slack-message", home, "");
    defer config.deinit();
    try config.putMapping("alice", "alice.slack");

    var reviewers = [_][]const u8{ "alice", "bob" };
    var msg_buffer: [512]u8 = undefined;
    const message = try generateSlackMessage(
        "Fix race condition",
        "https://github.com/acme/repo/pull/123",
        reviewers[0..],
        &config,
        &msg_buffer,
    );

    try std.testing.expectEqualStrings(
        ":open-pr: [Fix race condition](https://github.com/acme/repo/pull/123) @alice.slack / @bob",
        message,
    );
}
