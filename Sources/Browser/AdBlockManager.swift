import Foundation
import WebKit

@MainActor
final class AdBlockManager: ObservableObject {
    static let shared = AdBlockManager()
    @Published private(set) var compiledRuleLists: [WKContentRuleList] = []

    private static let rulePacks: [(identifier: String, resource: String)] = [
        ("prism-easylist-adguard-cn-v1.0.0", "easylist_adguard_cn"),
        ("prism-annoyances-privacy-v1.0.8", "prism_annoyances_privacy")
    ]

    func prepareRules() async {
        guard let store = WKContentRuleListStore.default() else {
            self.compiledRuleLists = []
            return
        }

        var loaded: [WKContentRuleList] = []
        var missingPacks: [(identifier: String, resource: String)] = []

        // Fast path: mount already-compiled rules directly from WebKit C++ cache without reading bundle JSON
        for pack in Self.rulePacks {
            if let existing = try? await store.contentRuleList(forIdentifier: pack.identifier) {
                loaded.append(existing)
            } else {
                missingPacks.append(pack)
            }
        }

        if !missingPacks.isEmpty {
            // Read multi-megabyte JSON rule packs on a background utility thread to avoid main-thread cold-start hitches
            let packsToLoad = missingPacks
            let rawPayloads: [(identifier: String, json: String)] = await Task.detached(priority: .utility) {
                var results: [(identifier: String, json: String)] = []
                for pack in packsToLoad {
                    guard let url = Bundle.main.url(forResource: pack.resource, withExtension: "json"),
                          let jsonStr = try? String(contentsOf: url, encoding: .utf8) else {
                        continue
                    }
                    results.append((pack.identifier, jsonStr))
                }
                return results
            }.value

            for item in rawPayloads {
                if let compiled = try? await store.compileContentRuleList(
                    forIdentifier: item.identifier,
                    encodedContentRuleList: item.json
                ) {
                    loaded.append(compiled)
                }
            }
        }

        self.compiledRuleLists = loaded
    }

    func apply(to userContentController: WKUserContentController, enabled: Bool) {
        userContentController.removeAllContentRuleLists()
        if enabled {
            for ruleList in compiledRuleLists {
                userContentController.add(ruleList)
            }
        }
    }

    static func shouldInterceptNavigation(_ url: URL) -> Bool {
        AppJumpShield.isBlockedSchemeOrAppStore(url) || AppJumpShield.isGatewayURL(url)
    }
}
