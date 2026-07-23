# Changelog

All notable changes are documented here. This project follows
[Semantic Versioning](https://semver.org/).

## [0.1.0]

Initial release: a macOS menu bar widget for YouTube playback in Google Chrome.

### Added
- **YouTube playback timer.** When a video plays in Chrome, the menu bar shows `current / total` time (e.g. `12:34 / 1:02:45`), advancing smoothly via local interpolation between ~1s syncs. Paused videos show the same time dimmed with a `⏸` prefix; with nothing playing it rests on the red YouTube logo.
- **Preview image.** The dropdown shows a preview of the current video. A **Preview** setting chooses between the official **Thumbnail** and a **Mid-video frame** (~50% of the video, from YouTube's storyboard images, falling back to the thumbnail when unavailable).
- **Click to focus the tab.** Clicking the preview raises the Chrome window, selects the video's tab, and activates Chrome.
- **Detection via in-process AppleScript** (no `osascript` spawning): one batched Apple Event enumerates tabs, the YouTube tab handle is cached, and steady state is a single JS probe of the `<video>` element per cycle. No Apple Events fire while Chrome isn't running (driven by workspace launch/quit notifications); polling slows while paused. Handles multiple YouTube tabs (tracks the one playing) and surfaces guidance when Automation permission or Chrome's "Allow JavaScript from Apple Events" is missing.
- **Color** setting: Red (YouTube logo) or System (adaptive template).
