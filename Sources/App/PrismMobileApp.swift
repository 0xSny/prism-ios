import SwiftUI
import UIKit

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
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                handoffService.handleForegroundResume(syncEngine: syncEngine)
                tabManager.checkClipboardForURL()
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    handoffService.handleForegroundResume(syncEngine: syncEngine)
                    tabManager.checkClipboardForURL()
                case .background:
                    handoffService.pauseForBackground()
                    Task { await syncEngine.flushPendingBeforeBackground() }
                default:
                    break
                }
            }
        }
    }
}
