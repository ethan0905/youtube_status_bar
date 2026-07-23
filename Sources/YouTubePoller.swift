import Cocoa

enum PlayerState { case noChrome, noVideo, playing, paused, permissionDenied, jsDisabled }

struct PlaybackInfo {
    var videoId: String
    var title: String
    var currentTime: Double
    var duration: Double
    var rate: Double
    var paused: Bool
    var windowId: Int
    var tabId: Int
    var syncedAt: Date

    // Elapsed position with local interpolation between real syncs, so the displayed clock
    // advances smoothly (and at playback rate) without polling Chrome every frame.
    func interpolated(now: Date) -> Double {
        guard !paused else { return min(currentTime, duration) }
        return min(duration, currentTime + rate * now.timeIntervalSince(syncedAt))
    }
}

// Watches Google Chrome for a playing YouTube tab via in-process Apple Events (NSAppleScript,
// no osascript spawn). One batched event enumerates tabs; once a video tab is found its window+tab
// ids are cached and steady state is a single JS probe per cycle. Cadence adapts to the state, and
// no Apple Events fire at all while Chrome isn't running.
final class ChromeYouTubePoller {
    static let chromeBundleId = "com.google.Chrome"

    var onUpdate: ((PlayerState, PlaybackInfo?) -> Void)?

    private let queue = DispatchQueue(label: "com.local.ytbar.applescript")
    private var timer: Timer?
    private var inFlight = false
    private var chromeRunning = false

    private(set) var state: PlayerState = .noChrome
    private(set) var info: PlaybackInfo?

    // Cached tab handle; nil forces a full tab scan on the next cycle.
    private var cachedWindowId: Int?
    private var cachedTabId: Int?

    // Poll intervals (seconds), overridable via uiconfig.
    private var pollPlaying = 1.5
    private var pollPaused = 5.0
    private var pollIdle = 3.0
    private var pollRetry = 10.0

    private var lastFired = Date.distantPast
    private var currentInterval = 3.0

    init() {
        chromeRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.chromeBundleId }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    func applyConfig(_ cfg: [String: Double]) {
        if let v = cfg["pollPlaying"] { pollPlaying = v }
        if let v = cfg["pollPaused"] { pollPaused = v }
        if let v = cfg["pollIdle"] { pollIdle = v }
    }

    func start() {
        // A short master tick decides, each fire, whether enough time has elapsed for the current
        // state's interval — lets the cadence change without tearing down the timer.
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.maybePoll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        maybePoll()
    }

    @objc private func appLaunched(_ note: Notification) {
        guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Self.chromeBundleId else { return }
        chromeRunning = true
        lastFired = .distantPast   // poll promptly now that Chrome is up
    }

    @objc private func appTerminated(_ note: Notification) {
        guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Self.chromeBundleId else { return }
        chromeRunning = false
        cachedWindowId = nil; cachedTabId = nil
        publish(.noChrome, nil)
    }

    private func intervalFor(_ s: PlayerState) -> Double {
        switch s {
        case .playing:                       return pollPlaying
        case .paused:                        return pollPaused
        case .noVideo:                       return pollIdle
        case .permissionDenied, .jsDisabled: return pollRetry
        case .noChrome:                      return 3.0
        }
    }

    private func maybePoll() {
        guard chromeRunning else {
            if state != .noChrome { publish(.noChrome, nil) }
            return
        }
        guard !inFlight else { return }
        guard Date().timeIntervalSince(lastFired) >= currentInterval else { return }
        lastFired = Date()
        inFlight = true
        queue.async { [weak self] in self?.poll() }
    }

    // Runs on the AppleScript queue.
    private func poll() {
        // If we have a cached tab, probe it directly; on any miss, fall through to a rescan.
        if let wid = cachedWindowId, let tid = cachedTabId {
            switch probe(windowId: wid, tabId: tid) {
            case .success(let info):
                finish(info.paused ? .paused : .playing, info)
                return
            case .permissionDenied:
                finish(.permissionDenied, nil); return
            case .jsDisabled:
                finish(.jsDisabled, nil); return
            case .noChrome:
                finish(.noChrome, nil); return
            case .miss:
                cachedWindowId = nil; cachedTabId = nil   // tab gone / navigated away → rescan
            }
        }

        switch scanForCandidates() {
        case .failure(let s):
            finish(s, nil)
        case .success(let candidates):
            // Probe each candidate; prefer a playing tab, else a paused one.
            var firstPaused: PlaybackInfo?
            for c in candidates {
                switch probe(windowId: c.windowId, tabId: c.tabId) {
                case .success(let info):
                    if !info.paused {
                        cachedWindowId = c.windowId; cachedTabId = c.tabId
                        finish(.playing, info); return
                    }
                    if firstPaused == nil { firstPaused = info }
                case .permissionDenied: finish(.permissionDenied, nil); return
                case .jsDisabled:       finish(.jsDisabled, nil); return
                case .noChrome:         finish(.noChrome, nil); return
                case .miss:             continue
                }
            }
            if let p = firstPaused {
                cachedWindowId = p.windowId; cachedTabId = p.tabId
                finish(.paused, p); return
            }
            finish(.noVideo, nil)
        }
    }

    private func finish(_ s: PlayerState, _ info: PlaybackInfo?) {
        DispatchQueue.main.async { [weak self] in
            self?.inFlight = false
            self?.publish(s, info)
        }
    }

    private func publish(_ s: PlayerState, _ info: PlaybackInfo?) {
        state = s
        self.info = info
        currentInterval = intervalFor(s)
        onUpdate?(s, info)
    }

    // MARK: - Apple Events

    private struct Candidate { let windowId: Int; let tabId: Int }

    private enum ProbeResult { case success(PlaybackInfo); case miss; case permissionDenied; case jsDisabled; case noChrome }
    private enum ScanResult { case success([Candidate]); case failure(PlayerState) }

    // One batched event: parallel lists of window ids, per-window tab ids, per-window tab URLs.
    private func scanForCandidates() -> ScanResult {
        let src = """
        tell application "Google Chrome"
          return {id of every window, id of tabs of every window, URL of tabs of every window}
        end tell
        """
        var errNum = 0
        guard let desc = run(src, error: &errNum) else {
            return .failure(classify(errNum))
        }
        // desc: list of 3 items. item1 = list of window ids; item2 = list of (list of tab ids);
        // item3 = list of (list of urls). AppleScript descriptor lists are 1-indexed.
        guard desc.numberOfItems == 3,
              let winIds = desc.atIndex(1), let tabIdLists = desc.atIndex(2), let urlLists = desc.atIndex(3) else {
            return .success([])
        }
        var candidates: [Candidate] = []
        for w in 1...max(1, winIds.numberOfItems) where winIds.numberOfItems > 0 {
            guard let wid = winIds.atIndex(w)?.int32Value,
                  let tabIds = tabIdLists.atIndex(w), let urls = urlLists.atIndex(w) else { continue }
            for t in 1...max(1, tabIds.numberOfItems) where tabIds.numberOfItems > 0 {
                guard let url = urls.atIndex(t)?.stringValue, isYouTubeWatch(url),
                      let tid = tabIds.atIndex(t)?.int32Value else { continue }
                candidates.append(Candidate(windowId: Int(wid), tabId: Int(tid)))
            }
        }
        return .success(candidates)
    }

    private func isYouTubeWatch(_ url: String) -> Bool {
        guard url.contains("youtube.com") else { return false }
        return url.contains("/watch") || url.contains("/shorts/")
    }

    private static let probeJS = """
    (function(){
      var v=document.querySelector('video.html5-main-video')||document.querySelector('video');
      if(!v||!isFinite(v.duration)||v.duration<=0) return JSON.stringify({ok:false});
      var m=location.href.match(/[?&]v=([A-Za-z0-9_-]{11})/);
      var id=m?m[1]:(location.pathname.indexOf('/shorts/')===0?location.pathname.split('/')[2]:'');
      return JSON.stringify({ok:true,t:v.currentTime,d:v.duration,paused:v.paused,rate:v.playbackRate,id:id,title:document.title});
    })()
    """

    private func probe(windowId: Int, tabId: Int) -> ProbeResult {
        let src = """
        tell application "Google Chrome"
          execute (first tab of window id \(windowId) whose id is \(tabId)) javascript "\(escapeForAppleScript(Self.probeJS))"
        end tell
        """
        var errNum = 0
        guard let desc = run(src, error: &errNum) else {
            let s = classify(errNum)
            switch s {
            case .permissionDenied: return .permissionDenied
            case .jsDisabled:       return .jsDisabled
            case .noChrome:         return .noChrome
            default:                return .miss   // window/tab not found → rescan
            }
        }
        guard let json = desc.stringValue,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["ok"] as? Bool == true else { return .miss }
        return .success(PlaybackInfo(
            videoId: obj["id"] as? String ?? "",
            title: (obj["title"] as? String ?? "").replacingOccurrences(of: " - YouTube", with: ""),
            currentTime: (obj["t"] as? NSNumber)?.doubleValue ?? 0,
            duration: (obj["d"] as? NSNumber)?.doubleValue ?? 0,
            rate: (obj["rate"] as? NSNumber)?.doubleValue ?? 1,
            paused: obj["paused"] as? Bool ?? false,
            windowId: windowId, tabId: tabId, syncedAt: Date()))
    }

    // Run arbitrary JS in the current video tab (used by the storyboard fetch). Returns the raw
    // string result, or nil on any error. Safe to call from any thread.
    func runJavaScriptInCurrentTab(_ js: String, completion: @escaping (String?) -> Void) {
        guard let wid = cachedWindowId, let tid = cachedTabId else { completion(nil); return }
        queue.async { [weak self] in
            guard let self = self else { completion(nil); return }
            let src = """
            tell application "Google Chrome"
              execute (first tab of window id \(wid) whose id is \(tid)) javascript "\(self.escapeForAppleScript(js))"
            end tell
            """
            var e = 0
            let result = self.run(src, error: &e)?.stringValue
            DispatchQueue.main.async { completion(result) }
        }
    }

    // Raise the video's window, select its tab, and bring Chrome to the front.
    func focusCurrentTab() {
        guard let wid = cachedWindowId, let tid = cachedTabId else { return }
        queue.async { [weak self] in
            let src = """
            tell application "Google Chrome"
              set w to window id \(wid)
              set n to count of tabs of w
              repeat with i from 1 to n
                if id of tab i of w is \(tid) then
                  set active tab index of w to i
                  exit repeat
                end if
              end repeat
              set index of w to 1
              activate
            end tell
            """
            var e = 0
            _ = self?.run(src, error: &e)
        }
    }

    // Compile-and-run on the AppleScript queue. Returns nil on error, writing the OSA error number.
    private func run(_ source: String, error errNum: inout Int) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { errNum = -1; return nil }
        var errInfo: NSDictionary?
        let result = script.executeAndReturnError(&errInfo)
        if let err = errInfo {
            errNum = (err[NSAppleScript.errorNumber] as? Int) ?? 0
            lastErrorMessage = (err[NSAppleScript.errorMessage] as? String) ?? ""
            return nil
        }
        return result
    }

    private var lastErrorMessage = ""

    private func classify(_ errNum: Int) -> PlayerState {
        if errNum == -1743 { return .permissionDenied }
        if errNum == -600 || lastErrorMessage.contains("isn't running") { return .noChrome }
        if lastErrorMessage.contains("JavaScript through AppleScript") { return .jsDisabled }
        return .noVideo
    }

    // AppleScript string literals: escape backslashes, quotes, and newlines.
    private func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: " ")
    }
}
