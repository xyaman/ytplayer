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

    const stdin = std.io.getStdIn();
    const stdout = std.io.getStdOut().writer();

    try mibu.term.enterAlternateScreen(stdout);
    defer {
        mibu.term.exitAlternateScreen(stdout) catch {};
        stdout.print("\r", .{}) catch {};
        defer mibu.cursor.show(stdout) catch {};
    }

    const ws = try mibu.term.getSize(0);
    var screen = try ui.Screen.init(allocator, ws.width, ws.height);
    defer screen.deinit();

    var input = ui.InputText.init(allocator, 0, 4);
    defer input.deinit();

    var list = ui.List.init(allocator, 0, 7);
    defer list.deinit();

    var tracks: ?[]yt.TrackInfo = null;
    defer {
        if (tracks) |t| allocator.free(t);
    }

    const Focus = enum {
        input,
        list,
        none,
    };

    var currfocus = Focus.none;

    var pause = true;
    while (should_run) {
        const event = try mibu.events.next(stdin);

        switch (event) {
            .key => |k| {
                if (k.char) |char| {
                    if (currfocus == .input) {
                        try input.insertChar(char);
                    } else if (currfocus == .none and char == 'i') {
                        currfocus = .input;
                    }

                    if (currfocus == .list and !k.mods.ctrl) {
                        switch (char) {
                            'j' => list.curr_id += 1,
                            'k' => list.curr_id -= 1,
                            else => {},
                        }
                    }

                    if (k.mods.ctrl) switch (char) {
                        'c' => should_run = false,
                        'l' => try screen.cleanDraw(stdout.any()),
                        'p' => pause = !pause,
                        else => {},
                    };
                }

                if (k.special_key != .none) switch (k.special_key) {
                    .backspace => _ = try input.pop(),
                    .esc => currfocus = .none,
                    .enter => {
                        if (currfocus == .list) {
                            try yt_stream.playFromTrack(tracks.?[@intCast(list.curr_id)]);
                            pause = false;
                            list.inner.clearRetainingCapacity();
                            currfocus = .none;
                        }

                        if (currfocus == .input) {
                            if (tracks) |t| allocator.free(t);
                            tracks = try yt.search(allocator, input.inner.items, 20);
                            for (tracks.?) |*t| {
                                try list.inner.append(t.title.slice());
                            }

                            currfocus = .list;
                        }
                    },
                    else => {},
                };
            },
            else => {},
        }

        // show information
        // screen.addText(1, 1, "Music Player");

        const string = try std.fmt.allocPrint(allocator, "Music Player: {d}x{d}", .{ ws.width, ws.height });
        defer allocator.free(string);
        screen.addText(0, 0, string);

        if (pause) {
            screen.addText(0, 1, "Status: Pause");
        } else {
            screen.addText(0, 1, "Status: Playing");
        }

        input.draw(&screen, 0, 0);
        list.draw(&screen, 0, 0);

        switch (currfocus) {
            .input => try screen.draw(stdout.any(), &input),
            else => try screen.draw(stdout.any(), null),
        }
    }
}
