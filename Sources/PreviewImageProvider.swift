import Cocoa

enum PreviewMode: String { case thumbnail, midVideo }

// Fetches and caches the preview image for a video. Thumbnail mode is a plain HTTP fetch of
// YouTube's mqdefault.jpg. Mid-video mode reads the storyboard spec from the page (via the poller's
// JS channel), computes the tile at ~50% duration, fetches the storyboard sheet, and crops that
// tile — falling back to the thumbnail whenever any step fails.
final class PreviewImageProvider {
    private let cache = NSCache<NSString, NSImage>()
    private weak var poller: ChromeYouTubePoller?

    init(poller: ChromeYouTubePoller) { self.poller = poller }

    // Delivers on the main thread. Fires the completion at most once per call.
    func image(videoId: String, mode: PreviewMode, completion: @escaping (NSImage?) -> Void) {
        guard !videoId.isEmpty else { completion(nil); return }
        let key = "\(videoId)|\(mode.rawValue)" as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached); return
        }
        switch mode {
        case .thumbnail:
            fetchThumbnail(videoId: videoId) { [weak self] img in
                if let img = img { self?.cache.setObject(img, forKey: key) }
                completion(img)
            }
        case .midVideo:
            fetchMidVideo(videoId: videoId) { [weak self] img in
                if let img = img {
                    self?.cache.setObject(img, forKey: key)
                    completion(img)
                } else {
                    // Fall back to the thumbnail (cached under the thumbnail key, not this one).
                    self?.image(videoId: videoId, mode: .thumbnail, completion: completion)
                }
            }
        }
    }

    private func fetchThumbnail(videoId: String, completion: @escaping (NSImage?) -> Void) {
        guard let url = URL(string: "https://img.youtube.com/vi/\(videoId)/mqdefault.jpg") else {
            completion(nil); return
        }
        fetchImage(url) { completion($0) }
    }

    private func fetchMidVideo(videoId: String, completion: @escaping (NSImage?) -> Void) {
        let js = """
        (function(){try{
          var p=document.getElementById('movie_player');
          var r=(p&&p.getPlayerResponse&&p.getPlayerResponse())||window.ytInitialPlayerResponse;
          if(!r||!r.videoDetails||r.videoDetails.videoId!=='\(videoId)') return '';
          var s=r.storyboards;
          return (s&&s.playerStoryboardSpecRenderer&&s.playerStoryboardSpecRenderer.spec)||'';
        }catch(e){return ''}})()
        """
        poller?.runJavaScriptInCurrentTab(js) { [weak self] spec in
            guard let self = self, let spec = spec, !spec.isEmpty,
                  let tileURL = self.midTileURL(spec: spec) else {
                completion(nil); return
            }
            self.fetchImage(tileURL.url) { image in
                guard let image = image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let cropped = cg.cropping(to: tileURL.crop) else {
                    completion(nil); return
                }
                completion(NSImage(cgImage: cropped, size: NSSize(width: tileURL.crop.width, height: tileURL.crop.height)))
            }
        }
    }

    // Parse a storyboard spec into the URL of the sheet holding the mid-video tile + the crop rect.
    // spec = "<baseURL with $L and $N>|<level0>|<level1>|..." where each level is
    // "W#H#count#rows#cols#interval#name#sigh".
    private func midTileURL(spec: String) -> (url: URL, crop: CGRect)? {
        let parts = spec.components(separatedBy: "|")
        guard parts.count >= 2 else { return nil }
        let base = parts[0]
        // Highest-resolution level = last one.
        let levelIdx = parts.count - 2                 // 0-based index among levels
        let fields = parts[parts.count - 1].components(separatedBy: "#")
        guard fields.count >= 8,
              let w = Int(fields[0]), let h = Int(fields[1]), let count = Int(fields[2]),
              let rows = Int(fields[3]), let cols = Int(fields[4]) else { return nil }
        let sigh = fields[7]
        guard w > 0, h > 0, count > 0, rows > 0, cols > 0 else { return nil }

        let frameIdx = Int(Double(count - 1) * 0.5)
        let perSheet = rows * cols
        let sheet = frameIdx / perSheet
        let inSheet = frameIdx % perSheet
        let row = inSheet / cols
        let col = inSheet % cols

        // Base uses $L for the level; the sheet placeholder is $N in older specs and $M in newer
        // storyboard3 specs — replace whichever is present.
        var urlStr = base
            .replacingOccurrences(of: "$L", with: String(levelIdx))
            .replacingOccurrences(of: "$N", with: "M\(sheet)")
            .replacingOccurrences(of: "$M", with: String(sheet))
        let sep = urlStr.contains("?") ? "&" : "?"
        urlStr += "\(sep)sigh=\(sigh)"
        guard let url = URL(string: urlStr) else { return nil }

        // JPEG and CGImage both use a top-left origin, so no vertical flip is needed.
        let crop = CGRect(x: col * w, y: row * h, width: w, height: h)
        return (url, crop)
    }

    private func fetchImage(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let img = data.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async { completion(img) }
        }.resume()
    }
}
