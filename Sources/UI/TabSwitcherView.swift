import SwiftUI

struct TabSwitcherView: View {
    @ObservedObject var tabManager: TabManager
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var handoffService: HandoffService
    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(tabManager.tabs) { tab in
                        TabGridCard(
                            tab: tab,
                            profile: syncEngine.profiles.first(where: { $0.id == tab.profileId }) ?? .defaultProfile,
                            isActive: tab.id == tabManager.activeTabId,
                            onSelect: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    tabManager.activateTab(id: tab.id)
                                }
                                dismiss()
                            },
                            onClose: {
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                                    tabManager.closeTab(tab.id)
                                }
                            }
                        )
                        .contextMenu {
                            if !tab.isNewTab && !tab.urlString.isEmpty {
                                Button {
                                    UIPasteboard.general.string = tab.urlString
                                    tabManager.syncClipboardChangeCount()
                                    tabManager.showToast(L10n.t("已复制标签页链接", "Tab URL copied"))
                                } label: {
                                    Label(L10n.t("复制链接", "Copy URL"), systemImage: "doc.on.doc")
                                }

                                Button {
                                    guard syncEngine.loggedIn else {
                                        tabManager.showToast(L10n.t("请先登录 Prism Account", "Sign in to Prism Account"))
                                        return
                                    }
                                    Task {
                                        let ok = await handoffService.push(
                                            kind: tab.hasVideo ? "video" : "tab",
                                            title: tab.title,
                                            url: tab.urlString,
                                            videoSeconds: tab.hasVideo ? tab.videoSeconds : 0,
                                            syncEngine: syncEngine
                                        )
                                        tabManager.showToast(ok ? L10n.t("已推送至电脑端", "Sent to desktop") : L10n.t("发送失败", "Failed"))
                                    }
                                } label: {
                                    Label(L10n.t("发送到桌面端", "Send to Desktop"), systemImage: "laptopcomputer")
                                }
                            }

                            if tabManager.tabs.count > 1 {
                                Button {
                                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                                        tabManager.closeOtherTabs(keeping: tab.id)
                                    }
                                } label: {
                                    Label(L10n.t("关闭其他标签页", "Close Other Tabs"), systemImage: "xmark.square")
                                }
                            }

                            Button(role: .destructive) {
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                                    tabManager.closeTab(tab.id)
                                }
                            } label: {
                                Label(L10n.t("关闭此标签页", "Close Tab"), systemImage: "trash")
                            }
                        }
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.92).combined(with: .opacity),
                            removal: .scale(scale: 0.82).combined(with: .opacity)
                        ))
                    }
                }
                .padding(16)
                .animation(.spring(response: 0.34, dampingFraction: 0.82), value: tabManager.tabs.map(\.id))
            }
            .navigationTitle(L10n.t("标签页 (\(tabManager.tabs.count))", "Tabs (\(tabManager.tabs.count))"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button(L10n.t("关闭", "Done")) { dismiss() }

                    if !tabManager.recentlyClosedTabs.isEmpty {
                        Button {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                                tabManager.restoreLastClosedTab()
                            }
                            dismiss()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.uturn.backward")
                                Text("\(tabManager.recentlyClosedTabs.count)")
                                    .font(.caption.weight(.bold).monospacedDigit())
                            }
                        }
                        .accessibilityLabel(L10n.t("恢复刚关闭的标签页", "Reopen Closed Tab"))
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if tabManager.tabs.count > 1 {
                        Button(role: .destructive) {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                                tabManager.closeAllTabs()
                            }
                            dismiss()
                        } label: {
                            Text(L10n.t("清空", "Clear"))
                                .font(.subheadline)
                                .foregroundStyle(.red)
                        }
                    }
                    Button {
                        tabManager.createTab(url: nil, activate: true)
                        dismiss()
                    } label: {
                        Image(systemName: "plus")
                            .fontWeight(.semibold)
                    }
                }
            }
        }
    }
}

private struct TabGridCard: View {
    @ObservedObject var tab: BrowserTab
    let profile: BrowserProfile
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(profile.swiftColor)
                        .frame(width: 8, height: 8)
                    Text(tab.title.isEmpty ? L10n.t("新标签页", "New Tab") : tab.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 16))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))

                ZStack(alignment: .bottomLeading) {
                    if let snap = tab.snapshot, !tab.isNewTab {
                        Image(uiImage: snap)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity, maxHeight: 132, alignment: .top)
                            .clipped()
                    } else {
                        ZStack {
                            LinearGradient(
                                colors: [
                                    profile.swiftColor.opacity(0.18),
                                    Color(.tertiarySystemBackground)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            VStack(spacing: 6) {
                                Image(systemName: tab.isNewTab ? "safari" : "globe")
                                    .font(.system(size: 24, weight: .light))
                                    .foregroundStyle(profile.swiftColor)
                                Text(tab.isNewTab ? "Prism" : (URL(string: tab.urlString)?.host ?? tab.urlString))
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: 132)
                    }

                    Text(tab.isNewTab ? "prism://newtab" : (URL(string: tab.urlString)?.host ?? tab.urlString))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(7)
                }
                .frame(height: 132)
                .clipped()
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isActive ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isActive ? 2.2 : 0.8)
            )
            .shadow(color: Color.black.opacity(isActive ? 0.16 : 0.06), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }
}
