const std = @import("std");
const mibu = @import("mibu");
const assert = std.debug.assert;

pub const Cell = struct {
    /// UTF-8 slice representing the character to display.
    /// Don't set this value directly, use `setCh`
    ch: []const u8 = " ",

    /// `is_wide` is set automatically when `setCh` is called
    is_wide: bool = false,

    /// The consumer should write this value
    is_continuation: bool = false,

    /// Stores up to 4 bytes for a UTF-8 character.
    /// Read-only
    utf8_ch: struct { value: [4]u8, len: u3 } = .{
        .value = [_]u8{ ' ', 0, 0, 0 },
        .len = 1,
    },

    /// Sets the cell's character from a UTF-8 codepoint slice.
    pub inline fn setCh(self: *@This(), codepoint: []const u8) void {
        const len = std.unicode.utf8ByteSequenceLength(codepoint[0]) catch 1;
        const copy_len = @min(codepoint.len, len, 4);
        @memcpy(self.utf8_ch.value[0..copy_len], codepoint[0..copy_len]);

        self.ch = self.utf8_ch.value[0..self.utf8_ch.len];
        self.is_wide = isWideCharacter(self.ch, self.utf8_ch.len);
        self.utf8_ch.len = @intCast(copy_len);
    }
};

fn isWideCharacter(ch2: []const u8, len: u3) bool {
    const ch = switch (len) {
        1 => ch2[0],
        2 => std.unicode.utf8Decode2(ch2[0..2].*) catch @panic("utf8Decode2"),
        3 => std.unicode.utf8Decode3(ch2[0..3].*) catch @panic("utf8Decode3"),
        4 => std.unicode.utf8Decode4(ch2[0..4].*) catch @panic("utf8Decode4"),
        else => unreachable,
    };

    // Control characters have zero width
    if (ch < 0x20 or (ch >= 0x7F and ch < 0xA0)) {
        return false;
    }

    // ASCII characters are narrow
    if (ch < 0x7F) {
        return false;
    }

    // Wide character ranges (CJK, emojis, etc.)
    return (ch >= 0x1100 and ch <= 0x115F) or // Hangul Jamo

        (ch >= 0x2E80 and ch <= 0x2EFF) or // CJK Radicals
        (ch >= 0x2F00 and ch <= 0x2FDF) or // Kangxi Radicals
        (ch >= 0x3000 and ch <= 0x303F) or // CJK Symbols
        (ch >= 0x3040 and ch <= 0x309F) or // Hiragana
        (ch >= 0x30A0 and ch <= 0x30FF) or // Katakana
        (ch >= 0x3100 and ch <= 0x312F) or // Bopomofo
        (ch >= 0x3130 and ch <= 0x318F) or // Hangul Compatibility
        (ch >= 0x3400 and ch <= 0x4DBF) or // CJK Extension A
        (ch >= 0x4E00 and ch <= 0x9FFF) or // CJK Unified Ideographs

        (ch >= 0xAC00 and ch <= 0xD7AF) or // Hangul Syllables
        (ch >= 0xF900 and ch <= 0xFAFF) or // CJK Compatibility
        (ch >= 0xFF00 and ch <= 0xFFEF) or // Fullwidth Forms
        (ch >= 0x1F000 and ch <= 0x1F9FF) or // Emojis
        (ch >= 0x20000 and ch <= 0x2A6DF) or // CJK Extension B
        (ch >= 0x2A700 and ch <= 0x2B73F) or // CJK Extension C

        (ch >= 0x2B740 and ch <= 0x2B81F) or // CJK Extension D
        (ch >= 0x2B820 and ch <= 0x2CEAF) or // CJK Extension E
        (ch >= 0x2CEB0 and ch <= 0x2EBEF); // CJK Extension F
}

pub const Canvas = struct {
    allocator: std.mem.Allocator,
    buffers: [2][]Cell,
    curr_buffer: u2,

    w: usize,
    h: usize,

    pub fn init(allocator: std.mem.Allocator, w: usize, h: usize) !@This() {
        const buffers = [_][]Cell{
            try allocator.alloc(Cell, w * h),
            try allocator.alloc(Cell, w * h),
        };

        @memset(buffers[0], .{});
        @memset(buffers[1], .{});

        return .{
            .allocator = allocator,
            .buffers = buffers,
            .curr_buffer = 0,
            .w = w,
            .h = h,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.buffers[0]);
        self.allocator.free(self.buffers[1]);
    }

    pub fn currBuffer(self: @This()) []Cell {
        return self.buffers[self.curr_buffer];
    }

    /// 0-based index
    /// Does not support wrap for the moment. It just stops writing if x > width
    pub fn addText(self: *@This(), sx: usize, sy: usize, text: []const u8) !void {
        const buf = self.buffers[self.curr_buffer];
        var utf8 = (try std.unicode.Utf8View.init(text)).iterator();
        var x: usize = sx;
        while (utf8.nextCodepointSlice()) |codepoint| : (x += 1) {
            if (x >= self.w) break;
            if (sy * self.w + x >= buf.len) break;

            const len = std.unicode.utf8ByteSequenceLength(codepoint[0]) catch @panic("utf8ByteSequenceLength");
            const is_wide = isWideCharacter(codepoint, len);
            if (is_wide and x + 1 >= self.w) break;

            // check if there is already a wide character that we need to clean
            var cell = &buf[sy * self.w + x];
            if (cell.*.is_continuation) {
                // we are trying to overwrite a continuation cell
                // we need to clear the primary too
                assert(x > 0);
                const prev_cell = &buf[sy * self.w + x - 1];
                assert(prev_cell.*.is_wide); // the previous before continuation must be always be wide
                prev_cell.* = .{};
            }

            // If we're placing a character where a wide char starts, clear its continuation
            if (cell.*.is_wide) {
                assert(x + 1 < buf.len);
                const next_cell = &buf[sy * self.w + x + 1];
                assert(next_cell.*.is_continuation); // the cell next to wide must be continuation
                next_cell.* = .{};
            }

            cell.setCh(codepoint);
            // if wide set next as continuation and advance one more cell
            if (is_wide) {
                const next_cell = &buf[sy * self.w + x + 1];
                next_cell.*.is_continuation = true;
                x += 1;
            }
        }
    }

    pub fn draw(self: *@This(), out: *std.Io.Writer, focus: anytype) !void {
        const buf = self.buffers[self.curr_buffer];
        const prev = self.buffers[1 - self.curr_buffer];

        try mibu.cursor.hide(out);

        var y: usize = 0;
        while (y < self.h) : (y += 1) {
            try mibu.cursor.goTo(out, 1, y + 1);
            var x: usize = 0;
            while (x < self.w) : (x += 1) {
                const i = y * self.w + x;
                if (!std.mem.eql(u8, buf[i].ch, prev[i].ch)) {
                    try out.print("{s}", .{buf[i].ch});
                } else {
                    try mibu.cursor.goTo(out, x + 2, y + 1);
                }
            }
        }

        self.curr_buffer = 1 - self.curr_buffer;
        @memset(self.buffers[self.curr_buffer], .{});

        if (@typeInfo(@TypeOf(focus)) != .null) {
            try focus.focused(self, out);
        } else {
            try mibu.cursor.hide(out);
        }
    }
};

pub const InputOption = struct {
    x: usize = 0,
    y: usize = 0,
    width: usize = 16,
    placeholder: []const u8 = "",
    border: bool = false,
    border_horizontal: []const u8 = "-",
    border_vertical: []const u8 = "|",
    border_corner: []const u8 = "+",
};

pub const InputText = struct {
    allocator: std.mem.Allocator,
    inner: std.array_list.Managed(u8),
    placeholder: []const u8,

    x: usize,
    y: usize,
    width: usize, // width of input area (excluding border)

    // Border configuration
    border: bool = false,
    border_horizontal: []const u8 = "-",
    border_vertical: []const u8 = "|",
    border_corner: []const u8 = "+",

    pub fn init(allocator: std.mem.Allocator, opt: InputOption) @This() {
        return .{
            .allocator = allocator,
            .inner = std.array_list.Managed(u8).init(allocator),
            .placeholder = opt.placeholder,
            .x = opt.x,
            .y = opt.y,
            .width = opt.width,
            .border = opt.border,
            .border_horizontal = opt.border_horizontal,
            .border_vertical = opt.border_vertical,
            .border_corner = opt.border_corner,
        };
    }

    pub fn insertFromSlice(self: *@This(), slice: []u21) !void {
        try self.inner.appendSlice(slice);
    }

    pub fn insertChar(self: *@This(), c: u21) !void {
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(c, &buf);
        try self.inner.appendSlice(buf[0..len]);
    }

    pub fn pop(self: *@This()) !?u8 {
        return self.inner.pop();
    }

    pub fn draw(self: @This(), screen: *Canvas, _: usize, _: usize) !void {
        const text = if (self.inner.items.len > self.width)
            self.inner.items[self.inner.items.len - self.width .. self.inner.items.len]
        else
            self.inner.items;

        if (self.border) {
            // Top border
            try screen.addText(self.x, self.y, self.border_corner);
            for (0..self.width) |i| {
                try screen.addText(self.x + 1 + i, self.y, self.border_horizontal);
            }
            try screen.addText(self.x + self.width + 1, self.y, self.border_corner);

            // Bottom border
            try screen.addText(self.x, self.y + 2, self.border_corner);
            for (0..self.width) |i| {
                try screen.addText(self.x + 1 + i, self.y + 2, self.border_horizontal);
            }
            try screen.addText(self.x + self.width + 1, self.y + 2, self.border_corner);

            // Left and right borders
            try screen.addText(self.x, self.y + 1, self.border_vertical);
            try screen.addText(self.x + self.width + 1, self.y + 1, self.border_vertical);

            // Input text or placeholder inside border
            if (self.inner.items.len == 0) {
                try screen.addText(self.x + 1, self.y + 1, self.placeholder);
            } else {
                try screen.addText(self.x + 1, self.y + 1, text);
            }
        } else {
            if (self.inner.items.len == 0) {
                try screen.addText(self.x, self.y + 1, self.placeholder);
            } else {
                try screen.addText(self.x, self.y + 1, text);
            }
        }
    }

    pub fn focused(self: *@This(), _: *Canvas, out: *std.Io.Writer) !void {
        const x = @min(self.x + self.width, self.x + self.inner.items.len);

        try mibu.cursor.goTo(out, x + 2, self.y + 2);
        try mibu.cursor.show(out);
    }

    pub fn deinit(self: *@This()) void {
        self.inner.deinit();
    }
};
