import Foundation
import WebKit

@MainActor
final class AdBlockManager: ObservableObject {
    static let shared = AdBlockManager()
    @Published private(set) var compiledRuleList: WKContentRuleList?

    private static let ruleIdentifier = "prism-easylist-adguard-cn-v1.0.0"

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
        if let existing = try? await WKContentRuleListStore.default().contentRuleList(forIdentifier: Self.ruleIdentifier) {
            self.compiledRuleList = existing
            return
        }
        guard let url = Bundle.main.url(forResource: "easylist_adguard_cn", withExtension: "json"),
              let jsonStr = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }
        if let compiled = try? await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: Self.ruleIdentifier,
            encodedContentRuleList: jsonStr
        ) {
            self.compiledRuleList = compiled
        }
    }

    func apply(to userContentController: WKUserContentController, enabled: Bool) {
        userContentController.removeAllContentRuleLists()
        if enabled, let compiledRuleList {
            userContentController.add(compiledRuleList)
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
