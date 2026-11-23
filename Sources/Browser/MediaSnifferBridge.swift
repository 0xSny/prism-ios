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
        const vids = document.getElementsByTagName('video');
        let v = vids[0];
        for (let i = 0; i < vids.length; i += 1) {
          if (vids[i].readyState > 0 || !vids[i].paused) { v = vids[i]; break; }
        }
        if (!v) return false;
        if (cmd === 'play') {
          v.play().catch(() => {});
          return true;
        }
        if (cmd === 'pause') {
          v.pause();
          return true;
        }
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

      window.__prismScheduleSeek = function(targetSeconds) {
        const sec = Math.max(0, Number(targetSeconds) || 0);
        if (sec <= 0) return;
        let done = false;
        const deadline = Date.now() + 8000;
        const attempt = () => {
          if (done || Date.now() > deadline) return;
          const vids = document.getElementsByTagName('video');
          let v = vids[0];
          for (let i = 0; i < vids.length; i += 1) {
            if (vids[i].readyState >= 1 || vids[i].duration > 0) { v = vids[i]; break; }
          }
          if (!v) {
            setTimeout(attempt, 250);
            return;
          }
          if (v.readyState >= 1) {
            done = true;
            try { v.currentTime = sec; } catch (e) {}
            return;
          }
          v.addEventListener('loadedmetadata', attempt, { once: true });
          v.addEventListener('canplay', attempt, { once: true });
          setTimeout(attempt, 350);
        };
        attempt();
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

    static let imeCodeMirrorHealerSource = """
    (() => {
      if (window.__prismImeHealerInstalled) return;
      window.__prismImeHealerInstalled = true;

      const composingTargets = new WeakSet();
      const recentComposedTargets = new WeakSet();
      const quietSyncTimers = new WeakMap();
      const ZWS_RE = /[\\u200B\\uFEFF]/g;

      function stripZws(str) {
        return (str || '').replace(ZWS_RE, '');
      }

      function markRecentComposed(el) {
        if (!el) return;
        recentComposedTargets.add(el);
        const cm5 = el.closest ? el.closest('.CodeMirror') : null;
        if (cm5) recentComposedTargets.add(cm5);
        const cm6 = el.closest ? el.closest('.cm-editor') : null;
        if (cm6) recentComposedTargets.add(cm6);
      }

      function isEditableElement(el) {
        if (!el || el.nodeType !== 1) return false;
        const tag = el.tagName;
        if (tag === 'TEXTAREA') return !el.readOnly && !el.disabled;
        if (tag === 'INPUT') {
          const t = (el.type || 'text').toLowerCase();
          if (['button', 'submit', 'reset', 'checkbox', 'radio', 'file', 'image', 'range', 'color', 'hidden'].includes(t)) {
            return false;
          }
          return !el.readOnly && !el.disabled;
        }
        return !!el.isContentEditable;
      }

      function getEditorScope(el) {
        if (!el || !el.closest) return el;
        return el.closest('.CodeMirror, .cm-editor') || el;
      }

      function extractCodeMirror5DomText(wrapper) {
        const codeEl = wrapper && wrapper.querySelector('.CodeMirror-code');
        if (!codeEl) return '';
        const clone = codeEl.cloneNode(true);
        const noise = clone.querySelectorAll(
          '.CodeMirror-placeholder, .CodeMirror-linenumber, .CodeMirror-gutter-elt, .CodeMirror-cursors, .CodeMirror-selected, .CodeMirror-gutter-wrapper'
        );
        for (let i = 0; i < noise.length; i++) {
          noise[i].remove();
        }
        const lineNodes = clone.querySelectorAll('.CodeMirror-line');
        if (lineNodes.length > 0) {
          const lines = [];
          for (let i = 0; i < lineNodes.length; i++) {
            lines.push(stripZws(lineNodes[i].textContent || '').replace(/[\\r\\n]+$/, ''));
          }
          let extraOrphan = '';
          for (let i = 0; i < clone.childNodes.length; i++) {
            const c = clone.childNodes[i];
            if (c.nodeType === 3) {
              extraOrphan += stripZws(c.nodeValue || '');
            }
          }
          let joined = lines.join('\\n');
          if (extraOrphan.trim()) {
            joined = joined ? (joined + extraOrphan) : extraOrphan;
          }
          return joined;
        }
        return stripZws(clone.textContent || '');
      }

      function extractCodeMirror6DomText(editor) {
        const content = editor && editor.querySelector('.cm-content');
        if (!content) return '';
        const clone = content.cloneNode(true);
        const phs = clone.querySelectorAll('.cm-placeholder');
        for (let i = 0; i < phs.length; i++) {
          phs[i].remove();
        }
        const lineNodes = clone.querySelectorAll('.cm-line');
        if (lineNodes.length > 0) {
          const lines = [];
          for (let i = 0; i < lineNodes.length; i++) {
            lines.push(stripZws(lineNodes[i].textContent || '').replace(/[\\r\\n]+$/, ''));
          }
          return lines.join('\\n');
        }
        return stripZws(clone.textContent || '');
      }

      function updatePlaceholderVisibility(target) {
        try {
          const el = target && target.nodeType === 1 ? target : (target && target.parentElement);
          if (!el || !el.closest) return;

          const cm5 = el.closest('.CodeMirror');
          if (cm5) {
            const ph = cm5.querySelector('.CodeMirror-placeholder');
            if (ph) {
              const cmVal = cm5.CodeMirror && typeof cm5.CodeMirror.getValue === 'function' ? cm5.CodeMirror.getValue() : '';
              const domText = extractCodeMirror5DomText(cm5);
              const hasText = stripZws(cmVal).length > 0 || stripZws(domText).length > 0;
              ph.style.opacity = hasText ? '0' : '';
            }
          }

          const cm6 = el.closest('.cm-editor');
          if (cm6) {
            const ph = cm6.querySelector('.cm-placeholder');
            if (ph) {
              const domText = extractCodeMirror6DomText(cm6);
              ph.style.opacity = stripZws(domText).length > 0 ? '0' : '';
            }
          }
        } catch (_) {}
      }

      function removeDirectOrphanTextNodes(el) {
        if (!el || !el.childNodes) return;
        for (let i = el.childNodes.length - 1; i >= 0; i--) {
          if (el.childNodes[i].nodeType === 3) {
            el.removeChild(el.childNodes[i]);
          }
        }
      }

      function anchorSelectionInsideLine(lineEl) {
        if (!lineEl) return;
        try {
          const sel = window.getSelection();
          if (!sel) return;
          const range = document.createRange();
          if (lineEl.firstChild && lineEl.firstChild.nodeType === 3) {
            range.setStart(lineEl.firstChild, lineEl.firstChild.nodeValue.length);
          } else {
            range.selectNodeContents(lineEl);
          }
          range.collapse(false);
          sel.removeAllRanges();
          sel.addRange(range);
        } catch (_) {}
      }

      function dispatchEndAndSyncEvents(el, textVal) {
        try {
          el.composing = false;
        } catch (_) {}
        try {
          el.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: textVal || '' }));
        } catch (_) {}
        try {
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        } catch (_) {}
      }

      function flushCodeMirror5(wrap, preserveFocus) {
        try {
          const cm = wrap && wrap.CodeMirror;
          if (!cm) return;

          const codeEl = wrap.querySelector('.CodeMirror-code');
          if (cm.display && cm.display.input) {
            const inp = cm.display.input;
            if (inp.composing && typeof inp.composing === 'object') {
              inp.composing.done = true;
            }
            if (typeof cm.operation === 'function') {
              cm.operation(() => {
                if (typeof inp.pollContent === 'function') {
                  inp.pollContent();
                }
              });
            }
            inp.composing = null;
            if (inp.textarea) {
              try { inp.textarea.composing = false; } catch (_) {}
            }
          }

          removeDirectOrphanTextNodes(codeEl);
          removeDirectOrphanTextNodes(wrap.querySelector('.CodeMirror-sizer'));
          removeDirectOrphanTextNodes(wrap.querySelector('.CodeMirror-lines'));

          const domText = extractCodeMirror5DomText(wrap);
          if (domText.length > 0 && typeof cm.getValue === 'function' && domText !== cm.getValue() && typeof cm.setValue === 'function') {
            cm.setValue(domText);
            const lastLine = Math.max(0, (typeof cm.lineCount === 'function' ? cm.lineCount() : 1) - 1);
            const lastText = typeof cm.getLine === 'function' ? (cm.getLine(lastLine) || '') : domText;
            if (typeof cm.setCursor === 'function') {
              cm.setCursor({ line: lastLine, ch: lastText.length });
            }
            if (typeof cm.refresh === 'function') {
              cm.refresh();
            }
            if (preserveFocus && typeof cm.focus === 'function') {
              cm.focus();
            }
          }
          updatePlaceholderVisibility(wrap);
        } catch (_) {}
      }

      function flushCodeMirror6(editor, preserveFocus) {
        try {
          const content = editor && editor.querySelector('.cm-content');
          if (!content) return;

          try {
            content.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: content.textContent || '' }));
          } catch (_) {}

          const viewObs = (content.cmView && content.cmView.view && content.cmView.view.observer)
            || (editor.cmView && editor.cmView.view && editor.cmView.view.observer);
          if (viewObs && typeof viewObs.flush === 'function') {
            viewObs.flush();
          }

          let orphanParts = [];
          for (let i = content.childNodes.length - 1; i >= 0; i--) {
            const child = content.childNodes[i];
            if (child.nodeType === 3) {
              const txt = stripZws(child.nodeValue);
              if (txt) orphanParts.unshift(txt);
              content.removeChild(child);
            }
          }
          const rescued = orphanParts.join('');
          if (rescued) {
            const prevFocus = document.activeElement;
            content.focus({ preventScroll: true });
            const line = content.querySelector('.cm-line') || content;
            anchorSelectionInsideLine(line);
            let inserted = false;
            try {
              inserted = document.execCommand('insertText', false, rescued);
            } catch (_) {
              inserted = false;
            }
            if (!inserted) {
              try {
                content.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: rescued }));
              } catch (_) {
                content.dispatchEvent(new Event('input', { bubbles: true }));
              }
            }
            if (!preserveFocus && prevFocus !== content && document.activeElement === content) {
              content.blur();
            }
          }
          updatePlaceholderVisibility(editor);
        } catch (_) {}
      }

      function flushEditableState(el, preserveFocus) {
        try {
          if (!el) return;
          const node = el.nodeType === 1 ? el : el.parentElement;
          if (!node) return;
          composingTargets.delete(node);

          const cm5 = node.closest ? node.closest('.CodeMirror') : null;
          if (cm5) {
            composingTargets.delete(cm5);
            flushCodeMirror5(cm5, preserveFocus);
            return;
          }

          const cm6 = node.closest ? node.closest('.cm-editor') : null;
          if (cm6) {
            composingTargets.delete(cm6);
            flushCodeMirror6(cm6, preserveFocus);
            return;
          }

          const field = (node.matches && node.matches('textarea, input'))
            ? node
            : (node.closest ? node.closest('textarea, input') : null);
          if (field) {
            composingTargets.delete(field);
            dispatchEndAndSyncEvents(field, field.value || '');
            return;
          }

          if (node.isContentEditable) {
            dispatchEndAndSyncEvents(node, node.textContent || '');
          }
        } catch (_) {}
      }

      function silentWindowSync(target) {
        try {
          if (!target) return;
          const node = target.nodeType === 1 ? target : target.parentElement;
          if (!node) return;
          updatePlaceholderVisibility(node);

          const cm5 = node.closest ? node.closest('.CodeMirror') : null;
          if (cm5 && cm5.CodeMirror) {
            const cm = cm5.CodeMirror;
            const inp = cm.display && cm.display.input;
            if (inp && inp.composing) {
              inp.composing.done = true;
              if (typeof cm.operation === 'function') {
                cm.operation(() => { if (typeof inp.pollContent === 'function') inp.pollContent(); });
              }
              inp.composing = null;
            }
            const domText = extractCodeMirror5DomText(cm5);
            if (domText.length > 0 && typeof cm.getValue === 'function' && domText !== cm.getValue()) {
              cm.setValue(domText);
              const lastLine = Math.max(0, (typeof cm.lineCount === 'function' ? cm.lineCount() : 1) - 1);
              const lastText = typeof cm.getLine === 'function' ? (cm.getLine(lastLine) || '') : domText;
              if (typeof cm.setCursor === 'function') {
                cm.setCursor({ line: lastLine, ch: lastText.length });
              }
              cm.refresh && cm.refresh();
              cm.focus && cm.focus();
            }
            return;
          }

          const cm6 = node.closest ? node.closest('.cm-editor') : null;
          if (cm6) {
            flushCodeMirror6(cm6, true);
            return;
          }

          const field = (node.matches && node.matches('textarea, input'))
            ? node
            : (node.closest ? node.closest('textarea, input') : null);
          if (field && field.composing === true) {
            field.composing = false;
            field.dispatchEvent(new Event('input', { bubbles: true }));
          }
        } catch (_) {}
      }

      function handleTouchOrClickFocus(e) {
        try {
          if (e.type === 'touchend' && lastTouchMoved) return;
          const target = e.target;
          if (!target || !target.closest) return;

          const cm5 = target.closest('.CodeMirror');
          if (cm5 && cm5.CodeMirror && !cm5.classList.contains('CodeMirror-focused')) {
            const cm = cm5.CodeMirror;
            if (typeof cm.focus === 'function') cm.focus();
            if (typeof cm.getValue === 'function' && !cm.getValue() && typeof cm.setCursor === 'function') {
              cm.setCursor(0, 0);
            }
            return;
          }

          const cm6 = target.closest('.cm-editor');
          if (cm6) {
            const content = cm6.querySelector('.cm-content');
            if (content && document.activeElement !== content && !content.contains(document.activeElement)) {
              content.focus({ preventScroll: true });
              const line = content.querySelector('.cm-line') || content;
              anchorSelectionInsideLine(line);
            }
          }
        } catch (_) {}
      }

      let touchStartX = 0;
      let touchStartY = 0;
      let lastTouchMoved = false;

      document.addEventListener('touchstart', (e) => {
        const t = e.touches && e.touches[0];
        if (t) {
          touchStartX = t.clientX;
          touchStartY = t.clientY;
          lastTouchMoved = false;
        }
        try {
          const activeEl = document.activeElement;
          if (activeEl && (isEditableElement(activeEl) || (activeEl.closest && activeEl.closest('.CodeMirror, .cm-editor')))) {
            const scope = getEditorScope(activeEl);
            if (scope && e.target && !scope.contains(e.target)) {
              flushEditableState(activeEl, false);
            }
          }
        } catch (_) {}
      }, { capture: true, passive: true });

      document.addEventListener('touchmove', (e) => {
        if (lastTouchMoved) return;
        const t = e.touches && e.touches[0];
        if (!t) return;
        if (Math.abs(t.clientX - touchStartX) > 10 || Math.abs(t.clientY - touchStartY) > 10) {
          lastTouchMoved = true;
        }
      }, { capture: true, passive: true });

      document.addEventListener('pointerdown', (e) => {
        try {
          const activeEl = document.activeElement;
          if (activeEl && (isEditableElement(activeEl) || (activeEl.closest && activeEl.closest('.CodeMirror, .cm-editor')))) {
            const scope = getEditorScope(activeEl);
            if (scope && e.target && !scope.contains(e.target)) {
              flushEditableState(activeEl, false);
            }
          }
        } catch (_) {}
      }, true);

      document.addEventListener('touchend', handleTouchOrClickFocus, true);
      document.addEventListener('click', handleTouchOrClickFocus, true);

      document.addEventListener('compositionstart', (e) => {
        if (e.target) {
          composingTargets.add(e.target);
          markRecentComposed(e.target);
          const scope = getEditorScope(e.target);
          const prev = scope && quietSyncTimers.get(scope);
          if (prev) clearTimeout(prev);
        }
      }, true);

      document.addEventListener('compositionend', (e) => {
        const t = e.target;
        if (t) {
          composingTargets.delete(t);
          markRecentComposed(t);
        }
        updatePlaceholderVisibility(t);
        setTimeout(() => {
          flushEditableState(t, true);
        }, 16);
      }, true);

      function handleBlurOrFocusOut(e) {
        const t = e.target;
        if (!t) return;
        if (isEditableElement(t) || (t.closest && t.closest('.CodeMirror, .cm-editor'))) {
          flushEditableState(t, false);
          setTimeout(() => {
            flushEditableState(t, false);
          }, 40);
        }
      }

      document.addEventListener('focusout', handleBlurOrFocusOut, true);
      document.addEventListener('blur', handleBlurOrFocusOut, true);

      document.addEventListener('input', (e) => {
        const t = e.target;
        updatePlaceholderVisibility(t);
        const scope = getEditorScope(t);
        if (!scope) return;
        const prev = quietSyncTimers.get(scope);
        if (prev) clearTimeout(prev);

        const isActivePinyin = e.isComposing && typeof e.data === 'string' && /[a-zA-Z'\\u00B4]/.test(e.data);
        if (isActivePinyin) return;

        const shouldWindowSync = !e.isComposing
          || (typeof e.data === 'string' && e.data.length > 0 && !/[a-zA-Z'\\u00B4]/.test(e.data));
        if (!shouldWindowSync) return;

        const timer = setTimeout(() => {
          quietSyncTimers.delete(scope);
          silentWindowSync(t);
        }, 120);
        quietSyncTimers.set(scope, timer);
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

    private var audioSessionActivated = false
    private var commandsRegistered = false
    var onRemoteCommand: ((String, Double?) -> Void)?

    // Activate .playback ONLY on demand when webpage media genuinely starts playing (never steal Apple Music/NetEase on launch!)
    func activateAudioSessionIfNeeded() {
        registerRemoteCommandsIfNeeded()
        guard !audioSessionActivated else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
            try AVAudioSession.sharedInstance().setActive(true)
            audioSessionActivated = true
        } catch {
            // Non-fatal
        }
    }

    private func registerRemoteCommandsIfNeeded() {
        guard !commandsRegistered else { return }
        commandsRegistered = true
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.isEnabled = true
        cc.playCommand.addTarget { _ in
            Task { @MainActor in
                BackgroundMediaController.shared.onRemoteCommand?("play", nil)
            }
            return .success
        }
        cc.pauseCommand.isEnabled = true
        cc.pauseCommand.addTarget { _ in
            Task { @MainActor in
                BackgroundMediaController.shared.onRemoteCommand?("pause", nil)
            }
            return .success
        }
        cc.togglePlayPauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in
                BackgroundMediaController.shared.onRemoteCommand?("togglePlay", nil)
            }
            return .success
        }
        cc.changePlaybackPositionCommand.isEnabled = true
        cc.changePlaybackPositionCommand.addTarget { event in
            let pos = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
            Task { @MainActor in
                BackgroundMediaController.shared.onRemoteCommand?("seekTo", pos)
            }
            return .success
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
