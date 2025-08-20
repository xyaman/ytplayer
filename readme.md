# ytplayer

Youtube audio player TUI.

## Features
- Search
- Play/Pause

## Usage/Build

```bash
# build
zig build --release=safe

# run
zig-out/bin/ytplayer
```

## Dependencies

- [yt-dlp](https://github.com/yt-dlp/yt-dlp) (runtime)
- [ffmpeg](https://ffmpeg.org/) (runtime)
- [portaudio](https://github.com/PortAudio/portaudio)(build, handled by zig)
- audio backend dev libraries: alsa, pulseaudio

## TODO:

- [ ] cursor movement with wide chars
