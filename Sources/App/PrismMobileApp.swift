import SwiftUI

@main
struct PrismMobileApp: App {
    @StateObject private var syncEngine = SyncEngine()
    @StateObject private var tabManager = TabManager()
    @StateObject private var handoffService = HandoffService()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            BrowserRootView(
                syncEngine: syncEngine,
                tabManager: tabManager,
                handoffService: handoffService
            )
            .task {
                tabManager.syncEngine = syncEngine
                tabManager.handoffService = handoffService
                await AdBlockManager.shared.prepareRules()
                handoffService.startPolling(syncEngine: syncEngine)
                tabManager.checkClipboardForURL()
            }
            .onOpenURL { url in
                tabManager.handleDeepLink(url)
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    tabManager.checkClipboardForURL()
                    Task { await handoffService.pollOnce(syncEngine: syncEngine) }
                case .background:
                    Task { await syncEngine.flushPendingBeforeBackground() }
                default:
                    break
                }
            }
        }
    }
}
