# Troubleshooting

**The timer doesn't appear when a video is playing.** Two one-time grants are needed for Chrome to answer:

1. **Automation permission.** On first run macOS asks to let YTBar control Google Chrome — click **Allow**. If you missed it, the menu shows *Allow Automation for YTBar…* (which opens System Settings ▸ Privacy & Security ▸ Automation), or run `tccutil reset AppleEvents com.local.ytbar` and relaunch to get the prompt again.
2. **Chrome ▸ View ▸ Developer ▸ Allow JavaScript from Apple Events.** This must be enabled once so the widget can read the player state. The menu tells you when it's off.

**It's tracking the wrong tab.** When several YouTube tabs are open, YTBar follows the one actually *playing*. Pause the others and it locks onto the active one.

**Nothing happens when Chrome is closed.** That's by design — YTBar makes no Apple Events at all while Chrome isn't running, and resumes automatically when you relaunch Chrome.

**Preview shows the thumbnail even in "Mid-video frame" mode.** Some videos (very fresh uploads, or ones without storyboards) don't expose storyboard images; YTBar falls back to the thumbnail in that case.

**The menu bar icon is hidden.** If you use a menu bar manager (Ice, Bartender, Hidden Bar), YTBar's icon may be tucked behind the overflow. Reveal it there, or drag it out with ⌘-drag.

---
Back to the [README](README.md).
