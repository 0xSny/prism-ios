import SwiftUI

struct HomeNewTabView: View {
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var tabManager: TabManager
    @State private var query: String = ""
    @State private var showAddShortcut: Bool = false
    @State private var newTitle: String = ""
    @State private var newUrl: String = ""
    @Environment(\.colorScheme) private var colorScheme

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        let isDark = colorScheme == .dark
        let bg = isDark ? Color(hex: "#202124")! : Color.white

        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 48)

                // Chrome-minimalist Prism Wordmark
                HStack(spacing: 4) {
                    Text("Prism")
                        .font(.system(size: 46, weight: .semibold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(hex: "#4285F4")!, Color(hex: "#6366F1")!, Color(hex: "#06B6D4")!],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }

                // Centered 48pt Rounded Search Pill
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 16, weight: .medium))
                    TextField(
                        L10n.t("在 Google 中搜索，或输入网址", "Search or type a URL"),
                        text: $query
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit {
                        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !q.isEmpty else { return }
                        tabManager.navigateActive(q)
                        query = ""
                    }
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(isDark ? Color(hex: "#303134")! : Color.white)
                        .shadow(color: Color.black.opacity(isDark ? 0.25 : 0.12), radius: 8, x: 0, y: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(isDark ? Color(hex: "#5F6368")! : Color.black.opacity(0.06), lineWidth: 1)
                )
                .padding(.horizontal, 20)

                // Synced Home Shortcuts Grid (max 10)
                if syncEngine.homeConfig.showShortcuts {
                    let items = Array(syncEngine.homeConfig.shortcuts.sorted { $0.order < $1.order }.prefix(10))
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(items) { item in
                            Button {
                                tabManager.navigateActive(item.url)
                            } label: {
                                VStack(spacing: 8) {
                                    ZStack {
                                        Circle()
                                            .fill(isDark ? Color(hex: "#303134")! : Color(hex: "#F1F3F4")!)
                                            .frame(width: 48, height: 48)
                                        ShortcutFavicon(urlString: item.url, title: item.title, colorHex: item.color)
                                    }
                                    Text(item.title)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    syncEngine.homeConfig.shortcuts.removeAll { $0.id == item.id }
                                    syncEngine.notifyScopeDirty("home_shortcuts")
                                } label: {
                                    Label(L10n.t("移除快捷方式", "Remove Shortcut"), systemImage: "trash")
                                }
                            }
                        }

                        if items.count < 10 {
                            Button {
                                newTitle = ""
                                newUrl = ""
                                showAddShortcut = true
                            } label: {
                                VStack(spacing: 8) {
                                    ZStack {
                                        Circle()
                                            .fill(isDark ? Color(hex: "#303134")! : Color(hex: "#F1F3F4")!)
                                            .frame(width: 48, height: 48)
                                        Image(systemName: "plus")
                                            .font(.system(size: 18, weight: .medium))
                                            .foregroundStyle(.primary)
                                    }
                                    Text(L10n.t("添加", "Add"))
                                        .font(.system(size: 12))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }

                Spacer(minLength: 40)
            }
        }
        .background(bg.ignoresSafeArea())
        .sheet(isPresented: $showAddShortcut) {
            NavigationStack {
                Form {
                    TextField(L10n.t("网站名称", "Name"), text: $newTitle)
                    TextField(L10n.t("网址 (例如 https://example.com)", "URL (e.g. https://example.com)"), text: $newUrl)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .navigationTitle(L10n.t("添加快捷方式", "Add Shortcut"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.t("取消", "Cancel")) { showAddShortcut = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.t("保存", "Save")) {
                            let cleanUrl = newUrl.hasPrefix("http") ? newUrl : "https://\(newUrl)"
                            let sc = HomeShortcut(
                                id: UUID().uuidString,
                                title: newTitle.isEmpty ? (URL(string: cleanUrl)?.host ?? cleanUrl) : newTitle,
                                url: cleanUrl,
                                color: "#4285F4",
                                order: syncEngine.homeConfig.shortcuts.count
                            )
                            syncEngine.homeConfig.shortcuts.append(sc)
                            syncEngine.notifyScopeDirty("home_shortcuts")
                            showAddShortcut = false
                        }
                        .disabled(newUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }
}

struct ShortcutFavicon: View {
    let urlString: String
    let title: String
    let colorHex: String?

    var body: some View {
        let host = URL(string: urlString)?.host ?? ""
        if !host.isEmpty, let iconUrl = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64") {
            AsyncImage(url: iconUrl) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                default:
                    fallbackBadge
                }
            }
        } else {
            fallbackBadge
        }
    }

    private var fallbackBadge: some View {
        Text(String(title.prefix(1)).uppercased())
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(Color(hex: colorHex ?? "#4285F4") ?? .blue)
    }
}
