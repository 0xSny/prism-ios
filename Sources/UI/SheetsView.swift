import LocalAuthentication
import SwiftUI
import WebKit

struct MenuSheetView: View {
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var tabManager: TabManager
    @ObservedObject var handoffService: HandoffService
    let onOpenSubSheet: (BrowserRootView.ActiveSheet) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        QuickMenuTile(
                            title: L10n.t("新标签页", "New Tab"),
                            icon: "plus.square",
                            color: .blue
                        ) {
                            tabManager.createTab(url: nil, activate: true)
                            dismiss()
                        }
                        QuickMenuTile(
                            title: tabManager.isCurrentBookmarked() ? L10n.t("已收藏", "Saved") : L10n.t("收藏本页", "Bookmark"),
                            icon: tabManager.isCurrentBookmarked() ? "star.fill" : "star",
                            color: .orange
                        ) {
                            tabManager.toggleBookmarkCurrentPage()
                            dismiss()
                        }
                        QuickMenuTile(
                            title: (tabManager.activeTab?.isTranslated == true) ? L10n.t("恢复原文", "Original") : L10n.t("中文翻译", "Translate"),
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
                    }
                    .padding(.vertical, 4)
                }

                if syncEngine.loggedIn, let tab = tabManager.activeTab, !tab.isNewTab {
                    Section {
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
                }

                Section(L10n.t("核心工具", "Tools")) {
                    Button {
                        dismiss()
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
                        dismiss()
                        onOpenSubSheet(.profiles)
                    } label: {
                        Label(L10n.t("隔离身份与网络代理", "Profiles & Network Proxy"), systemImage: "person.2.badge.key")
                    }

                    Button {
                        dismiss()
                        onOpenSubSheet(.vault)
                    } label: {
                        Label(L10n.t("面容 ID 密码管家 (\(syncEngine.passwords.count))", "Password Vault (\(syncEngine.passwords.count))"), systemImage: "key.viewfinder")
                    }

                    Button {
                        dismiss()
                        onOpenSubSheet(.sniffer)
                    } label: {
                        Label(
                            L10n.t("媒体嗅探器 (\(tabManager.activeTab?.sniffedMedia.count ?? 0))", "Media Sniffer (\(tabManager.activeTab?.sniffedMedia.count ?? 0))"),
                            systemImage: "film.stack"
                        )
                    }

                    Button {
                        dismiss()
                        onOpenSubSheet(.devtools)
                    } label: {
                        Label(L10n.t("移动端 DevTools 调试器", "Mobile DevTools"), systemImage: "wrench.and.screwdriver")
                    }
                }

                Section(L10n.t("防护与偏好", "Protection & Preferences")) {
                    Toggle(L10n.t("屏蔽追踪与广告", "Ad & Tracker Blocker"), isOn: $tabManager.adblockEnabled)
                    Toggle(L10n.t("拦截强跳 App Store / 外部App", "Block Rogue App Jumps"), isOn: $tabManager.blockRogueAppJumps)
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
            .navigationTitle("Prism v0.9.0")
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
        .buttonStyle(.plain)
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
                        Picker(L10n.t("网络代理", "Proxy Mode"), selection: $proxyMode) {
                            Text(L10n.t("系统代理", "System")).tag(ProxyMode.system)
                            Text(L10n.t("直连", "Direct")).tag(ProxyMode.direct)
                            Text(L10n.t("自定义 HTTP/SOCKS5", "Custom HTTP/SOCKS5")).tag(ProxyMode.custom)
                        }
                        if proxyMode == .custom {
                            TextField("socks5://127.0.0.1:7891", text: $newProxy)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.origin).font(.subheadline.weight(.semibold))
                            Spacer()
                            Button(unlockedIds.contains(item.id) ? L10n.t("复制密码", "Copy") : L10n.t("解锁查看", "Reveal")) {
                                authenticateAndReveal(item)
                            }
                            .font(.caption.weight(.bold))
                        }
                        Text(item.username).font(.caption).foregroundStyle(.secondary)
                        if unlockedIds.contains(item.id) {
                            Text(item.password).font(.caption.monospaced()).foregroundStyle(.blue)
                        }
                    }
                }
            }
            .searchable(text: $search)
            .navigationTitle(L10n.t("加密密码库", "Password Vault"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("完成", "Done")) { dismiss() }
                }
            }
        }
    }

    private var filtered: [PasswordEntry] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return syncEngine.passwords }
        return syncEngine.passwords.filter { $0.origin.lowercased().contains(q) || $0.username.lowercased().contains(q) }
    }

    private func authenticateAndReveal(_ item: PasswordEntry) {
        if unlockedIds.contains(item.id) {
            UIPasteboard.general.string = item.password
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
                }
            }
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
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    Text("Console (\(tab?.consoleLogs.count ?? 0))").tag(0)
                    Text("Network (\(tab?.networkLogs.count ?? 0))").tag(1)
                    Text("Storage").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()

                if selectedTab == 0 {
                    List(tab?.consoleLogs ?? []) { log in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(log.level.uppercased()).font(.caption2.bold()).foregroundStyle(log.level == "error" ? .red : .blue)
                            Text(log.message).font(.caption.monospaced())
                        }
                    }
                } else if selectedTab == 1 {
                    List(tab?.networkLogs ?? []) { req in
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
                                    let ok = await handoffService.push(kind: "clipboard", title: "Session Storage", url: tab?.urlString, text: storageText, syncEngine: syncEngine)
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
                    Button(L10n.t("完成", "Done")) { dismiss() }
                }
            }
            .onAppear { fetchStorage() }
        }
    }

    private func fetchStorage() {
        let js = """
        JSON.stringify({ cookie: document.cookie, localStorage: Object.assign({}, window.localStorage) }, null, 2);
        """
        tab?.webView?.evaluateJavaScript(js) { res, _ in
            if let s = res as? String {
                Task { @MainActor in storageText = s }
            }
        }
    }
}
