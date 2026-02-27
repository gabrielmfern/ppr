const std = @import("std");
const builtin = @import("builtin");

fn promptText(
    prompt: []const u8,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    outputBuffer: []u8,
) ![]u8 {
    try writer.writeAll(prompt);
    try writer.flush();

    var collecting = std.Io.Writer.fixed(outputBuffer);
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
    var inputBuffer: [16]u8 = undefined;
    const text = try promptText(prompt, reader, writer, &inputBuffer);
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (std.ascii.eqlIgnoreCase(trimmed, "y") or std.ascii.eqlIgnoreCase(trimmed, "yes")) {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "n") or std.ascii.eqlIgnoreCase(trimmed, "no")) {
        return false;
    }
    return null;
}

fn copyTrimmed(input: []const u8, outputBuffer: []u8) ![]u8 {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
    if (trimmed.len > outputBuffer.len) return error.StreamTooLong;
    @memcpy(outputBuffer[0..trimmed.len], trimmed);
    return outputBuffer[0..trimmed.len];
}

fn normalizeCommaSeparated(input: []const u8, outputBuffer: []u8) ![]u8 {
    var cursor: usize = 0;
    var parts = std.mem.splitScalar(u8, input, ',');

    while (parts.next()) |partRaw| {
        const part = std.mem.trim(u8, partRaw, &std.ascii.whitespace);
        if (part.len == 0) continue;

        if (cursor != 0) {
            if (cursor >= outputBuffer.len) return error.StreamTooLong;
            outputBuffer[cursor] = ',';
            cursor += 1;
        }

        if (cursor + part.len > outputBuffer.len) return error.StreamTooLong;
        @memcpy(outputBuffer[cursor .. cursor + part.len], part);
        cursor += part.len;
    }

    return outputBuffer[0..cursor];
}

const Config = struct {
    nameBuffer: [maxNameLen]u8,
    nameLen: usize,
    pathBuffer: [maxPathLen]u8,
    pathLen: usize,
    entries: [maxEntries]Entry,
    entriesLen: usize,
    created: bool,

    const maxNameLen = 64;
    const maxPathLen = 1024;
    const maxEntries = 256;
    const maxHandleLen = 128;
    const maxFileSize = 64 * 1024;

    const Entry = struct {
        githubBuffer: [maxHandleLen]u8,
        githubLen: usize,
        slackBuffer: [maxHandleLen]u8,
        slackLen: usize,

        fn github(self: *const Entry) []const u8 {
            return self.githubBuffer[0..self.githubLen];
        }

        fn slack(self: *const Entry) []const u8 {
            return self.slackBuffer[0..self.slackLen];
        }
    };

    pub fn init(
        name: []const u8,
        githubReviewers: []const u8,
    ) !Config {
        if (builtin.os.tag == .windows) return error.UnsupportedOperatingSystem;
        const home = std.posix.getenv("HOME") orelse return error.EnvironmentVariableNotFound;
        return initWithHome(name, home, githubReviewers);
    }

    fn initWithHome(
        name: []const u8,
        home: []const u8,
        githubReviewers: []const u8,
    ) !Config {
        var configDirBuffer: [maxPathLen]u8 = undefined;
        const configDir = try std.fmt.bufPrint(&configDirBuffer, "{s}/.config", .{home});

        std.fs.makeDirAbsolute(configDir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var config = Config{
            .nameBuffer = undefined,
            .nameLen = 0,
            .pathBuffer = undefined,
            .pathLen = 0,
            .entries = undefined,
            .entriesLen = 0,
            .created = false,
        };

        config.nameLen = try copyInto(config.nameBuffer[0..], name);
        const configPath = try std.fmt.bufPrint(&config.pathBuffer, "{s}/{s}.json", .{ configDir, name });
        config.pathLen = configPath.len;

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
            try config.seedDefaults(githubReviewers);
            try config.save();
        }

        return config;
    }

    pub fn deinit(self: *Config) void {
        _ = self;
    }

    pub fn path(self: *const Config) []const u8 {
        return self.pathBuffer[0..self.pathLen];
    }

    pub fn getSlackHandle(self: *const Config, githubHandle: []const u8) ?[]const u8 {
        for (self.entries[0..self.entriesLen]) |*entry| {
            if (std.mem.eql(u8, entry.github(), githubHandle)) {
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

    fn putMapping(self: *Config, githubHandle: []const u8, slackHandle: []const u8) !void {
        if (githubHandle.len == 0 or slackHandle.len == 0) return;
        if (self.getSlackHandle(githubHandle) != null) return;
        if (self.entriesLen >= maxEntries) return error.StreamTooLong;

        var entry = &self.entries[self.entriesLen];
        entry.githubLen = try copyInto(entry.githubBuffer[0..], githubHandle);
        entry.slackLen = try copyInto(entry.slackBuffer[0..], slackHandle);
        self.entriesLen += 1;
    }

    fn seedDefaults(self: *Config, githubReviewers: []const u8) !void {
        var lines = std.mem.splitScalar(u8, githubReviewers, '\n');
        while (lines.next()) |lineRaw| {
            const handle = std.mem.trim(u8, lineRaw, &std.ascii.whitespace);
            if (handle.len == 0) continue;
            try self.putMapping(handle, handle);
        }
    }

    fn load(self: *Config) !void {
        self.entriesLen = 0;

        var file = try std.fs.openFileAbsolute(self.path(), .{});
        defer file.close();

        var jsonTextBuffer: [maxFileSize]u8 = undefined;
        const n = try file.readAll(&jsonTextBuffer);
        var extra: [1]u8 = undefined;
        if (try file.read(&extra) != 0) return error.StreamTooLong;
        const jsonText = jsonTextBuffer[0..n];

        const trimmed = std.mem.trim(u8, jsonText, &std.ascii.whitespace);
        if (trimmed.len == 0) return;

        try self.parseJsonMap(trimmed);
    }

    fn save(self: *const Config) !void {
        var file = try std.fs.createFileAbsolute(self.path(), .{
            .truncate = true,
        });
        defer file.close();

        var writeBuffer: [4096]u8 = undefined;
        var fileWriter = file.writer(&writeBuffer);
        const writer = &fileWriter.interface;

        try writer.writeAll("{");
        for (self.entries[0..self.entriesLen], 0..) |*entry, i| {
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
        if (self.entriesLen != 0) {
            try writer.writeAll("\n");
        }
        try writer.writeAll("}\n");
        try fileWriter.interface.flush();
    }

    fn skipWhitespace(jsonText: []const u8, index: *usize) void {
        while (index.* < jsonText.len and std.ascii.isWhitespace(jsonText[index.*])) : (index.* += 1) {}
    }

    fn parseJsonString(jsonText: []const u8, index: *usize) ![]const u8 {
        if (index.* >= jsonText.len or jsonText[index.*] != '"') return error.InvalidConfig;
        index.* += 1;
        const start = index.*;

        while (index.* < jsonText.len) : (index.* += 1) {
            const ch = jsonText[index.*];
            if (ch == '"') {
                const value = jsonText[start..index.*];
                index.* += 1;
                return value;
            }
            if (ch == '\\' or ch < 0x20) return error.InvalidConfig;
        }

        return error.InvalidConfig;
    }

    fn parseJsonMap(self: *Config, jsonText: []const u8) !void {
        var index: usize = 0;
        skipWhitespace(jsonText, &index);
        if (index >= jsonText.len or jsonText[index] != '{') return error.InvalidConfig;
        index += 1;

        skipWhitespace(jsonText, &index);
        if (index < jsonText.len and jsonText[index] == '}') {
            index += 1;
            skipWhitespace(jsonText, &index);
            if (index != jsonText.len) return error.InvalidConfig;
            return;
        }

        while (true) {
            const githubHandle = try parseJsonString(jsonText, &index);
            skipWhitespace(jsonText, &index);
            if (index >= jsonText.len or jsonText[index] != ':') return error.InvalidConfig;
            index += 1;
            skipWhitespace(jsonText, &index);
            const slackHandle = try parseJsonString(jsonText, &index);
            try self.putMapping(githubHandle, slackHandle);
            skipWhitespace(jsonText, &index);
            if (index >= jsonText.len) return error.InvalidConfig;

            const ch = jsonText[index];
            if (ch == ',') {
                index += 1;
                skipWhitespace(jsonText, &index);
                continue;
            }
            if (ch == '}') {
                index += 1;
                break;
            }
            return error.InvalidConfig;
        }

        skipWhitespace(jsonText, &index);
        if (index != jsonText.len) return error.InvalidConfig;
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

fn worktreeIsClean(statusSbOutput: []const u8) bool {
    var lines = std.mem.tokenizeScalar(u8, statusSbOutput, '\n');
    _ = lines.next() orelse return false;
    return lines.next() == null;
}

fn promptEditor(pathBuffer: []u8) ![]u8 {
    return promptEditorWithScript("${EDITOR:-vi} \"$1\"", pathBuffer);
}

fn promptEditorWithScript(script: []const u8, pathBuffer: []u8) ![]u8 {
    if (builtin.os.tag == .windows) return error.UnsupportedOperatingSystem;

    var tempPathBuffer: [128]u8 = undefined;
    const tempPath = try createTempEditorFile(&tempPathBuffer);
    errdefer std.fs.deleteFileAbsolute(tempPath) catch {};

    var child = std.process.Child.init(
        &.{ "/bin/sh", "-c", script, "ppr-editor", tempPath },
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

    if (tempPath.len > pathBuffer.len) return error.StreamTooLong;
    @memcpy(pathBuffer[0..tempPath.len], tempPath);
    return pathBuffer[0..tempPath.len];
}

fn createTempEditorFile(pathBuffer: []u8) ![]u8 {
    for (0..32) |_| {
        const randomSuffix = std.crypto.random.int(u64);
        const tempPath = try std.fmt.bufPrint(pathBuffer, "/tmp/ppr-editor-{x}.md", .{randomSuffix});

        const file = std.fs.createFileAbsolute(tempPath, .{
            .read = true,
            .exclusive = true,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        file.close();
        return tempPath;
    }
    return error.UnableToCreateTempFile;
}

const Shell = struct {
    child: std.process.Child,
    stdoutBuffer: [stdoutBufferSize]u8,
    stdoutLen: usize,
    nextMarkerId: u64,
    closed: bool,

    const stdoutBufferSize = 16 * 1024;
    const markerBufferSize = 64;
    const markerCommandBufferSize = 256;
    const commandBufferSize = 8192;

    const CommandResult = struct {
        output: []u8,
        exitCode: u8,
    };

    const MarkerParse = struct {
        markerStart: usize,
        consumedEnd: usize,
        exitCode: u8,
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
            .stdoutBuffer = undefined,
            .stdoutLen = 0,
            .nextMarkerId = 0,
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
        outputBuffer: []u8,
        comptime commandFmt: []const u8,
        args: anytype,
    ) !CommandResult {
        if (self.closed) return error.ProcessAlreadyClosed;

        var commandBuffer: [commandBufferSize]u8 = undefined;
        const command = try std.fmt.bufPrint(&commandBuffer, commandFmt, args);

        self.nextMarkerId += 1;
        var markerBuffer: [markerBufferSize]u8 = undefined;
        const marker = try std.fmt.bufPrint(&markerBuffer, "__PPR_DONE_{d}__", .{self.nextMarkerId});

        std.log.debug("[shell] running {s}", .{command});
        try self.writeCommand(command, marker);

        var chunk: [1024]u8 = undefined;

        while (true) {
            if (findMarker(self.stdoutBuffer[0..self.stdoutLen], marker)) |markerParse| {
                const output = self.stdoutBuffer[0..markerParse.markerStart];
                if (output.len > outputBuffer.len) return error.OutputBufferTooSmall;
                @memcpy(outputBuffer[0..output.len], output);
                self.consumeStdout(markerParse.consumedEnd);
                return .{
                    .output = outputBuffer[0..output.len],
                    .exitCode = markerParse.exitCode,
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

        var markerCommandBuffer: [markerCommandBufferSize]u8 = undefined;
        const markerCommand = try std.fmt.bufPrint(
            &markerCommandBuffer,
            "printf '{s}:%d\\n' $?\n",
            .{marker},
        );
        try self.child.stdin.?.writeAll(markerCommand);
    }

    fn appendStdout(self: *Shell, bytes: []const u8) !void {
        const nextLen = self.stdoutLen + bytes.len;
        if (nextLen > self.stdoutBuffer.len) return error.StreamTooLong;
        @memcpy(self.stdoutBuffer[self.stdoutLen..nextLen], bytes);
        self.stdoutLen = nextLen;
    }

    fn consumeStdout(self: *Shell, consumed: usize) void {
        if (consumed == 0) return;
        const remaining = self.stdoutLen - consumed;
        std.mem.copyForwards(u8, self.stdoutBuffer[0..remaining], self.stdoutBuffer[consumed..self.stdoutLen]);
        self.stdoutLen = remaining;
    }

    fn findMarker(buffer: []const u8, marker: []const u8) ?MarkerParse {
        var searchFrom: usize = 0;

        while (std.mem.indexOfPos(u8, buffer, searchFrom, marker)) |markerStart| {
            const statusStart = markerStart + marker.len;
            if (statusStart >= buffer.len) return null;
            if (buffer[statusStart] != ':') {
                searchFrom = markerStart + 1;
                continue;
            }

            var statusEnd = statusStart + 1;
            while (statusEnd < buffer.len and std.ascii.isDigit(buffer[statusEnd])) : (statusEnd += 1) {}

            if (statusEnd == statusStart + 1) {
                searchFrom = markerStart + 1;
                continue;
            }
            if (statusEnd >= buffer.len) return null;
            if (buffer[statusEnd] != '\n') {
                searchFrom = markerStart + 1;
                continue;
            }

            const exitCode = std.fmt.parseInt(u8, buffer[(statusStart + 1)..statusEnd], 10) catch {
                searchFrom = markerStart + 1;
                continue;
            };

            return .{
                .markerStart = markerStart,
                .consumedEnd = statusEnd + 1,
                .exitCode = exitCode,
            };
        }

        return null;
    }
};

fn generateSlackMessage(
    title: []const u8,
    url: []const u8,
    reviewers: *std.mem.SplitIterator(u8, .any),
    config: *const Config,
    buffer: []u8,
) ![]u8 {
    var reviewerMentionBuffer: [1024]u8 = undefined;
    var reviewerMentions = std.ArrayList(u8).initBuffer(&reviewerMentionBuffer);
    var wroteReviewer = false;
    while (reviewers.next()) |githubHandleRaw| {
        const githubHandle = std.mem.trim(u8, githubHandleRaw, &std.ascii.whitespace);
        if (githubHandle.len == 0) continue;

        if (wroteReviewer) {
            reviewerMentions.appendSliceAssumeCapacity(" / ");
        }
        wroteReviewer = true;

        if (config.getSlackHandle(githubHandle)) |slackHandle| {
            reviewerMentions.appendSliceAssumeCapacity("@");
            reviewerMentions.appendSliceAssumeCapacity(slackHandle);
        } else {
            reviewerMentions.appendSliceAssumeCapacity("@");
            reviewerMentions.appendSliceAssumeCapacity(githubHandle);
        }
    }
    return try std.fmt.bufPrint(
        buffer,
        ":open-pr: [{s}]({s}) {s}",
        .{ title, url, reviewerMentions.items },
    );
}

fn copyToClipboard(shell: *Shell, text: []const u8) !void {
    var tempPathBuffer: [128]u8 = undefined;
    const tempPath = try createTempEditorFile(&tempPathBuffer);
    defer std.fs.deleteFileAbsolute(tempPath) catch {};

    var tempFile = try std.fs.createFileAbsolute(tempPath, .{ .truncate = true });
    defer tempFile.close();
    try tempFile.writeAll(text);

    var outputBuffer: [256]u8 = undefined;
    const result = switch (builtin.os.tag) {
        .macos => try shell.runCommand(&outputBuffer, "cat '{s}' | pbcopy", .{tempPath}),
        .linux => try shell.runCommand(&outputBuffer, "cat '{s}' | wl-copy", .{tempPath}),
        else => return error.UnsupportedOperatingSystem,
    };
    if (result.exitCode != 0) return error.ClipboardCommandFailed;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        std.log.err("Memory leak detected", .{});
    };

    const allocator = gpa.allocator();

    var shell = try Shell.init(allocator);
    defer shell.deinit();

    var stdinBuffer: [1024]u8 = undefined;
    var stdoutBuffer: [1024]u8 = undefined;
    var stdin = std.fs.File.stdin().reader(&stdinBuffer);
    var stdout = std.fs.File.stdout().writer(&stdoutBuffer);

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
        const continueAnyway = (try promptConfirmation("You have something to commit. Do it anyway? (Y/n)", reader, writer)) orelse true;
        if (!continueAnyway) {
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
    std.debug.assert(createPrOutput.len != 0);
    std.log.debug("create pr output {s}", .{createPrOutput});
    var reviewersIterator = std.mem.splitAny(u8, reviewers, ",");
    const message = try generateSlackMessage(
        title,
        createPrOutput,
        &reviewersIterator,
        &config,
        &outputBuffer,
    );
    try copyToClipboard(&shell, message);
    try writer.print("Pull request created: {s}\nThe PR URL and title have been copied to your clipboard in a Slack message format.\n", .{createPrOutput});
    try writer.print("{s}\n", .{message});
    try writer.flush();
}

test "Shell keeps child shell alive between commands" {
    var shell = try Shell.init(std.testing.allocator);
    defer shell.deinit();

    var firstOutputBuffer: [64]u8 = undefined;
    const first = try shell.runCommand(&firstOutputBuffer, "keepAliveVar=42", .{});
    try std.testing.expectEqual(@as(u8, 0), first.exitCode);
    try std.testing.expectEqualStrings("", first.output);

    var secondOutputBuffer: [64]u8 = undefined;
    const second = try shell.runCommand(&secondOutputBuffer, "echo \"$keepAliveVar\"", .{});
    try std.testing.expectEqual(@as(u8, 0), second.exitCode);
    try std.testing.expectEqualStrings("42\n", second.output);
}

test "promptText reads one line and writes prompt" {
    var reader = std.Io.Reader.fixed("octocat\nextra");
    var outputBuffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&outputBuffer);
    var inputBuffer: [32]u8 = undefined;

    const text = try promptText("GitHub username: ", &reader, &writer, &inputBuffer);

    try std.testing.expectEqualStrings("GitHub username: ", writer.buffered());
    try std.testing.expectEqualStrings("octocat", text);
}

test "promptText returns EndOfStream when no input is available" {
    var reader = std.Io.Reader.fixed("");
    var outputBuffer: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&outputBuffer);
    var inputBuffer: [32]u8 = undefined;

    try std.testing.expectError(
        error.EndOfStream,
        promptText("> ", &reader, &writer, &inputBuffer),
    );
    try std.testing.expectEqualStrings("> ", writer.buffered());
}

test "promptText returns StreamTooLong when input exceeds fixed buffer" {
    var reader = std.Io.Reader.fixed("this-input-is-too-long\n");
    var outputBuffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&outputBuffer);
    var inputBuffer: [4]u8 = undefined;

    try std.testing.expectError(
        error.StreamTooLong,
        promptText("Title: ", &reader, &writer, &inputBuffer),
    );
}

test "promptEditor returns path and editor writes text to file" {
    var pathBuffer: [256]u8 = undefined;
    const path = try promptEditorWithScript("printf 'body from editor' > \"$1\"", &pathBuffer);
    defer std.fs.deleteFileAbsolute(path) catch {};

    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    var contents: [64]u8 = undefined;
    const n = try file.readAll(&contents);
    try std.testing.expectEqualStrings("body from editor", contents[0..n]);
}

test "promptEditor returns StreamTooLong when path buffer is too small" {
    var pathBuffer: [4]u8 = undefined;
    try std.testing.expectError(
        error.StreamTooLong,
        promptEditorWithScript(":", &pathBuffer),
    );
}

test "promptEditor returns EditorFailed on non-zero exit" {
    var pathBuffer: [128]u8 = undefined;
    try std.testing.expectError(
        error.EditorFailed,
        promptEditorWithScript("exit 2", &pathBuffer),
    );
}

test "promptConfirmation accepts yes" {
    var reader = std.Io.Reader.fixed("YeS\n");
    var outputBuffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&outputBuffer);

    const accepted = try promptConfirmation("Continue? (y/N): ", &reader, &writer);
    try std.testing.expect(accepted == true);
    try std.testing.expectEqualStrings("Continue? (y/N): ", writer.buffered());
}

test "promptConfirmation null on empty input" {
    var reader = std.Io.Reader.fixed("\n");
    var outputBuffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&outputBuffer);

    const accepted = try promptConfirmation("Continue? (y/N): ", &reader, &writer);
    try std.testing.expect(accepted == null);
    try std.testing.expectEqualStrings("Continue? (y/N): ", writer.buffered());
}

test "promptConfirmation returns null for invalid answer" {
    var reader = std.Io.Reader.fixed("maybe\n");
    var outputBuffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&outputBuffer);

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

    var homeBuffer: [std.fs.max_path_bytes]u8 = undefined;
    const home = try tmp.dir.realpath(".", &homeBuffer);

    var config = try Config.initWithHome("ppr-test", home, "alice\nbob\n");
    defer config.deinit();

    try std.testing.expect(config.created);
    try std.testing.expectEqualStrings("alice", config.getSlackHandle("alice").?);
    try std.testing.expectEqualStrings("bob", config.getSlackHandle("bob").?);

    var configPathBuffer: [1024]u8 = undefined;
    const configPath = try std.fmt.bufPrint(&configPathBuffer, "{s}/.config/ppr-test.json", .{home});

    var file = try std.fs.openFileAbsolute(configPath, .{});
    defer file.close();

    var jsonTextBuffer: [4096]u8 = undefined;
    const n = try file.readAll(&jsonTextBuffer);
    const jsonText = jsonTextBuffer[0..n];
    try std.testing.expect(std.mem.indexOf(u8, jsonText, "\"alice\": \"alice\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonText, "\"bob\": \"bob\"") != null);
}

test "Config init loads existing reviewer to slack map" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var homeBuffer: [std.fs.max_path_bytes]u8 = undefined;
    const home = try tmp.dir.realpath(".", &homeBuffer);

    var configDirBuffer: [1024]u8 = undefined;
    const configDir = try std.fmt.bufPrint(&configDirBuffer, "{s}/.config", .{home});
    std.fs.makeDirAbsolute(configDir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var configPathBuffer: [1024]u8 = undefined;
    const configPath = try std.fmt.bufPrint(&configPathBuffer, "{s}/ppr-test.json", .{configDir});

    var file = try std.fs.createFileAbsolute(configPath, .{ .truncate = true });
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

    var homeBuffer: [std.fs.max_path_bytes]u8 = undefined;
    const home = try tmp.dir.realpath(".", &homeBuffer);

    var config = try Config.initWithHome("ppr-test-slack-message", home, "");
    defer config.deinit();
    try config.putMapping("alice", "alice.slack");

    var reviewers = std.mem.splitAny(u8, "alice,bob", ",");
    var msgBuffer: [512]u8 = undefined;
    const message = try generateSlackMessage(
        "Fix race condition",
        "https://github.com/acme/repo/pull/123",
        &reviewers,
        &config,
        &msgBuffer,
    );

    try std.testing.expectEqualStrings(
        ":open-pr: [Fix race condition](https://github.com/acme/repo/pull/123) @alice.slack / @bob",
        message,
    );
}
