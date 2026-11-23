import SwiftUI
import UIKit

@MainActor
final class PrismHostingController<Content: View>: UIHostingController<Content> {
    var dynamicStatusBarStyle: UIStatusBarStyle = .default {
        didSet {
            if oldValue != dynamicStatusBarStyle {
                setNeedsStatusBarAppearanceUpdate()
            }
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        dynamicStatusBarStyle
    }
}

@MainActor
final class StatusBarStyleManager {
    static let shared = StatusBarStyleManager()
    weak var hostController: PrismHostingController<AnyView>?

    func applyStyle(for color: UIColor?, fallbackTrait: UITraitCollection? = nil) {
        let nextStyle: UIStatusBarStyle
        let trait = fallbackTrait ?? hostController?.traitCollection ?? UITraitCollection.current
        if let color {
            let resolved = color.resolvedColor(with: trait)
            var r: CGFloat = 1
            var g: CGFloat = 1
            var b: CGFloat = 1
            var a: CGFloat = 1
            if resolved.getRed(&r, green: &g, blue: &b, alpha: &a) {
                let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
                nextStyle = luminance < 0.45 ? .lightContent : .darkContent
            } else {
                nextStyle = trait.userInterfaceStyle == .dark ? .lightContent : .darkContent
            }
        } else {
            nextStyle = trait.userInterfaceStyle == .dark ? .lightContent : .darkContent
        }
        hostController?.dynamicStatusBarStyle = nextStyle
    }

    func applyWindowOverride(_ style: UIUserInterfaceStyle) {
        hostController?.view.window?.overrideUserInterfaceStyle = style
        hostController?.overrideUserInterfaceStyle = style
    }
}

@MainActor
final class PrismAppStateContainer {
    static let shared = PrismAppStateContainer()
    let syncEngine = SyncEngine()
    let tabManager = TabManager()
    let handoffService = HandoffService()
    private var didBootstrap = false

    func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true
        tabManager.syncEngine = syncEngine
        tabManager.handoffService = handoffService
        Task {
            await AdBlockManager.shared.prepareRules()
            tabManager.applyAdblockToAllTabs()
        }
        handoffService.startPolling(syncEngine: syncEngine)
        tabManager.checkClipboardForURL()
    }
}

@main
final class PrismAppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        config.delegateClass = PrismSceneDelegate.self
        return config
    }
}

@MainActor
final class PrismSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let state = PrismAppStateContainer.shared
        let rootView = BrowserRootView(
            syncEngine: state.syncEngine,
            tabManager: state.tabManager,
            handoffService: state.handoffService
        )
        let host = PrismHostingController(rootView: AnyView(rootView))
        StatusBarStyleManager.shared.hostController = host

        let win = UIWindow(windowScene: windowScene)
        win.rootViewController = host
        let initialStyle: UIUserInterfaceStyle = {
            switch state.tabManager.appTheme {
            case .dark: return .dark
            case .light: return .light
            case .system: return .unspecified
            }
        }()
        win.overrideUserInterfaceStyle = initialStyle
        host.overrideUserInterfaceStyle = initialStyle
        win.makeKeyAndVisible()
        self.window = win

        state.bootstrapIfNeeded()
        for ctx in connectionOptions.urlContexts {
            state.tabManager.handleDeepLink(ctx.url)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        let state = PrismAppStateContainer.shared
        for ctx in URLContexts {
            state.tabManager.handleDeepLink(ctx.url)
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        let state = PrismAppStateContainer.shared
        state.tabManager.syncAppearanceOnForegroundResume(window: window)
        state.handoffService.handleForegroundResume(syncEngine: state.syncEngine)
        state.tabManager.checkClipboardForURL()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        let state = PrismAppStateContainer.shared
        state.handoffService.pauseForBackground()
        Task { await state.syncEngine.flushPendingBeforeBackground() }
    }
}
