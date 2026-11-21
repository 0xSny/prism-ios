import AVFoundation
import Foundation
import MediaPlayer
import Photos
import UIKit
import WebKit

enum MediaSnifferScripts {
    static let injectScriptSource = """
    (function() {
      if (window.__prismBridgeInstalled) return;
      window.__prismBridgeInstalled = true;

      const post = (type, payload) => {
        try {
          window.webkit.messageHandlers.prismBridge.postMessage({ type, payload });
        } catch (e) {}
      };

      const mediaExtRegex = /\\.(mp4|m3u8|webm|mov|m4v|mp3|m4a)(\\?|#|$)/i;
      const reportedMedia = new Set();
      const reportMedia = (rawUrl) => {
        if (!rawUrl || typeof rawUrl !== 'string') return;
        let abs = rawUrl;
        try { abs = new URL(rawUrl, location.href).href; } catch (e) {}
        if (!/^https?:/i.test(abs)) return;
        const m = abs.match(mediaExtRegex);
        if (!m || reportedMedia.has(abs)) return;
        reportedMedia.add(abs);
        post('media', { url: abs, ext: m[1].toLowerCase(), title: document.title || location.hostname });
      };

      // Console Capture -> Mobile DevTools
      ['log', 'warn', 'error', 'info'].forEach((lvl) => {
        const orig = console[lvl];
        console[lvl] = function(...args) {
          try {
            const msg = args.map((a) => {
              if (typeof a === 'string') return a;
              try { return JSON.stringify(a); } catch (e) { return String(a); }
            }).join(' ');
            post('console', { level: lvl, message: msg.slice(0, 600) });
          } catch (e) {}
          return orig.apply(console, args);
        };
      });
      window.addEventListener('error', (e) => {
        post('console', { level: 'error', message: (e.message || 'Script error').slice(0, 600) });
      });

      // Fetch / XHR Hook -> Network DevTools + Media Sniffer
      const origFetch = window.fetch;
      window.fetch = function(input, init) {
        const start = performance.now();
        const url = typeof input === 'string' ? input : (input && input.url ? input.url : '');
        const method = (init && init.method) ? init.method.toUpperCase() : 'GET';
        reportMedia(url);
        return origFetch.apply(this, arguments).then((res) => {
          post('network', { method, url, status: res.status || 200, durationMs: Math.round(performance.now() - start) });
          return res;
        }).catch((err) => {
          post('network', { method, url, status: 0, durationMs: Math.round(performance.now() - start) });
          throw err;
        });
      };

      const origOpen = XMLHttpRequest.prototype.open;
      const origSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(method, url) {
        this.__prismMethod = (method || 'GET').toUpperCase();
        this.__prismUrl = url || '';
        reportMedia(this.__prismUrl);
        return origOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function() {
        const start = performance.now();
        this.addEventListener('loadend', () => {
          post('network', { method: this.__prismMethod || 'GET', url: this.__prismUrl || '', status: this.status || 0, durationMs: Math.round(performance.now() - start) });
        });
        return origSend.apply(this, arguments);
      };

      // Video scanning & metadata
      const scanVideos = () => {
        document.querySelectorAll('video, source').forEach((el) => {
          if (el.currentSrc) reportMedia(el.currentSrc);
          if (el.src) reportMedia(el.src);
        });
        const v = document.querySelector('video');
        if (v) {
          post('videoState', {
            hasVideo: true,
            paused: v.paused,
            currentTime: Number.isFinite(v.currentTime) ? v.currentTime : 0,
            duration: Number.isFinite(v.duration) ? v.duration : 0,
            rate: v.playbackRate || 1
          });
        }
      };
      setInterval(scanVideos, 2000);

      // Video Controls API exposed to Swift
      window.__prismVideoControl = function(cmd, val) {
        const v = document.querySelector('video');
        if (!v) return false;
        if (cmd === 'rate') {
          v.playbackRate = Number(val) || 1.0;
          return true;
        }
        if (cmd === 'seekBy') {
          v.currentTime = Math.max(0, (v.currentTime || 0) + (Number(val) || 0));
          return true;
        }
        if (cmd === 'seekTo') {
          v.currentTime = Math.max(0, Number(val) || 0);
          return true;
        }
        if (cmd === 'togglePlay') {
          if (v.paused) v.play().catch(() => {}); else v.pause();
          return true;
        }
        if (cmd === 'pip') {
          if (typeof v.webkitSetPresentationMode === 'function') {
            v.webkitSetPresentationMode(v.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture');
            return true;
          }
          if (document.pictureInPictureElement) {
            document.exitPictureInPicture().catch(() => {});
          } else if (v.requestPictureInPicture) {
            v.requestPictureInPicture().catch(() => {});
          }
          return true;
        }
        return false;
      };

      // Password field focus & form submission detection
      document.addEventListener('focusin', (e) => {
        const t = e.target;
        if (t && t.tagName === 'INPUT' && (t.type === 'password' || /user|email|login/i.test(t.name + t.id + t.autocomplete))) {
          post('passwordFocus', { origin: location.origin });
        }
      }, true);

      document.addEventListener('submit', (e) => {
        const form = e.target;
        if (!form || !form.querySelector) return;
        const pw = form.querySelector('input[type="password"]');
        if (!pw || !pw.value) return;
        const userEl = form.querySelector('input[type="email"], input[type="text"], input[name*="user"], input[name*="email"]');
        post('passwordCapture', {
          origin: location.origin,
          username: userEl ? (userEl.value || '') : '',
          password: pw.value
        });
      }, true);
    })();
    """

    static func autofillJS(username: String, password: String) -> String {
        let uJson = (try? String(data: JSONEncoder().encode(username), encoding: .utf8)) ?? "\"\""
        let pJson = (try? String(data: JSONEncoder().encode(password), encoding: .utf8)) ?? "\"\""
        return """
        (function() {
          const uVal = \(uJson);
          const pVal = \(pJson);
          const setNative = (el, val) => {
            if (!el) return;
            const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
            if (setter) setter.call(el, val); else el.value = val;
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          };
          const pw = document.querySelector('input[type="password"]');
          if (pw) setNative(pw, pVal);
          const user = document.querySelector('input[type="email"], input[autocomplete="username"], input[name*="user"], input[name*="email"], input[type="text"]');
          if (user && uVal) setNative(user, uVal);
        })();
        """
    }
}

@MainActor
final class BackgroundMediaController {
    static let shared = BackgroundMediaController()

    func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Audio session failure is non-fatal
        }
    }

    func updateNowPlaying(title: String, host: String, duration: Double, elapsed: Double, playing: Bool) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title.isEmpty ? "Prism Video" : title,
            MPMediaItemPropertyArtist: host,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    static func downloadAndSaveMedia(urlString: String) async -> (Bool, String) {
        guard let url = URL(string: urlString) else {
            return (false, L10n.t("无效媒体链接", "Invalid media URL"))
        }
        if url.pathExtension.lowercased() == "m3u8" {
            // Export playlist URL / share sheet to Files
            await MainActor.run {
                let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let root = scene.windows.first?.rootViewController {
                    root.present(vc, animated: true)
                }
            }
            return (true, L10n.t("已调起系统分享导出 HLS 流", "Opened Share Sheet for HLS stream"))
        }

        do {
            let (tempUrl, _) = try await URLSession.shared.download(from: url)
            let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
            let destUrl = FileManager.default.temporaryDirectory.appendingPathComponent("prism-media-\(Int(Date().timeIntervalSince1970)).\(ext)")
            try? FileManager.default.removeItem(at: destUrl)
            try FileManager.default.moveItem(at: tempUrl, to: destUrl)

            let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            if auth == .authorized || auth == .limited {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: destUrl)
                }
                return (true, L10n.t("视频已保存到系统相册", "Saved video to Photos"))
            } else {
                await MainActor.run {
                    let vc = UIActivityViewController(activityItems: [destUrl], applicationActivities: nil)
                    if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let root = scene.windows.first?.rootViewController {
                        root.present(vc, animated: true)
                    }
                }
                return (true, L10n.t("已导出至「文件」共享面板", "Opened Files Share Sheet"))
            }
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
