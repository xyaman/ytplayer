const std = @import("std");
const c = @cImport({
    @cInclude("portaudio.h");
});

pub const Audio = struct {
    stream: ?*c.PaStream,
    pa_err: c.PaError,

    pub fn init(channels: usize, sample_rate: usize, buffer_size: usize) !Audio {
        // initialize portaudio
        var pa_err: c.PaError = c.paNoError;
        pa_err = c.Pa_Initialize();

        std.log.info("Initializing PortAudio", .{});
        pa_err = c.Pa_Initialize();
        if (pa_err != c.paNoError) {
            std.debug.print("PortAudio error: {s}\n", .{c.Pa_GetErrorText(pa_err)});
            return error.CantInitializePortAudio;
        }

        std.log.info("Opening Portaudio stream", .{});
        var stream: ?*c.PaStream = null;

        // pa_err = c.Pa_OpenDefaultStream(&stream, 0, channels, c.paUInt8, sample_rate, buffer_size, null, null);
        pa_err = c.Pa_OpenDefaultStream(&stream, 0, @intCast(channels), c.paFloat32, @floatFromInt(sample_rate), @intCast(buffer_size), null, null);
        if (pa_err != c.paNoError) {
            std.debug.print("PortAudio error: {s}\n", .{c.Pa_GetErrorText(pa_err)});
            return error.CantOpenDefaultStream;
        }

        // start stream
        std.log.info("Starting portaudio stream", .{});
        pa_err = c.Pa_StartStream(stream);
        if (pa_err != c.paNoError) {
            std.debug.print("PortAudio error: {s}\n", .{c.Pa_GetErrorText(pa_err)});
            return error.CantStartStream;
        }

        return .{
            .stream = stream,
            .pa_err = c.paNoError,
        };
    }

    pub fn write(self: *Audio, format: type, buffer: []format, frames: c_ulong) !void {
        self.pa_err = c.Pa_WriteStream(self.stream, @ptrCast(buffer), frames);
        if (self.pa_err != c.paNoError) {
            std.log.warn("PortAudio error: {s}\n", .{c.Pa_GetErrorText(self.pa_err)});
            return error.WriteError;
        }
    }

    pub fn deinit(self: *Audio) void {
        _ = c.Pa_CloseStream(self.stream);
        _ = c.Pa_Terminate();
    }
};
