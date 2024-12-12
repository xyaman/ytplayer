const std = @import("std");
const c = @cImport({
    @cInclude("portaudio.h");
});

const yt = @import("youtube.zig");
const Audio = @import("audio.zig").Audio;

const SAMPLE_RATE = 44100;
const BUFFER_SIZE = 2048;
const CHANNELS = 2;

var should_run: bool = true;

fn sigintHandler(sig: c_int) callconv(.C) void {
    _ = sig;
    should_run = false;
    std.log.info("SIGINT received...\nExiting", .{});
}

pub fn main() !void {
    var args = std.process.args();
    const exe = args.next().?;

    const url = args.next() orelse {
        std.log.err("You need to specify an url\nEx: {s} 'https://www.youtube.com/watch?v=HRlW6yZo6Kc'", .{exe});
        std.process.exit(1);
    };

    // start of program
    std.posix.sigaction(std.posix.SIG.INT, &std.posix.Sigaction{
        .handler = .{ .handler = sigintHandler },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    }, null);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var audio = try Audio.init(CHANNELS, SAMPLE_RATE, BUFFER_SIZE);
    defer audio.deinit();

    var yt_stream = yt.YTDLStream.init(allocator, CHANNELS, SAMPLE_RATE);
    defer yt_stream.deinit();

    try yt_stream.play(url);

    var buffer: [BUFFER_SIZE * CHANNELS * @sizeOf(f32)]f32 = undefined;
    while (should_run) {
        const bytes_read = try yt_stream.stdout.read(std.mem.sliceAsBytes(&buffer));
        if (bytes_read == 0) break;
        audio.write(f32, &buffer, bytes_read / (CHANNELS * @sizeOf(f32))) catch {};
    }
}
