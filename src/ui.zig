const std = @import("std");
const mibu = @import("mibu");

pub const Cell = struct {
    v: u8 = ' ',
    changed: bool = false,
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

        var x: usize = sx;
        while (x - sx < text.len) : (x += 1) {
            if (x >= self.w) break;
            if (sy * self.w + x >= buf.len) break;
            buf[sy * self.w + x].v = text[x - sx];
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
                if (buf[i].changed or buf[i].v != prev[i].v) {
                    try out.print("{c}", .{buf[i].v});
                } else {
                    // try out.print("#", .{});
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
