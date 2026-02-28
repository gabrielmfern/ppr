const std = @import("std");

pub const CSI = "\x1b[";
pub const CSIClearScreen = "2J";
pub const CSICursorToStart = "H";
pub const SaveCursorPosition = "\x1b7";
pub const RestoreSavedCursorPosition = "\x1b8";
pub const CSIRequestCursorPosition = "6n";
pub inline fn CSIMoveCursorTo(
    comptime row: usize,
    comptime column: usize,
) *const [std.fmt.count("{d};{d}H", .{ row, column })]u8 {
    return std.fmt.comptimePrint("{d};{d}H", .{ row, column });
}
pub const CSIDim = "2m";
pub const CSIBold = "1m";
pub const CSIDimAndBoldReset = "22m";
pub inline fn CSIForeground(comptime color_id: u8) *const [std.fmt.count("38;5;{d}m", .{color_id})]u8 {
    return std.fmt.comptimePrint("38;5;{d}m", .{color_id});
}
pub inline fn CSIBackground(comptime color_id: u8) *const [std.fmt.count("48;5;{d}m", .{color_id})]u8 {
    return std.fmt.comptimePrint("48;5;{d}m", .{color_id});
}
pub const CSIGraphicReset = "0m";

pub const CSIArrowUp = "A";
pub const CSIArrowDown = "B";
pub const CSIArrowRight = "C";
pub const CSIArrowLeft = "D";

arena: std.heap.ArenaAllocator,

allocator: std.mem.Allocator,
stderr: *std.io.Writer,
tty: Tty,

component_states: std.AutoHashMap(u64, ComponentState),
component_cursor_index: usize,
component_resolution_state: ?ComponentResolutionState,

last_input: ?Input,

const ComponentState = struct {
    states: std.ArrayList(*anyopaque),
};

const ComponentResolutionState = struct {
    component_key: u64,
    state_cursor_index: usize,
};

/// This only includes the few keys that we're using, it does not at all, include all of the possible values
pub const Input = union(enum) {
    action: enum {
        ArrowDown,
        ArrowUp,
        ArrowLeft,
        ArrowRight,
        Enter,
        Backspace,
    },
    printable_ascii: u8,
};

pub const Tty = struct {
    file: std.fs.File,
    original_termios: std.posix.termios,

    pub fn init() !@This() {
        const tty = try std.fs.cwd().openFile(
            "/dev/tty",
            .{ .mode = .read_write },
        );
        return .{
            .file = tty,
            .original_termios = try std.posix.tcgetattr(tty.handle),
        };
    }

    pub fn enter_raw_mode(tty: *@This()) !void {
        var raw = tty.original_termios;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        try std.posix.tcsetattr(tty.file.handle, .FLUSH, raw);
    }

    pub fn deinit(tty: *@This()) void {
        std.posix.tcsetattr(tty.file.handle, .FLUSH, tty.original_termios) catch |err| {
            std.log.err("Failed to restore original terminal settings: {}", .{err});
        };
        tty.file.close();
    }
};

var self: @This() = undefined;

/// Allocator is expected to be an Arena that clears all of the data it
/// allocates automatically
pub fn init(
    allocator: std.mem.Allocator,
    stderr: *std.io.Writer,
    tty: Tty,
) !void {
    self = .{
        .arena = std.heap.ArenaAllocator.init(allocator),

        .allocator = allocator,
        .stderr = stderr,
        .tty = tty,

        .component_states = .init(allocator),
        .component_cursor_index = 0,
        .component_resolution_state = null,

        .last_input = null,
    };
}

pub fn get_terminal_size() !struct { width: usize, height: usize } {
    try write(SaveCursorPosition);
    try self.stderr.flush();
    try write(CSI ++ CSIMoveCursorTo(10_000, 10_000));
    try write(CSI ++ CSIRequestCursorPosition);
    try self.stderr.flush();

    // Read until we find the cursor position response (ESC [ row ; col R)
    // This handles the case where user input is in the buffer before the response
    var response_buf: [32]u8 = undefined;
    var response_len: usize = 0;
    var state: enum { waiting_for_esc, waiting_for_bracket, reading_response } = .waiting_for_esc;

    while (response_len < response_buf.len) {
        var byte: [1]u8 = undefined;
        const bytes_read = try self.tty.file.read(&byte);
        if (bytes_read == 0) break;

        switch (state) {
            .waiting_for_esc => {
                if (byte[0] == '\x1b') {
                    state = .waiting_for_bracket;
                }
                // Discard any other input (user typed characters)
            },
            .waiting_for_bracket => {
                if (byte[0] == '[') {
                    state = .reading_response;
                } else {
                    // Not a CSI sequence, go back to waiting
                    state = .waiting_for_esc;
                }
            },
            .reading_response => {
                if (byte[0] == 'R') {
                    // Found the end of the cursor position response
                    break;
                }
                response_buf[response_len] = byte[0];
                response_len += 1;
            },
        }
    }

    try write(RestoreSavedCursorPosition);
    try self.stderr.flush();

    const response = response_buf[0..response_len];
    if (std.mem.indexOf(u8, response, ";")) |semicolon_index| {
        const row_string = response[0..semicolon_index];
        const col_string = response[semicolon_index + 1 ..];

        const height = try std.fmt.parseInt(usize, row_string, 10);
        const width = try std.fmt.parseInt(usize, col_string, 10);

        return .{
            .width = width,
            .height = height,
        };
    } else {
        return error.CouldNotDetermineTerminalSize;
    }
}

pub fn use_stderr() *std.io.Writer {
    return self.stderr;
}

pub fn use_allocator() std.mem.Allocator {
    return self.allocator;
}

/// thin wrapper around stderr.write, for convenience
pub fn write(bytes: []const u8) !void {
    _ = try self.stderr.write(bytes);
}

/// thin wrapper around stderr.print, for convenience
pub fn print(comptime fmt: []const u8, args: anytype) !void {
    try self.stderr.print(fmt, args);
}

pub fn flush() !void {
    try self.stderr.flush();
}

/// Generally is just blocks until there's user input. But, if it's running
/// after input, it goes through, this time with `last_input = null` which
/// makes sure the entire text UI is rendered with respect to the state in sync
pub fn update() !void {
    if (self.last_input == null) {
        var buffer: [8]u8 = undefined;
        const bytes_read = try self.tty.file.read(&buffer);

        var input: ?Input = null;
        if (bytes_read >= 3 and std.mem.eql(u8, buffer[0..3], CSI ++ CSIArrowDown)) {
            input = Input{ .action = .ArrowDown };
        } else if (bytes_read >= 3 and std.mem.eql(u8, buffer[0..3], CSI ++ CSIArrowUp)) {
            input = Input{ .action = .ArrowUp };
        } else if (bytes_read >= 3 and std.mem.eql(u8, buffer[0..3], CSI ++ CSIArrowLeft)) {
            input = Input{ .action = .ArrowLeft };
        } else if (bytes_read >= 3 and std.mem.eql(u8, buffer[0..3], CSI ++ CSIArrowRight)) {
            input = Input{ .action = .ArrowLeft };
        } else if (bytes_read == 1 and buffer[0] == 13) {
            input = Input{ .action = .Enter };
        } else if (bytes_read == 1 and buffer[0] == 127) {
            input = Input{ .action = .Backspace };
        } else if (bytes_read == 1 and buffer[0] >= 32 and buffer[0] <= 126) {
            input = Input{ .printable_ascii = buffer[0] };
        }

        self.last_input = input;
    } else {
        self.last_input = null;
    }

    self.component_cursor_index = 0;
    defer _ = self.arena.reset(.retain_capacity);
}

pub fn use_state(T: type, initial_value: T) !*T {
    if (self.component_resolution_state) |*component_resolution_state| {
        const component_state = self.component_states.getPtr(component_resolution_state.component_key) orelse {
            return error.NoComponentContext;
        };
        defer component_resolution_state.state_cursor_index += 1;

        if (component_resolution_state.state_cursor_index < component_state.states.items.len) {
            return @ptrCast(@alignCast(component_state.states.items[component_resolution_state.state_cursor_index]));
        }

        const actual_state = try self.allocator.create(T);
        actual_state.* = initial_value;
        try component_state.states.append(self.allocator, @ptrCast(@alignCast(actual_state)));

        return actual_state;
    }

    return error.NoComponentContext;
}

inline fn ReturnType(comptime function: anytype) type {
    const Function = @TypeOf(function);
    const function_type_info = @typeInfo(Function);
    if (function_type_info != .@"fn") {
        @compileError("expected function to be a `fn`, but found " ++ @typeName(Function));
    }
    if (function_type_info.@"fn".return_type) |ReturnTypeT| {
        const return_type_info = @typeInfo(ReturnTypeT);
        if (return_type_info == .error_union) {
            return return_type_info.error_union.payload;
        }
        return ReturnTypeT;
    }
    return void;
}

pub inline fn component(comptime function: anytype, props: anytype) !ReturnType(function) {
    // TODO: this isn't fully safe safe with respect to removing and adding components
    const Function = @TypeOf(function);
    const function_type_info = @typeInfo(Function);
    if (function_type_info != .@"fn") {
        @compileError("expected function to be a `fn`, but found " ++ @typeName(Function));
    }
    if (function_type_info.@"fn".params.len != 1) {
        @compileError(
            "function components can only have one parameter `props`, found " ++ std.fmt.comptimePrint("{d}", .{function_type_info.@"fn".params.len}),
        );
    }
    const function_name = @typeName(Function);
    const function_identifier: []const u8 = if (function_type_info.@"fn".is_generic)
        function_name[0..]
    else
        std.mem.asBytes(&@intFromPtr(&function));

    var key_hasher = std.hash.Wyhash.init(0);
    key_hasher.update(std.mem.asBytes(&self.component_cursor_index));
    key_hasher.update(function_identifier);
    const component_key = key_hasher.final();
    self.component_cursor_index += 1;

    const component_state_result = try self.component_states.getOrPut(component_key);
    if (!component_state_result.found_existing) {
        component_state_result.value_ptr.* = .{
            .states = try std.ArrayList(*anyopaque).initCapacity(self.allocator, 0),
        };
    }

    const previous_component_resolution_state = self.component_resolution_state;
    self.component_resolution_state = .{
        .component_key = component_key,
        .state_cursor_index = 0,
    };
    defer self.component_resolution_state = previous_component_resolution_state;

    const raw_return_value = function(props);
    const return_value: ReturnType(function) = switch (@typeInfo(@TypeOf(raw_return_value))) {
        .error_union => try raw_return_value,
        else => raw_return_value,
    };

    const used_state_count = self.component_resolution_state.?.state_cursor_index;
    const component_state = self.component_states.get(component_key) orelse {
        return error.NoComponentContext;
    };
    if (used_state_count < component_state.states.items.len) {
        return error.RulesOfHooksViolated;
    }

    return return_value;
}

pub fn use_last_input() ?Input {
    return self.last_input;
}
