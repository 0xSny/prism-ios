import Foundation
import WebKit

enum TranslatorService {
    static func translateBatch(_ texts: [String], targetLang: String = "zh-CN") async -> [String] {
        guard !texts.isEmpty else { return [] }
        let joined = texts.joined(separator: "\n[[PRISM_SEP]]\n")
        guard var comps = URLComponents(string: "https://translate.googleapis.com/translate_a/single") else {
            return texts
        }
        comps.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: targetLang),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: joined),
        ]
        guard let url = comps.url else { return texts }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let root = try JSONSerialization.jsonObject(with: data) as? [Any],
                  let sentences = root.first as? [[Any]] else {
                return texts
            }
            let merged = sentences.compactMap { $0.first as? String }.joined()
            let parts = merged.components(separatedBy: "\n[[PRISM_SEP]]\n")
            if parts.count == texts.count {
                return parts
            }
            return texts
        } catch {
            return texts
        }
    }

    static let collectNodesJS = """
    (function() {
      if (window.__prismOrigTexts && window.__prismTranslatedActive) {
        return { toggleOff: true, count: window.__prismOrigTexts.length };
      }
      if (window.__prismOrigTexts && !window.__prismTranslatedActive) {
        for (const item of window.__prismOrigTexts) {
          if (item.node && item.translated) item.node.nodeValue = item.translated;
        }
        window.__prismTranslatedActive = true;
        return { toggleOn: true, count: window.__prismOrigTexts.length };
      }
      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      const list = [];
      let n;
      while ((n = walker.nextNode())) {
        const parentTag = n.parentElement ? n.parentElement.tagName : '';
        if (parentTag === 'SCRIPT' || parentTag === 'STYLE' || parentTag === 'NOSCRIPT' || parentTag === 'CODE') continue;
        const t = (n.nodeValue || '').trim();
        if (t.length < 3 || t.length > 500) continue;
        list.push({ node: n, orig: n.nodeValue });
        if (list.length >= 120) break;
      }
      window.__prismOrigTexts = list;
      return { texts: list.map(i => i.orig) };
    })();
    """

    static func toggleOriginalJS() -> String {
        """
        (function() {
          if (!window.__prismOrigTexts) return false;
          for (const item of window.__prismOrigTexts) {
            if (item.node) item.node.nodeValue = item.orig;
          }
          window.__prismTranslatedActive = false;
          return true;
        })();
        """
    }

    static func applyTranslationsJS(_ translations: [String]) -> String {
        guard let jsonData = try? JSONEncoder().encode(translations),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            return ""
        }
        return """
        (function() {
          const arr = \(jsonStr);
          if (!window.__prismOrigTexts) return;
          for (let i = 0; i < Math.min(arr.length, window.__prismOrigTexts.length); i++) {
            window.__prismOrigTexts[i].translated = arr[i];
            if (window.__prismOrigTexts[i].node) {
              window.__prismOrigTexts[i].node.nodeValue = arr[i];
            }
          }
          window.__prismTranslatedActive = true;
        })();
        """
    }
}
