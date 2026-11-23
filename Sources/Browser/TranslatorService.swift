import Foundation
import WebKit

enum TranslatorService {
    private static let chunkSize = 25

    static func translateBatch(_ texts: [String], targetLang: String = "zh-CN") async -> (texts: [String], ok: Bool) {
        guard !texts.isEmpty else { return ([], true) }

        var indexedChunks: [(start: Int, slice: [String])] = []
        var offset = 0
        while offset < texts.count {
            let end = min(texts.count, offset + chunkSize)
            indexedChunks.append((offset, Array(texts[offset..<end])))
            offset = end
        }

        var output = texts
        var allSucceeded = true

        await withTaskGroup(of: (Int, [String]?, Bool).self) { group in
            for chunk in indexedChunks {
                group.addTask {
                    let res = await translateSingleChunkPOST(chunk.slice, startIndex: chunk.start, targetLang: targetLang)
                    return (chunk.start, res, res != nil)
                }
            }
            for await (start, translatedSlice, ok) in group {
                if ok, let translatedSlice, translatedSlice.count == min(chunkSize, texts.count - start) {
                    for i in 0..<translatedSlice.count {
                        output[start + i] = translatedSlice[i]
                    }
                } else {
                    allSucceeded = false
                }
            }
        }

        return (output, allSucceeded)
    }

    private static func translateSingleChunkPOST(_ slice: [String], startIndex: Int, targetLang: String) async -> [String]? {
        guard !slice.isEmpty else { return [] }
        // Numeric boundary tags resist machine translation reformatting & align reliably via regex
        var taggedParts: [String] = []
        for (i, item) in slice.enumerated() {
            let marker = "[[P_\(startIndex + i)]]"
            taggedParts.append("\(marker)\n\(item)")
        }
        let payloadText = taggedParts.joined(separator: "\n")

        guard var comps = URLComponents(string: "https://translate.googleapis.com/translate_a/single") else {
            return nil
        }
        comps.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: targetLang),
            URLQueryItem(name: "dt", value: "t")
        ]
        guard let url = comps.url else { return nil }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12.0)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")

        var bodyAllowed = CharacterSet.urlQueryAllowed
        bodyAllowed.remove(charactersIn: "+&=?")
        let encodedPayload = payloadText.addingPercentEncoding(withAllowedCharacters: bodyAllowed) ?? payloadText
        req.httpBody = "q=\(encodedPayload)".data(using: .utf8)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let root = try JSONSerialization.jsonObject(with: data) as? [Any],
                  let sentences = root.first as? [[Any]] else {
                return nil
            }
            let merged = sentences.compactMap { $0.first as? String }.joined()
            return parseMergedChunk(merged, slice: slice, startIndex: startIndex)
        } catch {
            return nil
        }
    }

    private static func parseMergedChunk(_ merged: String, slice: [String], startIndex: Int) -> [String]? {
        let pattern = #"(?:\[\[|\[\s*\[)\s*P[_\s-]*(\d+)\s*(?:\]\]|\]\s*\])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(merged.startIndex..<merged.endIndex, in: merged)
        let matches = regex.matches(in: merged, range: nsRange)
        if matches.isEmpty { return nil }

        var map: [Int: String] = [:]
        for (i, match) in matches.enumerated() {
            guard let idRange = Range(match.range(at: 1), in: merged),
                  let idx = Int(merged[idRange]),
                  let fullRange = Range(match.range, in: merged) else { continue }
            let contentStart = fullRange.upperBound
            let contentEnd: String.Index
            if i + 1 < matches.count, let nextRange = Range(matches[i + 1].range, in: merged) {
                contentEnd = nextRange.lowerBound
            } else {
                contentEnd = merged.endIndex
            }
            let text = String(merged[contentStart..<contentEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            map[idx] = text
        }

        var result: [String] = []
        result.reserveCapacity(slice.count)
        for i in 0..<slice.count {
            let absIdx = startIndex + i
            if let val = map[absIdx], !val.isEmpty {
                result.append(val)
            } else {
                result.append(slice[i])
            }
        }
        return map.isEmpty ? nil : result
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
      const candidateRoot = document.querySelector('article, main, [role="main"]');
      const root = (candidateRoot && (candidateRoot.innerText || '').trim().length > 200) ? candidateRoot : document.body;
      if (!root) return { texts: [] };
      const skipTags = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'CODE', 'PRE', 'TEXTAREA', 'INPUT']);
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      const list = [];
      let n;
      while ((n = walker.nextNode())) {
        const parentTag = n.parentElement ? n.parentElement.tagName : '';
        if (skipTags.has(parentTag)) continue;
        const t = (n.nodeValue || '').trim();
        if (t.length < 2 || t.length > 800) continue;
        list.push({ node: n, orig: n.nodeValue });
        if (list.length >= 240) break;
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
