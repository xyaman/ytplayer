const std = @import("std");
const c = @cImport({
    @cInclude("portaudio.h");
});

const clap = @import("clap");

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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-s, --search <str>     Search tracks by query.
        \\<str>                  Youtube url
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
    }

    var url: []const u8 = undefined;

    if (res.positionals[0]) |pos| {
        url = pos;
    } else {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("You need to specify an url\nUSAGE:\n", .{});
        return clap.help(stderr, clap.Help, &params, .{});
    }

    // start of program
    std.posix.sigaction(std.posix.SIG.INT, &std.posix.Sigaction{
        .handler = .{ .handler = sigintHandler },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    }, null);

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
