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

    static let blockedAppSchemes: Set<String> = [
        "itms-apps", "itms-appss", "itms",
        "tbopen", "taobao", "tmall",
        "bilibili", "snssdk", "snssdk1128", "aweme",
        "weixin", "wechat", "alipays", "alipay",
        "pinduoduo", "openapp.jdmobile", "jdmobile",
        "baiduboxapp", "zhihu", "xhsdiscover", "weibo", "sinaweibo"
    ]

    static let blockedStoreHosts: Set<String> = [
        "apps.apple.com", "itunes.apple.com"
    ]

    func prepareRules() async {
        var loaded: [WKContentRuleList] = []
        let store = WKContentRuleListStore.default()
        for pack in Self.rulePacks {
            if let existing = try? await store.contentRuleList(forIdentifier: pack.identifier) {
                loaded.append(existing)
                continue
            }
            guard let url = Bundle.main.url(forResource: pack.resource, withExtension: "json"),
                  let jsonStr = try? String(contentsOf: url, encoding: .utf8),
                  let compiled = try? await store.compileContentRuleList(
                      forIdentifier: pack.identifier,
                      encodedContentRuleList: jsonStr
                  ) else {
                continue
            }
            loaded.append(compiled)
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
        guard let scheme = url.scheme?.lowercased() else { return false }
        if blockedAppSchemes.contains(scheme) {
            return true
        }
        if (scheme == "http" || scheme == "https"),
           let host = url.host?.lowercased(),
           blockedStoreHosts.contains(host) {
            return true
        }
        return false
    }
}
