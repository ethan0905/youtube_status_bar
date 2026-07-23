# Contributing

Thanks for your interest. This is a tiny menu bar app and I'd like to keep it that way.

It does one thing: show the playback position of the YouTube video playing in Google Chrome. It stays local (the only network calls fetch preview images from YouTube), free (no API key, no spend), and small (a status bar, not a dashboard).

## What's welcome

Bug fixes, performance wins, visual polish, more reliable Chrome/YouTube detection, and compatibility fixes (macOS versions, CPU architectures).

See the [issues](https://github.com/ethan0905/youtube_status_bar/issues) for proposed enhancements; anything marked in scope there is open to pick up.

## Won't be merged

- Sending your browsing, tabs, or watch history to any API or relay.
- Anything that costs money or needs an API key.
- Usage meters, analytics, or telemetry.
- Hardcoding for one locale or setup.
- New settings stores or dependencies for a minor feature when what's already there works.
- Changing how your machine behaves beyond showing status (preventing sleep, privileged helpers, background actions). The app displays state, it doesn't act on your system.
- Support for browsers other than Chrome, or ports to other platforms. Great projects, but as your own fork.

## Building

You'll need macOS 12+ and the Swift toolchain (Xcode Command Line Tools).

```bash
./build.sh          # -> build/YTBar.app
./build.sh --dmg    # also builds a .dmg
```

Without a Developer ID cert you get an ad-hoc build, which is fine for testing. Launch it, play a YouTube video in Chrome, and the timer appears.

Build off the latest `main` so you're not fixing something that already changed.

## Testing

Before you open a PR, actually run it. "Builds clean" is not testing.

Try it end to end: a video playing, paused, closed, and with Chrome quit entirely; multiple YouTube tabs open at once; and clicking the preview to focus the tab. For any visual or timing change, attach a screenshot or a short screen recording.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/): `feat`, `fix`, `chore`, `refactor`, `style`, `docs`, `perf`. Branches: `type/kebab-case-description`.

## License

MIT. By contributing, you agree your contributions are licensed under it.
