import SwiftUI

struct TabSwitcherView: View {
    @ObservedObject var tabManager: TabManager
    @ObservedObject var syncEngine: SyncEngine
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
                                    tabManager.activeTabId = tab.id
                                }
                                dismiss()
                            },
                            onClose: {
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                                    tabManager.closeTab(tab.id)
                                }
                            }
                        )
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
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("关闭", "Done")) { dismiss() }
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
