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

      // Gate verbose Console & Network DevTools IPC behind explicit activation so browsing stays 120Hz crisp
      window.__prismDevToolsEnabled = Boolean(window.__prismDevToolsEnabled);

      const mediaExtRegex = /\\.(mp4|m3u8|webm|mov|m4v|mp3|m4a)(\\?|#|$)/i;
      const reportedMedia = new Set();
      const reportMedia = (rawUrl) => {
        if (!rawUrl || typeof rawUrl !== 'string') return;
        if (!mediaExtRegex.test(rawUrl)) return;
        let abs = rawUrl;
        try { abs = new URL(rawUrl, location.href).href; } catch (e) {}
        if (!/^https?:/i.test(abs)) return;
        const m = abs.match(mediaExtRegex);
        if (!m || reportedMedia.has(abs)) return;
        reportedMedia.add(abs);
        post('media', { url: abs, ext: m[1].toLowerCase(), title: document.title || location.hostname });
      };

      // Console Capture -> Mobile DevTools (zero-overhead fast path when DevTools closed)
      ['log', 'warn', 'error', 'info'].forEach((lvl) => {
        const orig = console[lvl];
        console[lvl] = function(...args) {
          if (window.__prismDevToolsEnabled) {
            try {
              const msg = args.map((a) => {
                if (typeof a === 'string') return a;
                try { return JSON.stringify(a); } catch (e) { return String(a); }
              }).join(' ');
              post('console', { level: lvl, message: msg.slice(0, 600) });
            } catch (e) {}
          }
          return orig.apply(console, args);
        };
      });
      window.addEventListener('error', (e) => {
        if (window.__prismDevToolsEnabled) {
          post('console', { level: 'error', message: (e.message || 'Script error').slice(0, 600) });
        }
      });

      // Fetch / XHR Hook -> Media Sniffer (fast regex check) + Network DevTools on demand
      const origFetch = window.fetch;
      window.fetch = function(input, init) {
        const url = typeof input === 'string' ? input : (input && input.url ? input.url : '');
        reportMedia(url);
        if (!window.__prismDevToolsEnabled) {
          return origFetch.apply(this, arguments);
        }
        const start = performance.now();
        const method = (init && init.method) ? init.method.toUpperCase() : 'GET';
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
        this.__prismUrl = url || '';
        reportMedia(this.__prismUrl);
        if (window.__prismDevToolsEnabled) {
          this.__prismMethod = (method || 'GET').toUpperCase();
        }
        return origOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function() {
        if (window.__prismDevToolsEnabled) {
          const start = performance.now();
          this.addEventListener('loadend', () => {
            post('network', { method: this.__prismMethod || 'GET', url: this.__prismUrl || '', status: this.status || 0, durationMs: Math.round(performance.now() - start) });
          }, { once: true });
        }
        return origSend.apply(this, arguments);
      };

      // O(1) Live video tracking — only emit when video state changes or playing progress advances
      let lastVideoKey = '';
      let lastVideoTime = -1;
      const liveVideoCollection = document.getElementsByTagName('video');
      const scanVideos = (forceEmit) => {
        const len = liveVideoCollection.length;
        if (len === 0) {
          if (window === window.top && lastVideoKey !== 'none') {
            lastVideoKey = 'none';
            lastVideoTime = -1;
            post('videoState', { hasVideo: false, paused: true, currentTime: 0, duration: 0, rate: 1 });
          }
          return;
        }
        let target = liveVideoCollection[0];
        for (let i = 0; i < len; i += 1) {
          const el = liveVideoCollection[i];
          if (el.currentSrc) reportMedia(el.currentSrc);
          if (el.src) reportMedia(el.src);
          if (el.readyState > 0 || !el.paused) target = el;
        }
        const ct = Number.isFinite(target.currentTime) ? target.currentTime : 0;
        const dur = Number.isFinite(target.duration) ? target.duration : 0;
        const rate = target.playbackRate || 1;
        const stateKey = '1|' + (target.paused ? 'p' : 'r') + '|' + rate;
        if (forceEmit || stateKey !== lastVideoKey || (!target.paused && Math.abs(ct - lastVideoTime) >= 2.0)) {
          lastVideoKey = stateKey;
          lastVideoTime = ct;
          post('videoState', { hasVideo: true, paused: target.paused, currentTime: ct, duration: dur, rate });
        }
      };
      if (document.readyState !== 'loading') scanVideos(true);
      else document.addEventListener('DOMContentLoaded', () => scanVideos(true), { once: true });
      document.addEventListener('play', () => scanVideos(true), true);
      document.addEventListener('pause', () => scanVideos(true), true);
      document.addEventListener('playing', () => scanVideos(true), true);
      document.addEventListener('loadedmetadata', () => scanVideos(true), true);
      setInterval(() => {
        if (!document.hidden && (liveVideoCollection.length > 0 || lastVideoKey !== 'none')) {
          scanVideos(false);
        }
      }, 2000);

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

      // Bulletproof Password field focus, input tracking & capture (eye-toggle & multi-step friendly)
      const knownPwInputs = new WeakSet();
      let sawPasswordActivity = false;
      let liveCred = { origin: location.origin, username: '', password: '', updatedAt: 0 };

      const readSavedUser = () => {
        try {
          const raw = sessionStorage.getItem('__prism_last_user');
          if (!raw) return '';
          const parsed = JSON.parse(raw);
          if (parsed && parsed.u && Date.now() - parsed.t < 180000) return String(parsed.u);
        } catch (e) {}
        return '';
      };

      const saveTempUser = (u) => {
        if (!u) return;
        try { sessionStorage.setItem('__prism_last_user', JSON.stringify({ u, t: Date.now() })); } catch (e) {}
      };

      const findVisibleUserNear = (anchor) => {
        const root = (anchor && anchor.closest && anchor.closest('form')) || document.body || document;
        const inputs = Array.from(root.querySelectorAll('input'));
        for (const el of inputs) {
          if (el === anchor || el.type === 'password' || el.type === 'hidden' || knownPwInputs.has(el)) continue;
          const v = (el.value || '').trim();
          if (v && (el.type === 'email' || el.type === 'text' || el.type === 'tel' || /user|email|mail|login|name|account/i.test((el.name || '') + (el.id || '') + (el.autocomplete || '')))) {
            return v;
          }
        }
        return readSavedUser();
      };

      const flushCredential = (anchor) => {
        const root = (anchor && anchor.closest && anchor.closest('form')) || document.body || document;
        let pwEl = null;
        for (const el of root.querySelectorAll('input')) {
          if ((el.type === 'password' || knownPwInputs.has(el)) && el.value) {
            pwEl = el;
            break;
          }
        }
        const pwVal = pwEl ? pwEl.value : (Date.now() - liveCred.updatedAt < 15000 ? liveCred.password : '');
        if (!pwVal) return;
        const userVal = findVisibleUserNear(pwEl || anchor) || liveCred.username || '';
        post('passwordCapture', { origin: location.origin, username: userVal, password: pwVal });
        liveCred.password = '';
      };

      document.addEventListener('focusin', (e) => {
        const t = e.target;
        if (!t || t.tagName !== 'INPUT') return;
        if (t.type === 'password') {
          knownPwInputs.add(t);
          sawPasswordActivity = true;
        }
        if (t.type === 'password' || knownPwInputs.has(t) || /user|email|login/i.test((t.name || '') + (t.id || '') + (t.autocomplete || ''))) {
          post('passwordFocus', { origin: location.origin });
        }
      }, true);

      document.addEventListener('input', (e) => {
        const t = e.target;
        if (!t || t.tagName !== 'INPUT') return;
        if (t.type === 'password' || knownPwInputs.has(t)) {
          knownPwInputs.add(t);
          sawPasswordActivity = true;
          if (t.value) {
            liveCred = {
              origin: location.origin,
              username: findVisibleUserNear(t) || liveCred.username,
              password: t.value,
              updatedAt: Date.now()
            };
          }
        } else if (t.value && /email|user|login|tel|text/i.test((t.type || '') + (t.name || '') + (t.id || '') + (t.autocomplete || ''))) {
          saveTempUser(t.value.trim());
          liveCred.username = t.value.trim();
        }
      }, true);

      document.addEventListener('submit', (e) => {
        if (sawPasswordActivity || liveCred.password) flushCredential(e.target);
      }, true);
      document.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && e.target && e.target.tagName === 'INPUT' && (sawPasswordActivity || liveCred.password)) flushCredential(e.target);
      }, true);
      document.addEventListener('click', (e) => {
        if (!sawPasswordActivity && !liveCred.password) return;
        const btn = e.target && e.target.closest && e.target.closest('button, input[type="submit"], input[type="button"], [role="button"], a[href^="javascript"]');
        if (btn) flushCredential(btn);
      }, true);
      window.addEventListener('pagehide', () => {
        if (sawPasswordActivity || liveCred.password) flushCredential(null);
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

    static let extractReaderJS = """
    (() => {
      const pickRoot = () => {
        const selectors = ['article', 'main', '[role="main"]', '.post-content', '.article-content', '.entry-content', '#content', '#article'];
        let best = null;
        let bestLen = 0;
        for (const sel of selectors) {
          for (const el of document.querySelectorAll(sel)) {
            const txtLen = (el.innerText || '').trim().length;
            if (txtLen > bestLen) { bestLen = txtLen; best = el; }
          }
        }
        return best || document.body;
      };
      const root = pickRoot();
      if (!root) return null;
      const blocks = [];
      const seen = new Set();
      for (const el of root.querySelectorAll('h1, h2, h3, p, blockquote, li')) {
        if (el.closest('nav, header, footer, aside, [role="navigation"], [aria-hidden="true"]')) continue;
        const text = (el.innerText || '').replace(/\\s+/g, ' ').trim();
        if (text.length < 18 || seen.has(text)) continue;
        seen.add(text);
        blocks.push(text);
        if (blocks.length >= 160) break;
      }
      const title = (document.querySelector('h1')?.innerText || document.title || '').trim();
      const byline = (document.querySelector('meta[name="author"]')?.getAttribute('content') || '').trim();
      return {
        title: title || location.hostname,
        byline,
        siteHost: location.hostname || '',
        paragraphs: blocks
      };
    })()
    """
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
