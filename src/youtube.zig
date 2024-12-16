const std = @import("std");
const audio = @import("audio.zig");

const SAMPLE_RATE = 44100;
const BUFFER_SIZE = 2048;
const CHANNELS = 2;

pub const TrackInfo = struct {
    url: std.BoundedArray(u8, 64),
    title: std.BoundedArray(u8, 256),
    duration: std.BoundedArray(u8, 16),
};

fn parseTrack(info: *TrackInfo, buffer: []const u8) !void {
    if (buffer.len == 0) return;

    switch (buffer[0]) {
        'I' => {
            if (buffer.len > 64) return error.TrackIndexTooLong;
            info.url = try std.BoundedArray(u8, 64).fromSlice(buffer[1..]);
        },
        'T' => {
            if (buffer.len > 256) return error.TrackTitleTooLong;
            info.title = try std.BoundedArray(u8, 256).fromSlice(buffer[1..]);
        },
        'D' => {
            if (buffer.len > 16) return error.TrackDurationTooLong;
            info.duration = try std.BoundedArray(u8, 16).fromSlice(buffer[1..]);
        },
        else => {},
    }
}

/// This function will also free the memory
fn getTrackInfo(allocator: std.mem.Allocator, url: []const u8) !TrackInfo {
    var child = std.process.Child.init(&.{
        "yt-dlp",
        "--quiet",
        "--skip-download",
        "--no-download",
        "--ignore-errors",
        "--flat-playlist",
        "--print",
        "I%(id)s\nT%(title)s\nD%(duration_string)s",
        url,
    }, allocator);

    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Close;
    child.stdin_behavior = .Close;

    try child.spawn();
    defer _ = child.kill() catch {};

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var info = TrackInfo{
        .url = undefined,
        .title = undefined,
        .duration = undefined,
    };

    while (child.stdout.?.reader().streamUntilDelimiter(buffer.writer(), '\n', null)) {
        defer buffer.clearRetainingCapacity();
        try parseTrack(&info, buffer.items);
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }

    return info;
}

/// The caller is responsible of freeing the pointer
pub fn search(allocator: std.mem.Allocator, query: []const u8, n: usize) ![]TrackInfo {
    var searchbuf: [512]u8 = undefined;

    var child = std.process.Child.init(&.{
        "yt-dlp",
        "--print",
        "I%(id)s\tT%(title)s\tD%(duration_string)s",
        try std.fmt.bufPrint(&searchbuf, "ytsearch{d}:{s}", .{ n, query }),
        "--no-download",
        "--skip-download",
        "--quiet",
        "--ignore-errors",
        "--flat-playlist",
    }, allocator);

    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Close;
    child.stdin_behavior = .Close;

    try child.spawn();
    defer _ = child.kill() catch {};

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var res = try allocator.alloc(TrackInfo, n);

    var i: usize = 0;
    while (child.stdout.?.reader().streamUntilDelimiter(buffer.writer(), '\n', null)) : (i += 1) {
        defer buffer.clearRetainingCapacity();
        var info = TrackInfo{
            .url = undefined,
            .title = undefined,
            .duration = undefined,
        };

        // line
        var iter = std.mem.splitAny(u8, buffer.items, "\t");
        while (iter.next()) |e| {
            try parseTrack(&info, e);
        }

        res[i] = info;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }

    return res;
}

fn writeAudioFn(self: *Youtube) !void {
    var buffer: [BUFFER_SIZE * CHANNELS * @sizeOf(f32)]f32 = undefined;
    while (true) {
        if (self.child == null) break;
        if (self.stream_should_stop.load(.seq_cst)) break;

        const bytes_read = try self.child.?.stdout.?.read(std.mem.sliceAsBytes(&buffer));
        if (bytes_read == 0) break;
        self.audio.write(f32, &buffer, bytes_read / (CHANNELS * @sizeOf(f32))) catch {};
    }

    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.child) |*c| _ = try c.kill();
}

pub const Youtube = struct {
    allocator: std.mem.Allocator,
    child: ?std.process.Child,

    audio: audio.Audio,
    stream_th: ?std.Thread,
    mutex: std.Thread.Mutex,
    stream_should_stop: std.atomic.Value(bool),

    channels: usize,
    sample_rate: usize,
    buffer_size: usize,

    current_track: ?TrackInfo,

    /// Must call `YTDL.deinit()`
    pub fn init(allocator: std.mem.Allocator, channels: usize, sample_rate: usize, buffer_size: usize) !Youtube {
        return .{
            .allocator = allocator,
            .child = null,
            .audio = try audio.Audio.init(channels, sample_rate, buffer_size),
            .stream_th = null,
            .mutex = .{},
            .stream_should_stop = std.atomic.Value(bool).init(false),

            .channels = channels,
            .sample_rate = sample_rate,
            .buffer_size = buffer_size,
            .current_track = null,
        };
    }

    pub fn deinit(self: *Youtube) void {
        if (self.child) |*c| {
            _ = c.kill() catch {};
        }
        self.audio.deinit();
    }

    pub fn playFromTrack(self: *@This(), track: TrackInfo) !void {
        self.current_track = track;
        try self.play(track.url.slice());
    }

    pub fn playFromUrl(self: *@This(), url: []const u8) !void {
        self.current_track = try getTrackInfo(self.allocator, url);
        try self.play(url);
    }

    fn play(self: *@This(), url: []const u8) !void {

        if (self.child) |*c| {
            _ = try c.kill();
        }
        // const command = [_][]const u8{ "sh", "-c", std.fmt.comptimePrint("yt-dlp -o - {s}  2> yt-dlp.out | ffmpeg -i pipe:0 -ac {d} -ar {d} -f u8 pipe:1 2> /dev/null", .{ url, CHANNELS, SAMPLE_RATE }) };
        // TODO: consider using heap instead of stack
        var cmd_buffer: [2048]u8 = undefined;
        const cmd_print = try std.fmt.bufPrint(&cmd_buffer, "yt-dlp --quiet --ignore-errors --flat-playlist -o - {s}  2> yt-dlp.out | ffmpeg -i pipe:0 -vn -ac {d} -ar {d} -f f32le pipe:1 2> ffmpeg.out", .{ url, self.channels, self.sample_rate });
        const command = [_][]const u8{ "sh", "-c", cmd_print };

        self.stream_should_stop.store(true, .seq_cst);
        if (self.stream_th) |th| {
            th.join();
            self.stream_th = null;
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        self.child = std.process.Child.init(&command, self.allocator);
        self.child.?.stdin_behavior = .Ignore;
        self.child.?.stdout_behavior = .Pipe;
        self.child.?.stderr_behavior = .Ignore;
        try self.child.?.spawn();

        if (self.stream_th == null) {
            self.stream_should_stop.store(false, .seq_cst);
            self.stream_th = try std.Thread.spawn(.{}, writeAudioFn, .{self});
        }
    }

    pub fn stop(self: *@This()) void {
        if (self.child) |*c| {
            _ = c.kill() catch {};
        }
        self.current_track = null;
    }
};
