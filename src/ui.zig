const std = @import("std");
const mibu = @import("mibu");

pub const Cell = struct {
    // unicode character (0 for continuation cells; wide chars)
    ch: []const u8 = " ",
    changed: bool = false,

    pub fn isContinuation(self: *@This()) bool {
        return self.ch == '0';
    }

    pub fn isWide(self: *@This()) bool {
        // Control characters have zero width
        if (self.ch < 0x20 or (self.ch >= 0x7F and self.ch < 0xA0)) {
            return false;
        }

        // ASCII characters are narrow
        if (self.ch < 0x7F) {
            return false;
        }

        // Wide character ranges (CJK, emojis, etc.)

        return (self.ch >= 0x1100 and self.ch <= 0x115F) or // Hangul Jamo

            (self.ch >= 0x2E80 and self.ch <= 0x2EFF) or // CJK Radicals
            (self.ch >= 0x2F00 and self.ch <= 0x2FDF) or // Kangxi Radicals
            (self.ch >= 0x3000 and self.ch <= 0x303F) or // CJK Symbols
            (self.ch >= 0x3040 and self.ch <= 0x309F) or // Hiragana
            (self.ch >= 0x30A0 and self.ch <= 0x30FF) or // Katakana
            (self.ch >= 0x3100 and self.ch <= 0x312F) or // Bopomofo
            (self.ch >= 0x3130 and self.ch <= 0x318F) or // Hangul Compatibility
            (self.ch >= 0x3400 and self.ch <= 0x4DBF) or // CJK Extension A
            (self.ch >= 0x4E00 and self.ch <= 0x9FFF) or // CJK Unified Ideographs

            (self.ch >= 0xAC00 and self.ch <= 0xD7AF) or // Hangul Syllables
            (self.ch >= 0xF900 and self.ch <= 0xFAFF) or // CJK Compatibility
            (self.ch >= 0xFF00 and self.ch <= 0xFFEF) or // Fullwidth Forms
            (self.ch >= 0x1F000 and self.ch <= 0x1F9FF) or // Emojis
            (self.ch >= 0x20000 and self.ch <= 0x2A6DF) or // CJK Extension B
            (self.ch >= 0x2A700 and self.ch <= 0x2B73F) or // CJK Extension C

            (self.ch >= 0x2B740 and self.ch <= 0x2B81F) or // CJK Extension D
            (self.ch >= 0x2B820 and self.ch <= 0x2CEAF) or // CJK Extension E
            (self.ch >= 0x2CEB0 and self.ch <= 0x2EBEF); // CJK Extension F
    }
};

pub const Screen = struct {
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
    /// TODO: change u8 to []const u8
    pub fn add(self: *@This(), x: usize, y: usize, c: u8) void {
        if (x < 1 or x > self.w or y < 1 or y > self.h) {
            return;
        }

        var buf = self.buffers[self.curr_buffer];
        buf[y * self.w + x] = c;
    }

    /// 0-based index
    /// Does not support wrap for the moment.
    pub fn addText(self: *@This(), sx: usize, sy: usize, text: []const u8) void {
        var buf = self.buffers[self.curr_buffer];
        var utf8 = (std.unicode.Utf8View.init(text) catch unreachable).iterator();
        var x: usize = sx;
        while (utf8.nextCodepointSlice()) |codepoint| : (x += 1) {
            if (x >= self.w) break;
            if (sy * self.w + x >= buf.len) break;
            buf[sy * self.w + x].ch = codepoint;
            buf[sy * self.w + x].changed = true;
        }
    }

    pub fn cleanDraw(_: @This(), out: std.io.AnyWriter) !void {
        try mibu.clear.all(out);
    }

    pub fn draw(self: *@This(), out: std.io.AnyWriter, focus: anytype) !void {
        const buf = self.buffers[self.curr_buffer];
        const prev = self.buffers[1 - self.curr_buffer];

        try mibu.cursor.hide(out);

        var y: usize = 0;
        while (y < self.h) : (y += 1) {
            try mibu.cursor.goTo(out, 1, y + 1);
            var x: usize = 0;
            while (x < self.w) : (x += 1) {
                const i = y * self.w + x;
                if (buf[i].changed or !std.mem.eql(u8, buf[i].ch, prev[i].ch)) {
                    try out.print("{s}", .{buf[i].ch});
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

        // if (focus) |f| try f.focused(self, out)
        // else try mibu.cursor.hide(out);

    }
};

pub const InputText = struct {
    allocator: std.mem.Allocator,
    inner: std.ArrayList(u8),

    x: usize,
    y: usize,

    pub fn init(allocator: std.mem.Allocator, x: usize, y: usize) @This() {
        return .{
            .allocator = allocator,
            .inner = std.ArrayList(u8).init(allocator),
            .x = x,
            .y = y,
        };
    }

    pub fn insertFromSlice(self: *@This(), slice: []u21) !void {
        try self.inner.appendSlice(slice);
    }

    pub fn insertChar(self: *@This(), c: u8) !void {
        try self.inner.append(c);
    }

    pub fn pop(self: *@This()) !?u8 {
        return self.inner.popOrNull();
    }

    pub fn draw(self: @This(), screen: *Screen, _: usize, _: usize) void {
        screen.addText(self.x, self.y, "search: ");
        if (self.inner.items.len == 0) {
            screen.addText(self.x, self.y + 1, "...");
        } else {
            screen.addText(self.x, self.y + 1, self.inner.items);
        }
    }

    pub fn focused(self: *@This(), _: *Screen, out: std.io.AnyWriter) !void {
        const x = self.x + self.inner.items.len;
        try mibu.cursor.goTo(out, x + 1, self.y + 2);
        try mibu.cursor.show(out);
    }

    pub fn deinit(self: *@This()) void {
        self.inner.deinit();
    }
};

pub const List = struct {
    allocator: std.mem.Allocator,
    inner: std.ArrayList([]const u8),
    curr_id: i16,

    x: usize,
    y: usize,

    pub fn init(allocator: std.mem.Allocator, x: usize, y: usize) @This() {
        return .{
            .allocator = allocator,
            .inner = std.ArrayList([]const u8).init(allocator),
            .curr_id = 0,
            .x = x,
            .y = y,
        };
    }

    pub fn insertFromSlice(self: *@This(), slice: [][]const u8) !void {
        try self.inner.appendSlice(slice);
    }

    pub fn draw(self: @This(), screen: *Screen, _: usize, _: usize) void {
        for (self.inner.items, 0..) |it, i| {
            if (i == self.curr_id) {
                screen.addText(self.x, self.y + i, "> ");
                screen.addText(self.x + 2, self.y + i, it);
            } else {
                screen.addText(self.x, self.y + i, it);
            }
        }
    }

    pub fn focused(self: *@This(), _: *Screen, out: std.io.AnyWriter) !void {
        const y = self.y + self.inner.items.len;
        try mibu.cursor.goTo(out, self.x + 1, y + 1);
        try mibu.cursor.show(out);
    }

    pub fn deinit(self: *@This()) void {
        self.inner.deinit();
    }
};
