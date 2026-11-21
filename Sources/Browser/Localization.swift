import Foundation

enum L10n {
    static var isEnglish: Bool {
        let saved = UserDefaults.standard.string(forKey: "prism.lang")
        if let saved {
            return saved == AppLang.en.rawValue
        }
        return !(Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? true)
    }

    static func t(_ zh: String, _ en: String) -> String {
        isEnglish ? en : zh
    }
}
