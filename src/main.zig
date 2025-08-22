const std = @import("std");
const c = @cImport({
    @cInclude("portaudio.h");
});

const mibu = @import("mibu");

const ui = @import("ui.zig");
const yt = @import("youtube.zig");
const Youtube = yt.Youtube;
const Audio = @import("audio.zig").Audio;

const SAMPLE_RATE = 44100;
const BUFFER_SIZE = 2048;
const CHANNELS = 2;

var should_run: bool = true;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // start of program

    var yt_stream = try Youtube.init(allocator, CHANNELS, SAMPLE_RATE, BUFFER_SIZE);
    defer yt_stream.deinit();

    var raw_term = try mibu.term.enableRawMode(0);
    defer raw_term.disableRawMode() catch {};

    const stdin_file = std.fs.File.stdout();

    var stdout_buffer: [1024]u8 = undefined;
    const stdout_file = std.fs.File.stdout();
    var stdout_writter = stdout_file.writer(&stdout_buffer);
    const stdout = &stdout_writter.interface;

    try mibu.term.enterAlternateScreen(stdout);
    try stdout.flush();

    defer {
        mibu.term.exitAlternateScreen(stdout) catch {};
        stdout.print("\r", .{}) catch {};
        mibu.cursor.show(stdout) catch {};
        stdout.flush() catch {};
    }

    const ws = try mibu.term.getSize(0);
    var canvas = try ui.Canvas.init(allocator, ws.width, ws.height);
    defer canvas.deinit();

    var input = ui.InputText.init(allocator, .{
        .x = 2,
        .y = 3,
        .width = 20,
        .placeholder = "Press i to write!",
        .border = true,
    });
    defer input.deinit();

    const Focus = enum {
        input,
        none,
    };

    var currfocus = Focus.none;

    var pause = true;
    while (should_run) {
        const event = try mibu.events.nextWithTimeout(stdin_file, 100);

        switch (event) {
            .key => |k| {
                if (k.char) |char| {
                    if (currfocus == .input) {
                        try input.insertChar(char);
                    } else if (currfocus == .none and char == 'i') {
                        currfocus = .input;
                    }

                    if (k.mods.ctrl) switch (char) {
                        'c' => should_run = false,
                        'p' => pause = !pause,
                        else => {},
                    };
                }

                if (k.special_key != .none) switch (k.special_key) {
                    .backspace => _ = try input.pop(),
                    .esc => currfocus = .none,
                    else => {},
                };
            },
            else => {},
        }

        const string = try std.fmt.allocPrint(allocator, "Music Player: {d}x{d}", .{ ws.width, ws.height });
        defer allocator.free(string);
        try canvas.addText(0, 0, string);

        try input.draw(&canvas, 0, 0);

        switch (currfocus) {
            .input => try canvas.draw(stdout, &input),
            else => try canvas.draw(stdout, null),
        }

        try stdout.flush();
    }
}
