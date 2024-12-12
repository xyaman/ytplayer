const std = @import("std");

const TrackInfo = struct {
    id: []u8,
    title: []u8,
    duration: []u8,

    allocator: std.mem.Allocator,

    pub fn deinit(self: @This()) void {
        self.allocator.free(self.id);
        self.allocator.free(self.title);
        self.allocator.free(self.duration);
    }
};

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
    child.stderr_behavior = .Ignore;
    child.stdin_behavior = .Close;

    try child.spawn();
    defer _ = child.kill() catch {};

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var info = TrackInfo{
        .id = "",
        .allocator = allocator,
        .title = "",
        .duration = "",
    };

    while (child.stdout.?.reader().streamUntilDelimiter(buffer.writer(), '\n', null)) {
        defer buffer.clearRetainingCapacity();

        switch (buffer.items[0]) {
            'I' => {
                info.id = try allocator.dupe(u8, buffer.items[1..]);
            },
            'T' => {
                info.title = try allocator.dupe(u8, buffer.items[1..]);
            },
            'D' => {
                info.duration = try allocator.dupe(u8, buffer.items[1..]);
            },

            else => {},
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }

    return info;
}

pub const YTDLStream = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    stdout: std.fs.File,

    channels: usize,
    sample_rate: usize,

    current_track: ?TrackInfo,

    /// Must call `YTDL.deinit()`
    pub fn init(allocator: std.mem.Allocator, channels: usize, sample_rate: usize) YTDLStream {
        return .{
            .allocator = allocator,
            .child = undefined,
            .stdout = undefined,
            .channels = channels,
            .sample_rate = sample_rate,
            .current_track = null,
        };
    }

    pub fn play(self: *@This(), url: []const u8) !void {
        if (self.current_track) |current_track| {
            current_track.deinit();
        }

        // const command = [_][]const u8{ "sh", "-c", std.fmt.comptimePrint("yt-dlp -o - {s}  2> yt-dlp.out | ffmpeg -i pipe:0 -ac {d} -ar {d} -f u8 pipe:1 2> /dev/null", .{ url, CHANNELS, SAMPLE_RATE }) };
        // TODO: consider using heap instead of stack
        var cmd_buffer: [2048]u8 = undefined;
        const cmd_print = try std.fmt.bufPrint(&cmd_buffer, "yt-dlp --quiet --ignore-errors --flat-playlist -o - {s}  2> yt-dlp.out | ffmpeg -i pipe:0 -vn -ac {d} -ar {d} -f f32le pipe:1 2> ffmpeg.out", .{ url, self.channels, self.sample_rate });
        const command = [_][]const u8{ "sh", "-c", cmd_print };

        self.child = std.process.Child.init(&command, self.allocator);
        self.child.stdin_behavior = .Close;
        self.child.stderr_behavior = .Close;
        self.child.stdout_behavior = .Pipe;

        try self.child.spawn();
        self.stdout = self.child.stdout.?;

        self.current_track = try getTrackInfo(self.allocator, url);
        const id = self.current_track.?.id;
        const title = self.current_track.?.title;
        const duration = self.current_track.?.duration;

        std.log.info("Playing: (?v={s}) {s} - {s}", .{id, title, duration});
    }

    pub fn stop(self: *@This()) void {
        _ = self.child.kill() catch {};
        self.current_track = null;
    }

    pub fn deinit(self: *YTDLStream) void {
        _ = self.child.kill() catch {};
        if (self.current_track) |track| track.deinit();
    }
};
