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

    const RawTerminalMode = struct {
        fd: std.posix.fd_t,
        previous: std.posix.termios,

        fn enter(fd: std.posix.fd_t) !@This() {
            const previous = try std.posix.tcgetattr(fd);
            var current = previous;

            current.iflag.ICRNL = false;
            current.iflag.IXON = false;
            current.lflag.ICANON = false;
            current.lflag.ECHO = false;
            current.lflag.IEXTEN = false;

            try std.posix.tcsetattr(fd, .FLUSH, current);
            return .{
                .fd = fd,
                .previous = previous,
            };
        }

        fn restore(self: *const @This()) void {
            std.posix.tcsetattr(self.fd, .FLUSH, self.previous) catch {};
        }
    };

    var liveEditing = !builtin.is_test and
        std.posix.isatty(std.posix.STDIN_FILENO) and
        std.posix.isatty(std.posix.STDOUT_FILENO);
    var rawMode: ?RawTerminalMode = null;

    if (liveEditing) {
        rawMode = RawTerminalMode.enter(std.posix.STDIN_FILENO) catch |err| switch (err) {
            error.NotATerminal => null,
            else => return err,
        };
        if (rawMode == null) liveEditing = false;
    }
    defer if (rawMode) |raw| {
        raw.restore();
    };

    const renderPromptLine = struct {
        fn call(w: *std.Io.Writer, p: []const u8, text: []const u8, c: usize) !void {
            try w.writeAll("\r");
            try w.writeAll(p);
            try w.writeAll(text);
            try w.writeAll("\x1b[K");
            const trailing = text.len - c;
            if (trailing > 0) try w.print("\x1b[{d}D", .{trailing});
            try w.flush();
        }
    }.call;

    var textLen: usize = 0;
    var cursor: usize = 0;

    while (true) {
        const byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => {
                if (textLen == 0) return error.EndOfStream;
                if (liveEditing) {
                    try renderPromptLine(writer, prompt, outputBuffer[0..textLen], textLen);
                    try writer.writeAll("\n");
                    try writer.flush();
                }
                return outputBuffer[0..textLen];
            },
            error.ReadFailed => return error.ReadFailed,
        };

        var shouldRender = false;

        switch (byte) {
            '\n' => {
                if (liveEditing) {
                    try renderPromptLine(writer, prompt, outputBuffer[0..textLen], textLen);
                    try writer.writeAll("\n");
                    try writer.flush();
                }
                return outputBuffer[0..textLen];
            },
            '\r' => {
                if (reader.bufferedLen() > 0 and reader.buffered()[0] == '\n') {
                    reader.toss(1);
                }
                if (liveEditing) {
                    try renderPromptLine(writer, prompt, outputBuffer[0..textLen], textLen);
                    try writer.writeAll("\n");
                    try writer.flush();
                }
                return outputBuffer[0..textLen];
            },
            0x01 => {
                cursor = 0; // Ctrl+A
                shouldRender = true;
            },
            0x05 => {
                cursor = textLen; // Ctrl+E
                shouldRender = true;
            },
            0x08, 0x7f => {
                deletePromptByteBeforeCursor(outputBuffer, &textLen, &cursor);
                shouldRender = true;
            },
            0x15 => {
                deletePromptToStart(outputBuffer, &textLen, &cursor); // Ctrl+U / Cmd+Backspace equivalent
                shouldRender = true;
            },
            0x17 => {
                deletePromptWordBeforeCursor(outputBuffer, &textLen, &cursor); // Ctrl+W / Ctrl+Backspace equivalent
                shouldRender = true;
            },
            0x1b => {
                const action = try readPromptEscapeAction(reader);
                switch (action) {
                    .none => {},
                    .submit => {
                        if (liveEditing) {
                            try renderPromptLine(writer, prompt, outputBuffer[0..textLen], textLen);
                            try writer.writeAll("\n");
                            try writer.flush();
                        }
                        return outputBuffer[0..textLen];
                    },
                    .move_up, .move_down => {},
                    .move_left => {
                        if (cursor > 0) cursor -= 1;
                        shouldRender = true;
                    },
                    .move_right => {
                        if (cursor < textLen) cursor += 1;
                        shouldRender = true;
                    },
                    .move_home => {
                        cursor = 0;
                        shouldRender = true;
                    },
                    .move_end => {
                        cursor = textLen;
                        shouldRender = true;
                    },
                    .move_word_left => {
                        moveCursorWordLeft(outputBuffer[0..textLen], &cursor);
                        shouldRender = true;
                    },
                    .move_word_right => {
                        moveCursorWordRight(outputBuffer[0..textLen], &cursor);
                        shouldRender = true;
                    },
                    .delete_word_left => {
                        deletePromptWordBeforeCursor(outputBuffer, &textLen, &cursor);
                        shouldRender = true;
                    },
                    .delete_to_start => {
                        deletePromptToStart(outputBuffer, &textLen, &cursor);
                        shouldRender = true;
                    },
                }
            },
            else => {
                if (byte == '\t' or (byte >= 0x20 and byte != 0x7f)) {
                    try insertPromptByte(outputBuffer, &textLen, &cursor, byte);
                    shouldRender = true;
                }
            },
        }

        if (liveEditing and shouldRender) {
            try renderPromptLine(writer, prompt, outputBuffer[0..textLen], cursor);
        }
    }
}

const PromptEscapeAction = enum {
    none,
    submit,
    move_up,
    move_down,
    move_left,
    move_right,
    move_home,
    move_end,
    move_word_left,
    move_word_right,
    delete_word_left,
    delete_to_start,
};

const CsiParameters = struct {
    first: ?usize,
    second: ?usize,
};

fn insertPromptByte(
    outputBuffer: []u8,
    textLen: *usize,
    cursor: *usize,
    byte: u8,
) !void {
    if (textLen.* >= outputBuffer.len) return error.StreamTooLong;
    if (cursor.* < textLen.*) {
        @memmove(outputBuffer[cursor.* + 1 .. textLen.* + 1], outputBuffer[cursor.*..textLen.*]);
    }
    outputBuffer[cursor.*] = byte;
    textLen.* += 1;
    cursor.* += 1;
}

fn deletePromptByteBeforeCursor(outputBuffer: []u8, textLen: *usize, cursor: *usize) void {
    if (cursor.* == 0) return;
    if (cursor.* < textLen.*) {
        @memmove(outputBuffer[cursor.* - 1 .. textLen.* - 1], outputBuffer[cursor.*..textLen.*]);
    }
    cursor.* -= 1;
    textLen.* -= 1;
}

fn deletePromptWordBeforeCursor(outputBuffer: []u8, textLen: *usize, cursor: *usize) void {
    if (cursor.* == 0) return;

    var start = cursor.*;
    while (start > 0 and std.ascii.isWhitespace(outputBuffer[start - 1])) {
        start -= 1;
    }
    while (start > 0 and !std.ascii.isWhitespace(outputBuffer[start - 1])) {
        start -= 1;
    }

    const tailLen = textLen.* - cursor.*;
    if (tailLen > 0) {
        @memmove(outputBuffer[start .. start + tailLen], outputBuffer[cursor.* .. cursor.* + tailLen]);
    }
    textLen.* -= cursor.* - start;
    cursor.* = start;
}

fn deletePromptToStart(outputBuffer: []u8, textLen: *usize, cursor: *usize) void {
    if (cursor.* == 0) return;
    const tailLen = textLen.* - cursor.*;
    if (tailLen > 0) {
        @memmove(outputBuffer[0..tailLen], outputBuffer[cursor.* .. cursor.* + tailLen]);
    }
    textLen.* = tailLen;
    cursor.* = 0;
}

fn moveCursorWordLeft(text: []const u8, cursor: *usize) void {
    while (cursor.* > 0 and std.ascii.isWhitespace(text[cursor.* - 1])) {
        cursor.* -= 1;
    }
    while (cursor.* > 0 and !std.ascii.isWhitespace(text[cursor.* - 1])) {
        cursor.* -= 1;
    }
}

fn moveCursorWordRight(text: []const u8, cursor: *usize) void {
    while (cursor.* < text.len and std.ascii.isWhitespace(text[cursor.*])) {
        cursor.* += 1;
    }
    while (cursor.* < text.len and !std.ascii.isWhitespace(text[cursor.*])) {
        cursor.* += 1;
    }
}

fn readPromptEscapeAction(reader: *std.Io.Reader) !PromptEscapeAction {
    const first = reader.takeByte() catch |err| switch (err) {
        error.EndOfStream => return .none,
        error.ReadFailed => return error.ReadFailed,
    };

    switch (first) {
        '\n', '\r' => return .submit,
        '[' => return readCsiEscapeAction(reader),
        'O' => return readSs3EscapeAction(reader),
        'b' => return .move_word_left, // Option+Left in many macOS terminal configs.
        'f' => return .move_word_right, // Option+Right in many macOS terminal configs.
        0x08, 0x7f => return .delete_word_left, // Option+Backspace (ESC + BS/DEL)
        else => return .none,
    }
}

fn readSs3EscapeAction(reader: *std.Io.Reader) !PromptEscapeAction {
    const final = reader.takeByte() catch |err| switch (err) {
        error.EndOfStream => return .none,
        error.ReadFailed => return error.ReadFailed,
    };

    return switch (final) {
        'A' => .move_up,
        'B' => .move_down,
        'D' => .move_left,
        'C' => .move_right,
        'H' => .move_home,
        'F' => .move_end,
        '\n', '\r' => .submit,
        else => .none,
    };
}

fn readCsiEscapeAction(reader: *std.Io.Reader) !PromptEscapeAction {
    var sequence: [16]u8 = undefined;
    var sequenceLen: usize = 0;

    while (sequenceLen < sequence.len) {
        const next = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => return .none,
            error.ReadFailed => return error.ReadFailed,
        };

        if (next == '\n' or next == '\r') return .submit;

        sequence[sequenceLen] = next;
        sequenceLen += 1;

        // ANSI CSI final bytes are in [0x40, 0x7E].
        if (next >= 0x40 and next <= 0x7e) break;
    }

    if (sequenceLen == 0) return .none;
    return classifyCsiEscapeAction(sequence[0..sequenceLen]);
}

fn classifyCsiEscapeAction(sequence: []const u8) PromptEscapeAction {
    const final = sequence[sequence.len - 1];
    const paramsText = sequence[0 .. sequence.len - 1];

    return switch (final) {
        'A' => .move_up,
        'B' => .move_down,
        'D' => classifyDirectionalEscape(paramsText, .move_left, .move_word_left, .move_home),
        'C' => classifyDirectionalEscape(paramsText, .move_right, .move_word_right, .move_end),
        'H' => .move_home,
        'F' => .move_end,
        '~' => classifyTildeEscape(paramsText),
        'u' => classifyUnicodeKeyEscape(paramsText),
        else => .none,
    };
}

fn classifyDirectionalEscape(
    paramsText: []const u8,
    baseAction: PromptEscapeAction,
    wordAction: PromptEscapeAction,
    commandAction: PromptEscapeAction,
) PromptEscapeAction {
    if (paramsText.len == 0) return baseAction;
    const params = parseCsiParameters(paramsText) orelse return .none;

    if (params.second) |modifier| {
        // Common modifier encodings:
        // 3 = Alt/Option, 9 = Cmd (seen in some terminal configs).
        if (modifier == 3) return wordAction;
        if (modifier == 9) return commandAction;
    }

    return baseAction;
}

fn classifyTildeEscape(paramsText: []const u8) PromptEscapeAction {
    const params = parseCsiParameters(paramsText) orelse return .none;
    const first = params.first orelse return .none;

    return switch (first) {
        1, 7 => .move_home,
        4, 8 => .move_end,
        else => .none,
    };
}

fn classifyUnicodeKeyEscape(paramsText: []const u8) PromptEscapeAction {
    const params = parseCsiParameters(paramsText) orelse return .none;
    const codepoint = params.first orelse return .none;
    const modifier = params.second orelse return .none;

    if (codepoint != 8 and codepoint != 127) return .none;

    if (modifier == 9) return .delete_to_start; // Cmd+Backspace in Kitty-style keyboard protocol.
    if (modifier == 3 or modifier == 5) return .delete_word_left; // Opt/Ctrl+Backspace.
    return .none;
}

fn parseCsiParameters(text: []const u8) ?CsiParameters {
    if (text.len == 0) return .{ .first = null, .second = null };

    if (std.mem.indexOfScalar(u8, text, ';')) |sep| {
        return .{
            .first = parseUnsigned(text[0..sep]),
            .second = parseUnsigned(text[sep + 1 ..]),
        };
    }

    return .{
        .first = parseUnsigned(text),
        .second = null,
    };
}

fn parseUnsigned(text: []const u8) ?usize {
    if (text.len == 0) return null;
    var value: usize = 0;
    for (text) |ch| {
        if (!std.ascii.isDigit(ch)) return null;
        value = std.math.mul(usize, value, 10) catch return null;
        value = std.math.add(usize, value, ch - '0') catch return null;
    }
    return value;
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

fn collectUniqueLines(input: []const u8, output: []([]const u8), outputLen: *usize) !void {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |lineRaw| {
        const line = std.mem.trim(u8, lineRaw, &std.ascii.whitespace);
        if (line.len == 0) continue;

        var exists = false;
        for (output[0..outputLen.*]) |existing| {
            if (std.mem.eql(u8, existing, line)) {
                exists = true;
                break;
            }
        }
        if (exists) continue;

        if (outputLen.* >= output.len) return error.StreamTooLong;
        output[outputLen.*] = line;
        outputLen.* += 1;
    }
}

fn reviewerDisplayHandle(reviewer: []const u8, config: *const Config) []const u8 {
    return config.getSlackHandle(reviewer) orelse reviewer;
}

fn writePicker(
    w: *std.Io.Writer,
    options: []const []const u8,
    selected: []const bool,
    cursor: usize,
    previousLines: *usize,
) !void {
    if (previousLines.* > 0) {
        try w.print("\x1b[{d}A\r", .{previousLines.*});
    }
    try w.writeAll("\x1b[J");
    try w.writeAll("\x1b[36mReviewers (up/down to move, space to toggle, enter to confirm)\x1b[0m\n");

    const windowSize: usize = 5;
    var start: usize = 0;
    if (options.len > windowSize) {
        const halfWindow = windowSize / 2;
        if (cursor > halfWindow) {
            start = cursor - halfWindow;
        }
        const maxStart = options.len - windowSize;
        if (start > maxStart) {
            start = maxStart;
        }
    }
    const end = @min(options.len, start + windowSize);

    var linesRendered: usize = 1;
    if (start > 0) {
        try w.print("\x1b[2m  ↑ {d} more above\x1b[0m\x1b[K\n", .{start});
        linesRendered += 1;
    }
    for (start..end) |idx| {
        const option = options[idx];
        const indicator = if (idx == cursor) "\x1b[32m>\x1b[0m" else " ";
        const marker = if (selected[idx]) "\x1b[33mx\x1b[0m" else " ";
        if (selected[idx]) {
            try w.print("{s} [{s}] \x1b[33m{s}\x1b[0m\x1b[K\n", .{ indicator, marker, option });
        } else {
            try w.print("{s} [{s}] {s}\x1b[K\n", .{ indicator, marker, option });
        }
        linesRendered += 1;
    }
    if (end < options.len) {
        try w.print("\x1b[2m  ↓ {d} more below\x1b[0m\x1b[K\n", .{options.len - end});
        linesRendered += 1;
    }

    var selectedBuffer: [2048]u8 = undefined;
    var selectedLen: usize = 0;
    var wroteAny = false;
    for (options, 0..) |option, idx| {
        if (!selected[idx]) continue;

        if (wroteAny) {
            if (selectedLen + 2 > selectedBuffer.len) break;
            @memcpy(selectedBuffer[selectedLen .. selectedLen + 2], ", ");
            selectedLen += 2;
        }
        const remaining = selectedBuffer.len - selectedLen;
        if (option.len > remaining) {
            if (remaining >= 3) {
                @memcpy(selectedBuffer[selectedLen .. selectedLen + 3], "...");
                selectedLen += 3;
            }
            break;
        }
        @memcpy(selectedBuffer[selectedLen .. selectedLen + option.len], option);
        selectedLen += option.len;
        wroteAny = true;
    }

    if (wroteAny) {
        try w.print("\x1b[36mSelected:\x1b[0m {s}\x1b[K\n", .{selectedBuffer[0..selectedLen]});
    } else {
        try w.writeAll("\x1b[2mSelected: none\x1b[0m\x1b[K\n");
    }
    linesRendered += 1;
    try w.flush();
    previousLines.* = linesRendered;
}

fn pickMultiple(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    options: []const []const u8,
    selectionBuffer: [][]const u8,
) ![]const []const u8 {
    if (options.len > selectionBuffer.len) return error.StreamTooLong;

    const maxOptions = 512;
    if (options.len > maxOptions) return error.StreamTooLong;

    const RawTerminalMode = struct {
        fd: std.posix.fd_t,
        previous: std.posix.termios,

        fn enter(fd: std.posix.fd_t) !@This() {
            const previous = try std.posix.tcgetattr(fd);
            var current = previous;

            current.iflag.ICRNL = false;
            current.iflag.IXON = false;
            current.lflag.ICANON = false;
            current.lflag.ECHO = false;
            current.lflag.IEXTEN = false;

            try std.posix.tcsetattr(fd, .FLUSH, current);
            return .{
                .fd = fd,
                .previous = previous,
            };
        }

        fn restore(self: *const @This()) void {
            std.posix.tcsetattr(self.fd, .FLUSH, self.previous) catch {};
        }
    };

    var liveSelection = !builtin.is_test and
        std.posix.isatty(std.posix.STDIN_FILENO) and
        std.posix.isatty(std.posix.STDOUT_FILENO);
    var rawMode: ?RawTerminalMode = null;

    if (liveSelection) {
        rawMode = RawTerminalMode.enter(std.posix.STDIN_FILENO) catch |err| switch (err) {
            error.NotATerminal => null,
            else => return err,
        };
        if (rawMode == null) liveSelection = false;
    }
    defer if (rawMode) |raw| {
        raw.restore();
    };

    var selectedFlags = std.mem.zeroes([maxOptions]bool);
    var cursor: usize = 0;
    var renderedLines: usize = 0;

    if (liveSelection) {
        try writePicker(writer, options, selectedFlags[0..options.len], cursor, &renderedLines);
    }

    while (true) {
        const byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return error.ReadFailed,
        };

        var changed = false;
        var submitted = false;

        switch (byte) {
            '\n' => submitted = true,
            '\r' => {
                if (reader.bufferedLen() > 0 and reader.buffered()[0] == '\n') {
                    reader.toss(1);
                }
                submitted = true;
            },
            ' ' => {
                if (options.len != 0) {
                    selectedFlags[cursor] = !selectedFlags[cursor];
                    changed = true;
                }
            },
            'k' => {
                if (cursor > 0) {
                    cursor -= 1;
                    changed = true;
                }
            },
            'j' => {
                if (cursor + 1 < options.len) {
                    cursor += 1;
                    changed = true;
                }
            },
            0x1b => {
                const action = try readPromptEscapeAction(reader);
                switch (action) {
                    .submit => submitted = true,
                    .move_up => {
                        if (cursor > 0) {
                            cursor -= 1;
                            changed = true;
                        }
                    },
                    .move_down => {
                        if (cursor + 1 < options.len) {
                            cursor += 1;
                            changed = true;
                        }
                    },
                    .move_home => {
                        if (options.len != 0 and cursor != 0) {
                            cursor = 0;
                            changed = true;
                        }
                    },
                    .move_end => {
                        if (options.len != 0 and cursor != options.len - 1) {
                            cursor = options.len - 1;
                            changed = true;
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }

        if (submitted) break;
        if (liveSelection and changed) {
            try writePicker(writer, options, selectedFlags[0..options.len], cursor, &renderedLines);
        }
    }

    var selectionLen: usize = 0;
    for (options, 0..) |item, idx| {
        if (!selectedFlags[idx]) continue;
        selectionBuffer[selectionLen] = item;
        selectionLen += 1;
    }
    return selectionBuffer[0..selectionLen];
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

const CliOptions = struct {
    draft: bool = false,
};

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
    reviewers: []const []const u8,
    config: *const Config,
    buffer: []u8,
) ![]u8 {
    var reviewerMentionBuffer: [1024]u8 = undefined;
    var reviewerMentions = std.ArrayList(u8).initBuffer(&reviewerMentionBuffer);
    var wroteReviewer = false;
    for (reviewers) |githubHandleRaw| {
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

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var draft = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--draft")) {
            draft = true;
        }
    }

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
    const bodyFilePathOpt = if (try promptConfirmation("Write the body (y/N): ", reader, writer) orelse false)
        try promptEditor(&bodyFilePathBuffer)
    else
        null;
    defer if (bodyFilePathOpt) |filePath| std.fs.deleteFileAbsolute(filePath) catch {};

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
    var collaboratorsListBuffer: [32 * 1024]u8 = undefined;
    const collaboratorsList = if (collaboratorsResult.exitCode == 0)
        try copyTrimmed(collaboratorsResult.output, &collaboratorsListBuffer)
    else
        "";

    var config = try Config.init("ppr", collaboratorsList);
    defer config.deinit();
    if (config.created) {
        try writer.print("Created config file: {s}\n", .{config.path()});
        try writer.flush();
    }

    const teamsResult = try shell.runCommand(
        &outputBuffer,
        "gh api 'repos/{s}/teams' --paginate --jq '.[] | .organization.login + \"/\" + .slug'",
        .{repo},
    );
    var teamsListBuffer: [1024]u8 = undefined;
    const teamsList = if (teamsResult.exitCode == 0)
        try copyTrimmed(teamsResult.output, &teamsListBuffer)
    else
        "";

    var reviewerChoicesBuffer: [512][]const u8 = undefined;
    var reviewerChoicesLen: usize = 0;
    try collectUniqueLines(collaboratorsList, &reviewerChoicesBuffer, &reviewerChoicesLen);
    try collectUniqueLines(teamsList, &reviewerChoicesBuffer, &reviewerChoicesLen);
    const reviewersAvailable = reviewerChoicesBuffer[0..reviewerChoicesLen];

    var selectedReviewersBuffer: [4][]const u8 = undefined;
    const selectedReviewers = if (reviewersAvailable.len == 0)
        &.{}
    else
        try pickMultiple(reader, writer, reviewersAvailable, &selectedReviewersBuffer);

    var reviewersArgumentBuffer: [1024]u8 = undefined;
    var reviewersArgumentLen: usize = 0;
    for (selectedReviewers, 0..) |reviewer, i| {
        if (i != 0) {
            reviewersArgumentBuffer[i - 1] = ',';
        }
        @memcpy(reviewersArgumentBuffer[i..(i + reviewer.len)], reviewer);
        reviewersArgumentLen += reviewer.len;
    }
    const reviewersArgument = reviewersArgumentBuffer[0..reviewersArgumentLen];

    const createPrResult = if (bodyFilePathOpt) |bodyFilePath|
        try shell.runCommand(
            &outputBuffer,
            "gh pr create --base '{s}' --head '{s}' --title '{s}' --body-file '{s}' --reviewer '{s}'{s}",
            .{ base, headBranch, title, bodyFilePath orelse "", reviewersArgument, if (draft) " --draft" else "" },
        )
    else
        try shell.runCommand(
            &outputBuffer,
            "gh pr create --base '{s}' --head '{s}' --title '{s}' --reviewer '{s}'{s}",
            .{ base, headBranch, title, reviewersArgument, if (draft) " --draft" else "" },
        );
    if (createPrResult.exitCode != 0) {
        try writer.print("Couldn't create pull request: {s}", .{createPrResult.output});
        try writer.flush();
        return error.PullRequestCreateFailed;
    }

    var createPrUrlBuffer: [512]u8 = undefined;
    const createPrUrl = try copyTrimmed(createPrResult.output, &createPrUrlBuffer);
    std.debug.assert(createPrUrl.len != 0);

    std.log.debug("create pr output {s}", .{createPrUrl});
    var messageBuffer: [1024]u8 = undefined;
    const message = try generateSlackMessage(
        title,
        createPrUrl,
        selectedReviewers,
        &config,
        &messageBuffer,
    );
    try copyToClipboard(&shell, message);
    try writer.print("The slack message was copied to your clipboard.\n", .{});
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

test "promptText supports command-left and command-right navigation" {
    var reader = std.Io.Reader.fixed("world\x1b[Hhello \x1b[F!\n");
    var outputBuffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&outputBuffer);
    var inputBuffer: [64]u8 = undefined;

    const text = try promptText("Title: ", &reader, &writer, &inputBuffer);
    try std.testing.expectEqualStrings("hello world!", text);
}

test "promptText supports option-left and option-right word navigation" {
    var reader = std.Io.Reader.fixed("hello world\x1bbbig \n");
    var outputBuffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&outputBuffer);
    var inputBuffer: [64]u8 = undefined;

    const text = try promptText("Title: ", &reader, &writer, &inputBuffer);
    try std.testing.expectEqualStrings("hello big world", text);

    var secondReader = std.Io.Reader.fixed("hello world\x1b[H\x1bf brave\n");
    var secondOutputBuffer: [128]u8 = undefined;
    var secondWriter = std.Io.Writer.fixed(&secondOutputBuffer);
    var secondInputBuffer: [64]u8 = undefined;
    const secondText = try promptText("Title: ", &secondReader, &secondWriter, &secondInputBuffer);
    try std.testing.expectEqualStrings("hello brave world", secondText);
}

test "promptText supports CSI modifier forms for option and command navigation" {
    var reader = std.Io.Reader.fixed("one two\x1b[1;3Dthree \n");
    var outputBuffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&outputBuffer);
    var inputBuffer: [64]u8 = undefined;

    const text = try promptText("Title: ", &reader, &writer, &inputBuffer);
    try std.testing.expectEqualStrings("one three two", text);

    var secondReader = std.Io.Reader.fixed("abc\x1b[1;9DSTART-\x1b[1;9C-END\n");
    var secondOutputBuffer: [128]u8 = undefined;
    var secondWriter = std.Io.Writer.fixed(&secondOutputBuffer);
    var secondInputBuffer: [64]u8 = undefined;
    const secondText = try promptText("Title: ", &secondReader, &secondWriter, &secondInputBuffer);
    try std.testing.expectEqualStrings("START-abc-END", secondText);
}

test "promptText supports cmd opt and ctrl backspace equivalents" {
    var cmdReader = std.Io.Reader.fixed("hello brave world\x1bb\x15\n");
    var cmdOutputBuffer: [128]u8 = undefined;
    var cmdWriter = std.Io.Writer.fixed(&cmdOutputBuffer);
    var cmdInputBuffer: [64]u8 = undefined;
    const cmdText = try promptText("Title: ", &cmdReader, &cmdWriter, &cmdInputBuffer);
    try std.testing.expectEqualStrings("world", cmdText);

    var optReader = std.Io.Reader.fixed("hello brave world\x1b\x7f\n");
    var optOutputBuffer: [128]u8 = undefined;
    var optWriter = std.Io.Writer.fixed(&optOutputBuffer);
    var optInputBuffer: [64]u8 = undefined;
    const optText = try promptText("Title: ", &optReader, &optWriter, &optInputBuffer);
    try std.testing.expectEqualStrings("hello brave ", optText);

    var ctrlReader = std.Io.Reader.fixed("hello brave world\x17\n");
    var ctrlOutputBuffer: [128]u8 = undefined;
    var ctrlWriter = std.Io.Writer.fixed(&ctrlOutputBuffer);
    var ctrlInputBuffer: [64]u8 = undefined;
    const ctrlText = try promptText("Title: ", &ctrlReader, &ctrlWriter, &ctrlInputBuffer);
    try std.testing.expectEqualStrings("hello brave ", ctrlText);
}

test "promptText supports CSI u backspace modifier forms" {
    var optReader = std.Io.Reader.fixed("hello brave world\x1b[127;3u\n");
    var optOutputBuffer: [128]u8 = undefined;
    var optWriter = std.Io.Writer.fixed(&optOutputBuffer);
    var optInputBuffer: [64]u8 = undefined;
    const optText = try promptText("Title: ", &optReader, &optWriter, &optInputBuffer);
    try std.testing.expectEqualStrings("hello brave ", optText);

    var optBsReader = std.Io.Reader.fixed("hello brave world\x1b[8;3u\n");
    var optBsOutputBuffer: [128]u8 = undefined;
    var optBsWriter = std.Io.Writer.fixed(&optBsOutputBuffer);
    var optBsInputBuffer: [64]u8 = undefined;
    const optBsText = try promptText("Title: ", &optBsReader, &optBsWriter, &optBsInputBuffer);
    try std.testing.expectEqualStrings("hello brave ", optBsText);

    var ctrlReader = std.Io.Reader.fixed("hello brave world\x1b[127;5u\n");
    var ctrlOutputBuffer: [128]u8 = undefined;
    var ctrlWriter = std.Io.Writer.fixed(&ctrlOutputBuffer);
    var ctrlInputBuffer: [64]u8 = undefined;
    const ctrlText = try promptText("Title: ", &ctrlReader, &ctrlWriter, &ctrlInputBuffer);
    try std.testing.expectEqualStrings("hello brave ", ctrlText);

    var cmdReader = std.Io.Reader.fixed("hello brave world\x1bb\x1b[127;9u\n");
    var cmdOutputBuffer: [128]u8 = undefined;
    var cmdWriter = std.Io.Writer.fixed(&cmdOutputBuffer);
    var cmdInputBuffer: [64]u8 = undefined;
    const cmdText = try promptText("Title: ", &cmdReader, &cmdWriter, &cmdInputBuffer);
    try std.testing.expectEqualStrings("world", cmdText);

    var cmdBsReader = std.Io.Reader.fixed("hello world\x1b[8;9u\n");
    var cmdBsOutputBuffer: [128]u8 = undefined;
    var cmdBsWriter = std.Io.Writer.fixed(&cmdBsOutputBuffer);
    var cmdBsInputBuffer: [64]u8 = undefined;
    const cmdBsText = try promptText("Title: ", &cmdBsReader, &cmdBsWriter, &cmdBsInputBuffer);
    try std.testing.expectEqualStrings("", cmdBsText);
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

test "collectUniqueLines merges newline lists without duplicates" {
    var out: [8][]const u8 = undefined;
    var outLen: usize = 0;

    try collectUniqueLines("alice\nbob\n", &out, &outLen);
    try collectUniqueLines("org/team\nbob\n", &out, &outLen);
    const values = out[0..outLen];

    try std.testing.expectEqual(@as(usize, 3), values.len);
    try std.testing.expectEqualStrings("alice", values[0]);
    try std.testing.expectEqualStrings("bob", values[1]);
    try std.testing.expectEqualStrings("org/team", values[2]);
}

test "reviewerDisplayHandle uses slack mapping when available" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var homeBuffer: [std.fs.max_path_bytes]u8 = undefined;
    const home = try tmp.dir.realpath(".", &homeBuffer);

    var config = try Config.initWithHome("ppr-test-reviewer-display", home, "");
    defer config.deinit();
    try config.putMapping("alice", "@alice.slack");

    try std.testing.expectEqualStrings("@alice.slack", reviewerDisplayHandle("alice", &config));
    try std.testing.expectEqualStrings("org/team", reviewerDisplayHandle("org/team", &config));
}

test "pickMultiple selects options with arrow keys and space" {
    const options = [_][]const u8{ "alice", "bob", "org/team" };
    var reader = std.Io.Reader.fixed("\x1b[B \x1b[B \n");
    var outputBuffer: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&outputBuffer);
    var selectedBuffer: [3][]const u8 = undefined;

    const selected = try pickMultiple(options[0..], &reader, &writer, &selectedBuffer);
    try std.testing.expectEqual(@as(usize, 2), selected.len);
    try std.testing.expectEqualStrings("bob", selected[0]);
    try std.testing.expectEqualStrings("org/team", selected[1]);
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

    const reviewers = [_][]const u8{ "alice", "bob" };
    var msgBuffer: [512]u8 = undefined;
    const message = try generateSlackMessage(
        "Fix race condition",
        "https://github.com/acme/repo/pull/123",
        reviewers[0..],
        &config,
        &msgBuffer,
    );

    try std.testing.expectEqualStrings(
        ":open-pr: [Fix race condition](https://github.com/acme/repo/pull/123) @alice.slack / @bob",
        message,
    );
}
