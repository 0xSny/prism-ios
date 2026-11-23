import LocalAuthentication
import SwiftUI
import WebKit

struct MenuSheetView: View {
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var tabManager: TabManager
    @ObservedObject var handoffService: HandoffService
    let onOpenSubSheet: (BrowserRootView.ActiveSheet) -> Void
    var onSendPhotoToDesktop: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                        QuickMenuTile(
                            title: L10n.t("新标签", "New Tab"),
                            icon: "plus.square",
                            color: .blue
                        ) {
                            tabManager.createTab(url: nil, activate: true)
                            dismiss()
                        }
                        QuickMenuTile(
                            title: tabManager.isCurrentBookmarked() ? L10n.t("已收藏", "Saved") : L10n.t("收藏", "Bookmark"),
                            icon: tabManager.isCurrentBookmarked() ? "star.fill" : "star",
                            color: .orange
                        ) {
                            tabManager.toggleBookmarkCurrentPage()
                            dismiss()
                        }
                        QuickMenuTile(
                            title: (tabManager.activeTab?.isTranslated == true) ? L10n.t("原文", "Original") : L10n.t("翻译", "Translate"),
                            icon: "character.book.closed",
                            color: .purple
                        ) {
                            tabManager.togglePageTranslation()
                            dismiss()
                        }
                        QuickMenuTile(
                            title: tabManager.desktopMode ? L10n.t("移动版", "Mobile") : L10n.t("桌面版", "Desktop"),
                            icon: "desktopcomputer",
                            color: .indigo
                        ) {
                            tabManager.toggleDesktopUserAgent()
                            dismiss()
                        }
                        if let tab = tabManager.activeTab, !tab.isNewTab, let shareURL = URL(string: tab.urlString) {
                            QuickMenuTile(
                                title: L10n.t("分享本页", "Share"),
                                icon: "square.and.arrow.up",
                                color: .teal
                            ) {
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
                                    BrowserRootView.presentSystemShareSheet(items: [shareURL])
                                }
                            }
                        } else {
                            QuickMenuTile(
                                title: L10n.t("分享本页", "Share"),
                                icon: "square.and.arrow.up",
                                color: .teal
                            ) {
                                tabManager.showToast(L10n.t("请先打开网页再分享", "Open a webpage first"))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                if tabManager.isEffectiveAppDark && tabManager.webDarkModeFollowTheme,
                   let host = tabManager.activeTabHTTPHost {
                    Section {
                        Button {
                            tabManager.toggleWebDarkWhitelistForActiveTab()
                            dismiss()
                        } label: {
                            HStack {
                                Label(
                                    tabManager.isActiveTabWebDarkWhitelisted
                                        ? L10n.t("🌙 恢复此网站网页深色", "🌙 Enable Web Dark Mode")
                                        : L10n.t("🌙 在此网站关闭网页深色", "🌙 Disable Web Dark Mode"),
                                    systemImage: tabManager.isActiveTabWebDarkWhitelisted ? "moon.fill" : "moon.zzz"
                                )
                                Spacer()
                                Text(host)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                if let tab = tabManager.activeTab, tab.hasVideo && !tab.isNewTab {
                    Section(L10n.t("视频控制", "Video Controls")) {
                        Button {
                            tab.webView?.evaluateJavaScript("window.__prismVideoControl && window.__prismVideoControl('pip');", completionHandler: nil)
                            dismiss()
                        } label: {
                            Label(L10n.t("开启 / 退出画中画", "Toggle Picture-in-Picture"), systemImage: "pip.enter")
                        }

                        Picker(selection: Binding(
                            get: { tab.playbackRate },
                            set: { rate in
                                tab.playbackRate = rate
                                tab.webView?.evaluateJavaScript("window.__prismVideoControl && window.__prismVideoControl('rate', \(rate));", completionHandler: nil)
                            }
                        )) {
                            ForEach([1.0, 1.25, 1.5, 2.0, 3.0], id: \.self) { rate in
                                Text("\(String(format: "%.2gx", rate))").tag(rate)
                            }
                        } label: {
                            Label(L10n.t("播放倍速", "Playback Speed"), systemImage: "gauge.with.dots.needle.67percent")
                        }
                    }
                }

                if syncEngine.loggedIn {
                    Section(L10n.t("跨端接力", "Cross-Device Handoff")) {
                        if let tab = tabManager.activeTab, !tab.isNewTab {
                            Button {
                                Task {
                                    let ok = await handoffService.push(
                                        kind: tab.hasVideo ? "video" : "tab",
                                        title: tab.title,
                                        url: tab.urlString,
                                        videoSeconds: tab.hasVideo ? tab.videoSeconds : nil,
                                        syncEngine: syncEngine
                                    )
                                    tabManager.showToast(ok ? L10n.t("已推送到 Windows 桌面端", "Sent to Windows desktop") : L10n.t("发送失败", "Failed"))
                                }
                                dismiss()
                            } label: {
                                Label(L10n.t("发送当前页至 Windows 桌面端", "Send Tab to Windows Desktop"), systemImage: "laptopcomputer.and.arrow.down")
                            }
                        }

                        Button {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                                onSendPhotoToDesktop?()
                            }
                        } label: {
                            Label(L10n.t("🖼 发送相册图片至电脑", "🖼 Send Photo to Desktop"), systemImage: "photo.on.rectangle.angled")
                        }

                        Button {
                            dismiss()
                            tabManager.pushSmartClipboardToDesktop()
                        } label: {
                            Label(L10n.t("📋 发送剪贴板至电脑", "📋 Send Clipboard to Desktop"), systemImage: "doc.on.clipboard")
                        }
                    }
                }

                Section(L10n.t("核心工具", "Tools")) {
                    Button {
                        onOpenSubSheet(.bookmarksHistory)
                    } label: {
                        Label(
                            L10n.t("书签与历史记录 (\(syncEngine.bookmarks.count)/\(syncEngine.history.count))", "Bookmarks & History (\(syncEngine.bookmarks.count)/\(syncEngine.history.count))"),
                            systemImage: "books.vertical"
                        )
                    }

                    Button {
                        onOpenSubSheet(.account)
                    } label: {
                        Label(
                            syncEngine.loggedIn
                                ? "Prism Account (\(syncEngine.email))"
                                : L10n.t("登录 Prism Account 云同步", "Sign in to Prism Account"),
                            systemImage: "person.crop.circle.badge.checkmark"
                        )
                    }

                    Button {
                        onOpenSubSheet(.profiles)
                    } label: {
                        Label(L10n.t("隔离身份与网络代理", "Profiles & Network Proxy"), systemImage: "person.2.badge.key")
                    }

                    Button {
                        onOpenSubSheet(.vault)
                    } label: {
                        Label(L10n.t("面容 ID 密码管家 (\(syncEngine.passwords.count))", "Password Vault (\(syncEngine.passwords.count))"), systemImage: "key.viewfinder")
                    }

                    Button {
                        onOpenSubSheet(.sniffer)
                    } label: {
                        Label(
                            L10n.t("媒体嗅探器 (\(tabManager.activeTab?.sniffedMedia.count ?? 0))", "Media Sniffer (\(tabManager.activeTab?.sniffedMedia.count ?? 0))"),
                            systemImage: "film.stack"
                        )
                    }

                    Button {
                        onOpenSubSheet(.reader)
                    } label: {
                        Label(L10n.t("沉浸式阅读模式", "Reader Mode"), systemImage: "doc.plaintext")
                    }
                    .disabled(tabManager.activeTab?.isNewTab != false)

                    Button {
                        onOpenSubSheet(.downloads)
                    } label: {
                        Label(
                            L10n.t("下载管理 (\(tabManager.downloads.count))", "Downloads (\(tabManager.downloads.count))"),
                            systemImage: "arrow.down.circle"
                        )
                    }

                    Button {
                        onOpenSubSheet(.devtools)
                    } label: {
                        Label(L10n.t("移动端 DevTools 调试器", "Mobile DevTools"), systemImage: "wrench.and.screwdriver")
                    }
                }

                Section(L10n.t("防护与偏好", "Protection & Preferences")) {
                    if let tab = tabManager.activeTab, !tab.isNewTab {
                        HStack {
                            Label(L10n.t("本页已拦截强跳与追踪", "Blocked on Current Page"), systemImage: "checkmark.shield")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(L10n.t("\(tab.blockedCount) 次", "\(tab.blockedCount)"))
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(tab.blockedCount > 0 ? .green : .secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    (tab.blockedCount > 0 ? Color.green.opacity(0.14) : Color(.tertiarySystemFill)),
                                    in: Capsule()
                                )
                        }
                    }
                    Toggle(L10n.t("屏蔽追踪与广告", "Ad & Tracker Blocker"), isOn: $tabManager.adblockEnabled)
                    Toggle(L10n.t("拦截强跳 App Store / 外部App", "Block Rogue App Jumps"), isOn: $tabManager.blockRogueAppJumps)
                    if tabManager.blockRogueAppJumps, let host = tabManager.activeTabHTTPHost {
                        Toggle(isOn: Binding(
                            get: { tabManager.isActiveTabAppJumpWhitelisted },
                            set: { _ in tabManager.toggleAppJumpWhitelistForActiveTab() }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.t("在此网站允许打开外部 App", "Allow External Apps on This Site"))
                                Text(host)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    if !tabManager.appJumpWhitelistHosts.isEmpty {
                        Button(role: .destructive) {
                            tabManager.clearAppJumpWhitelist()
                        } label: {
                            Label(
                                L10n.t(
                                    "清空外部 App 豁免域名 (\(tabManager.appJumpWhitelistHosts.count))",
                                    "Clear External App Exceptions (\(tabManager.appJumpWhitelistHosts.count))"
                                ),
                                systemImage: "hand.raised.slash"
                            )
                        }
                    }
                    Toggle(L10n.t("地址栏回车直达首位命中站点", "Enter Opens Top Hit in Address Bar"), isOn: $tabManager.omniboxEnterTopHitEnabled)
                    Toggle(L10n.t("深色模式下自动将网页变暗", "Auto-Darken Webpages in Dark Mode"), isOn: $tabManager.webDarkModeFollowTheme)
                    if !tabManager.webDarkModeWhitelistHosts.isEmpty {
                        Button(role: .destructive) {
                            tabManager.clearWebDarkWhitelist()
                        } label: {
                            Label(
                                L10n.t(
                                    "清空网页深色豁免域名 (\(tabManager.webDarkModeWhitelistHosts.count))",
                                    "Clear Web Dark Exceptions (\(tabManager.webDarkModeWhitelistHosts.count))"
                                ),
                                systemImage: "moon.circle"
                            )
                        }
                    }
                    Picker(L10n.t("搜索引擎", "Search Engine"), selection: $tabManager.searchEngine) {
                        ForEach(SearchEngineOption.allCases, id: \.self) { eng in
                            Text(eng.title).tag(eng)
                        }
                    }
                    .onChange(of: tabManager.searchEngine) { _, val in
                        UserDefaults.standard.set(val.rawValue, forKey: "prism.searchEngine")
                    }
                    Picker(L10n.t("外观主题", "Theme"), selection: $tabManager.appTheme) {
                        Text(L10n.t("跟随系统", "System")).tag(AppTheme.system)
                        Text(L10n.t("浅色", "Light")).tag(AppTheme.light)
                        Text(L10n.t("深色", "Dark")).tag(AppTheme.dark)
                    }
                    .onChange(of: tabManager.appTheme) { _, val in
                        UserDefaults.standard.set(val.rawValue, forKey: "prism.theme")
                    }
                }
            }
            .navigationTitle("Prism v1.1.2")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("完成", "Done")) { dismiss() }
                }
            }
        }
    }
}

private struct QuickMenuTile: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 44, height: 44)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(MenuTilePressStyle())
    }
}

private struct MenuTilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

// MARK: - Account Sheet

struct AccountSheetView: View {
    @ObservedObject var syncEngine: SyncEngine
    @State private var isRegister = false
    @State private var isResetMode = false
    @State private var email = ""
    @State private var password = ""
    @State private var otpCode = ""
    @State private var recoveryKeyInput = ""
    @State private var generatedRecoveryKey: String?
    @State private var codeCountdown = 0
    @State private var customMinutes = "10"
    @State private var busy = false
    @State private var statusMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if syncEngine.loggedIn {
                    Section(L10n.t("已连接账户", "Connected Account")) {
                        LabeledContent(L10n.t("邮箱", "Email"), value: syncEngine.email)
                        LabeledContent(L10n.t("自动同步状态", "Status"), value: syncEngine.autoSyncIntervalMinutes > 0 ? L10n.t("自动开启", "Auto On") : L10n.t("仅手动", "Manual"))
                        if let ts = syncEngine.lastSyncedAt {
                            LabeledContent(L10n.t("上次同步", "Last Sync"), value: Date(timeIntervalSince1970: ts / 1000).formatted(date: .omitted, time: .shortened))
                        }
                    }

                    Section(L10n.t("自动同步频率", "Sync Interval")) {
                        Picker(L10n.t("频率", "Frequency"), selection: Binding(
                            get: { [1, 5, 15, 30, 60, 0].contains(syncEngine.autoSyncIntervalMinutes) ? syncEngine.autoSyncIntervalMinutes : -1 },
                            set: { newVal in
                                if newVal >= 0 {
                                    syncEngine.updateAutoSyncInterval(newVal)
                                } else {
                                    let val = Int(customMinutes) ?? 10
                                    syncEngine.updateAutoSyncInterval(min(720, max(2, val)))
                                }
                            }
                        )) {
                            Text(L10n.t("每 1 分钟", "Every 1 min")).tag(1)
                            Text(L10n.t("每 5 分钟 (默认)", "Every 5 min")).tag(5)
                            Text(L10n.t("每 15 分钟", "Every 15 min")).tag(15)
                            Text(L10n.t("每 30 分钟", "Every 30 min")).tag(30)
                            Text(L10n.t("每 1 小时", "Every 1 hour")).tag(60)
                            Text(L10n.t("自定义...", "Custom...")).tag(-1)
                            Text(L10n.t("仅手动同步", "Manual only")).tag(0)
                        }
                        if ![1, 5, 15, 30, 60, 0].contains(syncEngine.autoSyncIntervalMinutes) {
                            HStack {
                                TextField(L10n.t("分钟 (2-720)", "Minutes"), text: $customMinutes)
                                    .keyboardType(.numberPad)
                                Button(L10n.t("应用", "Apply")) {
                                    let val = Int(customMinutes) ?? 10
                                    syncEngine.updateAutoSyncInterval(min(720, max(2, val)))
                                }
                            }
                        }
                        Button {
                            Task { await syncEngine.syncNow(forceFullPull: false) }
                        } label: {
                            HStack {
                                if syncEngine.syncing { ProgressView().padding(.trailing, 4) }
                                Text(L10n.t("立即同步云端数据", "Sync Cloud Data Now"))
                            }
                        }
                    }

                    Section(L10n.t("同步作用域", "Scopes")) {
                        Toggle(L10n.t("密码库", "Passwords"), isOn: $syncEngine.scopes.passwords)
                        Toggle(L10n.t("书签", "Bookmarks"), isOn: $syncEngine.scopes.bookmarks)
                        Toggle(L10n.t("首页快捷方式", "Home Shortcuts"), isOn: $syncEngine.scopes.home_shortcuts)
                        Toggle(L10n.t("历史记录", "History"), isOn: $syncEngine.scopes.history)
                        Toggle(L10n.t("隔离身份配置", "Profiles"), isOn: $syncEngine.scopes.profiles)
                    }

                    Section {
                        Button(L10n.t("🗝️ 生成 / 备份 24 位恢复密钥", "🗝️ Generate 24-Char Recovery Key")) {
                            Task {
                                let (ok, res) = await syncEngine.generateRecoveryKey()
                                if ok, let key = res {
                                    generatedRecoveryKey = key
                                    UIPasteboard.general.string = key
                                    statusMessage = L10n.t("已复制 24 位恢复密钥到剪贴板，请妥善保存！", "Recovery key copied!")
                                } else {
                                    statusMessage = res
                                }
                            }
                        }
                        if let rec = generatedRecoveryKey {
                            Text(rec)
                                .font(.caption.monospaced().bold())
                                .textSelection(.enabled)
                        }
                        if let msg = statusMessage {
                            Text(msg).font(.caption).foregroundStyle(.blue)
                        }
                        Button(L10n.t("退出登录", "Sign Out"), role: .destructive) {
                            syncEngine.logout()
                        }
                    }
                } else {
                    if !isResetMode {
                        Section {
                            Picker("", selection: $isRegister) {
                                Text(L10n.t("登录", "Sign In")).tag(false)
                                Text(L10n.t("注册账号", "Create Account")).tag(true)
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    Section {
                        TextField(L10n.t("邮箱地址", "Email"), text: $email)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if isRegister || isResetMode {
                            HStack {
                                TextField(L10n.t("6 位邮箱验证码", "6-digit code"), text: $otpCode)
                                    .keyboardType(.numberPad)
                                Button(codeCountdown > 0 ? "\(codeCountdown)s" : L10n.t("发送验证码", "Send Code")) {
                                    Task {
                                        let (ok, err) = isResetMode
                                            ? await syncEngine.sendResetCode(email: email)
                                            : await syncEngine.sendVerificationCode(email: email)
                                        statusMessage = ok ? L10n.t("验证码已发送至邮箱", "Code sent") : err
                                        if ok { startCountdown() }
                                    }
                                }
                                .disabled(codeCountdown > 0 || email.isEmpty)
                            }
                        }
                        SecureField(
                            isResetMode ? L10n.t("设置新主密码", "New Master Password") : L10n.t("主密码 (零知识端到端密钥)", "Master Password"),
                            text: $password
                        )
                        if isResetMode {
                            TextField(L10n.t("24 位恢复密钥（选填）", "24-char recovery key (optional)"), text: $recoveryKeyInput)
                                .font(.caption.monospaced())
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                        }
                    } footer: {
                        Text(
                            isResetMode
                                ? L10n.t("未填恢复密钥将重置云端旧密文；若填写可无损迁移云端数据。", "Leave recovery key blank to reset cloud vault; provide key for lossless migration.")
                                : L10n.t("PBKDF2 600,000 次 + HKDF + AES-256-GCM 本地加密，与桌面端密钥完全互通。", "PBKDF2 600k + HKDF + AES-256-GCM zero-knowledge sync compatible with Windows.")
                        )
                    }
                    if let msg = syncEngine.lastError ?? statusMessage {
                        Text(msg).font(.caption).foregroundStyle(.red)
                    }
                    Button {
                        Task {
                            busy = true
                            let ok: Bool
                            if isResetMode {
                                ok = await syncEngine.resetPassword(email: email, code: otpCode, newPassword: password, recoveryKey: recoveryKeyInput)
                            } else if isRegister {
                                ok = await syncEngine.register(email: email, password: password, code: otpCode)
                            } else {
                                ok = await syncEngine.login(email: email, password: password)
                            }
                            busy = false
                            if ok { dismiss() }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() }
                            Text(
                                isResetMode
                                    ? L10n.t("验证并重置主密码", "Verify & Reset Password")
                                    : (isRegister ? L10n.t("创建零知识账户", "Create Account") : L10n.t("登录并解锁同步", "Sign In & Sync"))
                            )
                            .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(busy || email.isEmpty || password.count < 6)

                    if !isRegister {
                        Button(isResetMode ? L10n.t("返回登录", "Back to Sign In") : L10n.t("忘记主密码？", "Forgot master password?")) {
                            isResetMode.toggle()
                            statusMessage = nil
                        }
                        .font(.caption)
                    }
                }
            }
            .navigationTitle("Prism Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("完成", "Done")) { dismiss() }
                }
            }
        }
    }

    private func startCountdown() {
        codeCountdown = 60
        Task {
            while codeCountdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                codeCountdown -= 1
            }
        }
    }
}

// MARK: - Profiles & Proxy Sheet

struct ProfilesSheetView: View {
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var tabManager: TabManager
    @State private var newName = ""
    @State private var newProxy = ""
    @State private var proxyMode: ProxyMode = .system
    @State private var showCreate = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(syncEngine.profiles) { prof in
                    Button {
                        tabManager.switchProfileForActiveTab(prof.id)
                        dismiss()
                    } label: {
                        HStack {
                            Circle().fill(prof.swiftColor).frame(width: 12, height: 12)
                            VStack(alignment: .leading) {
                                Text(prof.name).fontWeight(.semibold).foregroundStyle(.primary)
                                Text(prof.proxyMode == .custom && !prof.proxyRules.isEmpty ? "Proxy: \(prof.proxyRules)" : L10n.t("独立 Cookie / 存储容器", "Isolated Data Container"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if prof.id == tabManager.activeProfile.id {
                                Image(systemName: "checkmark").foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.t("隔离身份 (Profile)", "Isolated Profiles"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("新建", "New")) { showCreate = true }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("关闭", "Done")) { dismiss() }
                }
            }
            .sheet(isPresented: $showCreate) {
                NavigationStack {
                    Form {
                        TextField(L10n.t("身份名称", "Profile Name"), text: $newName)
                            .keyboardType(.default)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                        Picker(L10n.t("网络代理", "Proxy Mode"), selection: $proxyMode) {
                            Text(L10n.t("系统代理", "System")).tag(ProxyMode.system)
                            Text(L10n.t("直连", "Direct")).tag(ProxyMode.direct)
                            Text(L10n.t("自定义 HTTP/SOCKS5", "Custom HTTP/SOCKS5")).tag(ProxyMode.custom)
                        }
                        if proxyMode == .custom {
                            TextField("socks5://127.0.0.1:7891", text: $newProxy)
                                .keyboardType(.default)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                        }
                    }
                    .navigationTitle(L10n.t("创建隔离身份", "New Profile"))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L10n.t("取消", "Cancel")) { showCreate = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.t("保存", "Save")) {
                                let pid = UUID().uuidString.lowercased()
                                let prof = BrowserProfile(
                                    id: pid,
                                    name: newName.isEmpty ? "Profile" : newName,
                                    color: ["#6366f1", "#10b981", "#f59e0b", "#ec4899"].randomElement() ?? "#6366f1",
                                    partition: "persist:prism-\(pid)",
                                    proxyMode: proxyMode,
                                    proxyRules: newProxy,
                                    fingerprint: FingerprintConfig(canvasNoise: true, blockTrackers: true),
                                    createdAt: Date().timeIntervalSince1970 * 1000
                                )
                                syncEngine.profiles.append(prof)
                                syncEngine.notifyScopeDirty("profiles")
                                showCreate = false
                            }
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }
    }
}

// MARK: - Password Vault Sheet

struct VaultSheetView: View {
    @ObservedObject var syncEngine: SyncEngine
    @State private var search = ""
    @State private var unlockedIds = Set<String>()
    @State private var copiedFeedbackId: String?
    @State private var showAddEntrySheet = false
    @State private var newOrigin = ""
    @State private var newUsername = ""
    @State private var newPassword = ""
    @State private var newNote = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if filtered.isEmpty {
                    ContentUnavailableView(
                        L10n.t("暂无保存的密码", "No Saved Passwords"),
                        systemImage: "key.viewfinder",
                        description: Text(L10n.t("点击右上角 + 可手动添加账号密码，或登录网站自动保存", "Tap + above to add manually or save automatically on sign-in"))
                    )
                } else {
                    ForEach(filtered) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                FaviconView(urlString: item.origin, title: item.origin, size: 22, cornerRadius: 5)
                                Text(item.origin).font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Spacer()
                                if copiedFeedbackId == item.id {
                                    Text(L10n.t("已复制", "Copied"))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.green)
                                }
                                Button(unlockedIds.contains(item.id) ? L10n.t("复制密码", "Copy") : L10n.t("解锁查看", "Reveal")) {
                                    authenticateAndReveal(item)
                                }
                                .font(.caption.weight(.bold))
                                .buttonStyle(.borderless)
                            }

                            HStack {
                                Text(item.username.isEmpty ? L10n.t("无用户名", "No username") : item.username)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                if !item.username.isEmpty {
                                    Button {
                                        UIPasteboard.general.string = item.username
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        copiedFeedbackId = item.id
                                    } label: {
                                        Label(L10n.t("复制账号", "Copy User"), systemImage: "person.crop.square")
                                            .font(.caption2.weight(.medium))
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }

                            if unlockedIds.contains(item.id) {
                                Text(item.password)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.blue)
                                    .textSelection(.enabled)
                            }
                            if let note = item.note, !note.isEmpty {
                                Text(note)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                deletePasswordItem(item)
                            } label: {
                                Label(L10n.t("删除", "Delete"), systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .searchable(text: $search)
            .keyboardType(.default)
            .submitLabel(.search)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .navigationTitle(L10n.t("加密密码库", "Password Vault"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        newOrigin = ""
                        newUsername = ""
                        newPassword = ""
                        newNote = ""
                        showAddEntrySheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("完成", "Done")) { dismiss() }
                }
            }
            .sheet(isPresented: $showAddEntrySheet) {
                NavigationStack {
                    Form {
                        Section(L10n.t("网站与账号", "Site & Credentials")) {
                            TextField(L10n.t("网站域名或网址（如 github.com）", "Website or domain (e.g. github.com)"), text: $newOrigin)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .keyboardType(.URL)
                            TextField(L10n.t("用户名 / 邮箱", "Username / Email"), text: $newUsername)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                            SecureField(L10n.t("密码", "Password"), text: $newPassword)
                            TextField(L10n.t("备注（可选）", "Note (optional)"), text: $newNote)
                        }
                    }
                    .navigationTitle(L10n.t("新增密码条目", "Add Password"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L10n.t("取消", "Cancel")) { showAddEntrySheet = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.t("保存", "Save")) {
                                saveNewPasswordEntry()
                            }
                            .disabled(newOrigin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newPassword.isEmpty)
                        }
                    }
                }
            }
        }
    }

    private var filtered: [PasswordEntry] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return syncEngine.passwords }
        return syncEngine.passwords.filter { $0.origin.lowercased().contains(q) || $0.username.lowercased().contains(q) }
    }

    private func deletePasswordItem(_ item: PasswordEntry) {
        syncEngine.recordDeletedPassword(item)
        syncEngine.notifyScopeDirty("passwords")
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func saveNewPasswordEntry() {
        var normalizedOrigin = newOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedOrigin.contains("://") {
            normalizedOrigin = "https://\(normalizedOrigin)"
        }
        let nowMs = Date().timeIntervalSince1970 * 1000
        let entry = PasswordEntry(
            id: UUID().uuidString,
            origin: normalizedOrigin,
            username: newUsername.trimmingCharacters(in: .whitespacesAndNewlines),
            password: newPassword,
            note: newNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : newNote.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: nowMs,
            updatedAt: nowMs
        )
        syncEngine.markPasswordChanged(entry)
        syncEngine.notifyScopeDirty("passwords")
        showAddEntrySheet = false
    }

    private func authenticateAndReveal(_ item: PasswordEntry) {
        if unlockedIds.contains(item.id) {
            UIPasteboard.general.string = item.password
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            copiedFeedbackId = item.id
            return
        }
        let ctx = LAContext()
        var err: NSError?
        if ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) {
            ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: L10n.t("解锁密码库条目", "Unlock password entry")) { ok, _ in
                guard ok else { return }
                Task { @MainActor in
                    unlockedIds.insert(item.id)
                    UIPasteboard.general.string = item.password
                    copiedFeedbackId = item.id
                }
            }
        } else {
            unlockedIds.insert(item.id)
            UIPasteboard.general.string = item.password
            copiedFeedbackId = item.id
        }
    }
}

// MARK: - Media Sniffer Sheet

struct SnifferSheetView: View {
    let tab: BrowserTab?
    @State private var feedback: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let msg = feedback {
                    Text(msg).font(.caption).foregroundStyle(.blue)
                }
                if let items = tab?.sniffedMedia, !items.isEmpty {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(item.mediaExt.uppercased())
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.14), in: Capsule())
                                Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                            }
                            Text(item.url).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            HStack {
                                Button(L10n.t("下载到相册/文件", "Save Media")) {
                                    Task {
                                        let (_, status) = await BackgroundMediaController.downloadAndSaveMedia(urlString: item.url)
                                        feedback = status
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)

                                Button(L10n.t("复制直链", "Copy URL")) {
                                    UIPasteboard.general.string = item.url
                                    feedback = L10n.t("已复制媒体链接", "Copied URL")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                } else {
                    Text(L10n.t("当前网页尚未捕获 .mp4 / .m3u8 媒体资源。", "No media resources captured yet."))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(L10n.t("媒体嗅探", "Media Sniffer"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("关闭", "Done")) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Mobile DevTools Bottom Sheet

struct MobileDevToolsSheetView: View {
    let tab: BrowserTab?
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var handoffService: HandoffService
    @ObservedObject var tabManager: TabManager

    @State private var selectedTab = 0
    @State private var storageText = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let activeTab = tab {
            MobileDevToolsContent(
                tab: activeTab,
                syncEngine: syncEngine,
                handoffService: handoffService,
                tabManager: tabManager,
                selectedTab: $selectedTab,
                storageText: $storageText,
                onDismiss: { dismiss() }
            )
            .onAppear { tabManager.setDevToolsActive(true) }
            .onDisappear { tabManager.setDevToolsActive(false) }
        } else {
            NavigationStack {
                ContentUnavailableView(
                    L10n.t("无活动标签页", "No Active Tab"),
                    systemImage: "wrench.and.screwdriver"
                )
                .navigationTitle("Mobile DevTools")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.t("完成", "Done")) { dismiss() }
                    }
                }
            }
        }
    }
}

private struct MobileDevToolsContent: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var handoffService: HandoffService
    @ObservedObject var tabManager: TabManager
    @Binding var selectedTab: Int
    @Binding var storageText: String
    let onDismiss: () -> Void

    var body: some View {
        let _ = tab.devToolsRevision
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    Text("Console (\(tab.consoleLogs.count))").tag(0)
                    Text("Network (\(tab.networkLogs.count))").tag(1)
                    Text("Storage").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()

                if selectedTab == 0 {
                    List(tab.consoleLogs) { log in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(log.level.uppercased()).font(.caption2.bold()).foregroundStyle(log.level == "error" ? .red : .blue)
                            Text(log.message).font(.caption.monospaced())
                        }
                    }
                } else if selectedTab == 1 {
                    List(tab.networkLogs) { req in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("\(req.method) \(req.status)").font(.caption2.bold())
                                    .foregroundStyle(req.status >= 400 || req.status == 0 ? .red : .green)
                                Spacer()
                                Text("\(req.durationMs)ms").font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(req.url).font(.caption2.monospaced()).lineLimit(2)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button(L10n.t("读取 Cookie / LocalStorage", "Inspect Storage")) {
                                fetchStorage()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button(L10n.t("加密推送至桌面", "Push to Desktop")) {
                                Task {
                                    guard !storageText.isEmpty else { return }
                                    let ok = await handoffService.push(kind: "clipboard", title: "Session Storage", url: tab.urlString, text: storageText, syncEngine: syncEngine)
                                    tabManager.showToast(ok ? L10n.t("已通过零知识通道推送至桌面", "Pushed encrypted storage") : L10n.t("需先登录 Prism Account", "Sign in required"))
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.horizontal)

                        ScrollView {
                            Text(storageText.isEmpty ? L10n.t("点击上方按钮提取当前站点 Cookie 与 LocalStorage...", "Tap Inspect Storage above...") : storageText)
                                .font(.caption.monospaced())
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .navigationTitle("Mobile DevTools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("完成", "Done")) { onDismiss() }
                }
            }
            .onAppear { fetchStorage() }
        }
    }

    private func fetchStorage() {
        let js = """
        JSON.stringify({ cookie: document.cookie, localStorage: Object.assign({}, window.localStorage) }, null, 2);
        """
        tab.webView?.evaluateJavaScript(js) { res, _ in
            if let s = res as? String {
                Task { @MainActor in storageText = s }
            }
        }
    }
}

// MARK: - Reader Mode Sheet

struct ReaderModeSheetView: View {
    @ObservedObject var tabManager: TabManager
    @Environment(\.dismiss) private var dismiss

    enum ReaderTheme: String, CaseIterable, Identifiable {
        case paper, sepia, dark
        var id: String { rawValue }
        var bg: Color {
            switch self {
            case .paper: return Color(red: 1.0, green: 0.992, blue: 0.976)
            case .sepia: return Color(red: 0.965, green: 0.933, blue: 0.859)
            case .dark: return Color(red: 0.094, green: 0.102, blue: 0.118)
            }
        }
        var fg: Color {
            switch self {
            case .paper, .sepia: return Color(red: 0.13, green: 0.14, blue: 0.16)
            case .dark: return Color(red: 0.89, green: 0.90, blue: 0.92)
            }
        }
        var label: String {
            switch self {
            case .paper: return L10n.t("纯净白", "Paper")
            case .sepia: return L10n.t("护眼黄", "Sepia")
            case .dark: return L10n.t("夜间黑", "Dark")
            }
        }
    }

    @State private var article: ReaderArticle?
    @State private var isLoading = true
    @State private var fontSize: Double = 17
    @State private var theme: ReaderTheme = .paper

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(L10n.t("正在提取正文排版...", "Extracting article..."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let article, !article.paragraphs.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(article.siteHost)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(theme == .dark ? .gray : .secondary)
                                Text(article.title)
                                    .font(.system(size: fontSize + 7, weight: .bold, design: .serif))
                                    .foregroundStyle(theme.fg)
                                if !article.byline.isEmpty {
                                    Text(article.byline)
                                        .font(.caption)
                                        .foregroundStyle(theme == .dark ? .gray : .secondary)
                                }
                            }
                            Divider()
                            ForEach(Array(article.paragraphs.enumerated()), id: \.offset) { _, p in
                                Text(p)
                                    .font(.system(size: fontSize, design: .serif))
                                    .lineSpacing(fontSize * 0.42)
                                    .foregroundStyle(theme.fg)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 20)
                    }
                    .background(theme.bg.ignoresSafeArea())
                } else {
                    ContentUnavailableView(
                        L10n.t("当前页面暂无可提取的正文", "No Readable Article Found"),
                        systemImage: "doc.plaintext",
                        description: Text(L10n.t("请先打开文章、博客或新闻详情页再启用阅读模式。", "Open an article or blog post to read cleanly."))
                    )
                }
            }
            .navigationTitle(L10n.t("阅读模式", "Reader"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { fontSize = max(14, fontSize - 1) } label: { Text("A-").font(.subheadline.weight(.semibold)) }
                    Button { fontSize = min(26, fontSize + 1) } label: { Text("A+").font(.subheadline.weight(.semibold)) }
                }
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $theme) {
                        ForEach(ReaderTheme.allCases) { t in
                            Text(t.label).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 190)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("完成", "Done")) { dismiss() }
                }
            }
            .onAppear {
                if tabManager.isEffectiveAppDark { theme = .dark }
                tabManager.extractReaderArticle { extracted in
                    self.article = extracted
                    self.isLoading = false
                }
            }
        }
    }
}

// MARK: - Downloads Sheet

struct DownloadsSheetView: View {
    @ObservedObject var tabManager: TabManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if tabManager.downloads.isEmpty {
                    ContentUnavailableView(
                        L10n.t("暂无下载记录", "No Downloads Yet"),
                        systemImage: "arrow.down.circle",
                        description: Text(L10n.t("浏览网页触发文件下载时，会在此自动接管并保存。", "File downloads triggered in webpages appear here."))
                    )
                } else {
                    List {
                        ForEach(tabManager.downloads) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(item.filename)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                    Spacer()
                                    if item.status == .downloading {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                    } else if item.status == .completed, let fileURL = item.localURL {
                                        ShareLink(item: fileURL) {
                                            Image(systemName: "square.and.arrow.up")
                                                .font(.subheadline)
                                        }
                                    } else if item.status == .failed {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.red)
                                    }
                                }
                                HStack {
                                    Text(statusText(item))
                                        .font(.caption)
                                        .foregroundStyle(item.status == .failed ? .red : .secondary)
                                    Spacer()
                                    if item.byteCount > 0 {
                                        Text(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .onDelete { offsets in
                            for idx in offsets {
                                if let url = tabManager.downloads[idx].localURL {
                                    try? FileManager.default.removeItem(at: url)
                                }
                            }
                            tabManager.downloads.remove(atOffsets: offsets)
                        }
                    }
                }
            }
            .navigationTitle(L10n.t("下载管理", "Downloads"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !tabManager.downloads.isEmpty {
                        Button(role: .destructive) {
                            for d in tabManager.downloads {
                                if let url = d.localURL { try? FileManager.default.removeItem(at: url) }
                            }
                            tabManager.downloads.removeAll()
                        } label: {
                            Text(L10n.t("清空", "Clear"))
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("完成", "Done")) { dismiss() }
                }
            }
        }
    }

    private func statusText(_ item: DownloadRecord) -> String {
        switch item.status {
        case .downloading: return L10n.t("下载中...", "Downloading...")
        case .completed: return L10n.t("已保存 · 点击右侧可分享至“文件”", "Saved · Share to Files")
        case .failed: return item.errorMessage ?? L10n.t("下载失败", "Download failed")
        }
    }
}

// MARK: - Bookmarks & History Sheet

struct BookmarksHistorySheetView: View {
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var tabManager: TabManager

    @State private var segment: Int = 0
    @State private var search: String = ""
    @State private var showClearConfirm = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $segment) {
                    Text(L10n.t("书签 (\(urlBookmarks.count))", "Bookmarks (\(urlBookmarks.count))")).tag(0)
                    Text(L10n.t("历史记录 (\(syncEngine.history.count))", "History (\(syncEngine.history.count))")).tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                List {
                    if segment == 0 {
                        if filteredBookmarks.isEmpty {
                            ContentUnavailableView(
                                L10n.t("暂无书签", "No Bookmarks"),
                                systemImage: "star",
                                description: Text(L10n.t("在菜单点击“收藏”即可跨设备云同步书签", "Bookmark any page from Menu to sync across devices"))
                            )
                        } else {
                            ForEach(filteredBookmarks) { bm in
                                Button {
                                    if let url = URL(string: bm.url) {
                                        tabManager.createTab(url: url, activate: true)
                                        dismiss()
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        FaviconView(urlString: bm.url, title: bm.title, size: 28, cornerRadius: 7)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(bm.title.isEmpty ? bm.url : bm.title)
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Text(SmartOmniboxEngine.hostOnly(bm.url).isEmpty ? bm.url : SmartOmniboxEngine.hostOnly(bm.url))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.up.forward")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        syncEngine.recordDeletedBookmark(bm)
                                        syncEngine.notifyScopeDirty("bookmarks")
                                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    } label: {
                                        Label(L10n.t("删除", "Delete"), systemImage: "trash")
                                    }
                                }
                            }
                        }
                    } else {
                        if filteredHistory.isEmpty {
                            ContentUnavailableView(
                                L10n.t("暂无浏览历史", "No History"),
                                systemImage: "clock",
                                description: Text(L10n.t("你访问过的网页会加密同步到此列表", "Visited pages appear here and sync encrypted"))
                            )
                        } else {
                            ForEach(filteredHistory) { item in
                                Button {
                                    if let url = URL(string: item.url) {
                                        tabManager.createTab(url: url, activate: true)
                                        dismiss()
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        FaviconView(urlString: item.url, title: item.title, size: 28, cornerRadius: 7)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title.isEmpty ? item.url : item.title)
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            HStack(spacing: 6) {
                                                Text(SmartOmniboxEngine.hostOnly(item.url).isEmpty ? item.url : SmartOmniboxEngine.hostOnly(item.url))
                                                    .lineLimit(1)
                                                Text("·")
                                                Text(relativeVisitTime(item.visitedAt))
                                            }
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        syncEngine.history.removeAll(where: { $0.id == item.id })
                                        syncEngine.notifyScopeDirty("history")
                                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    } label: {
                                        Label(L10n.t("删除", "Delete"), systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .searchable(text: $search, prompt: Text(L10n.t("搜索标题或网址", "Search title or URL")))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .navigationTitle(L10n.t("书签与历史记录", "Bookmarks & History"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if segment == 1 && !syncEngine.history.isEmpty {
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Text(L10n.t("清空历史", "Clear"))
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("完成", "Done")) { dismiss() }
                }
            }
            .confirmationDialog(
                L10n.t("清空全部浏览历史记录？", "Clear all browsing history?"),
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button(L10n.t("清空历史记录", "Clear All History"), role: .destructive) {
                    syncEngine.history.removeAll()
                    syncEngine.notifyScopeDirty("history")
                }
                Button(L10n.t("取消", "Cancel"), role: .cancel) {}
            }
        }
    }

    private var urlBookmarks: [BookmarkItem] {
        syncEngine.bookmarks.filter { ($0.type ?? "url") != "folder" && !$0.url.isEmpty }
    }

    private var filteredBookmarks: [BookmarkItem] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let list = urlBookmarks
        guard !q.isEmpty else { return list }
        return list.filter { $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q) }
    }

    private var filteredHistory: [HistoryItem] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return syncEngine.history }
        return syncEngine.history.filter { $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q) }
    }

    private func relativeVisitTime(_ ms: Double) -> String {
        let dt = Date(timeIntervalSince1970: ms / 1000.0)
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: dt, relativeTo: Date())
    }
}
