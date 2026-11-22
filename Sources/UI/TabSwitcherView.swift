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
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    tabManager.closeTab(tab.id)
                                }
                            }
                        )
                    }
                }
                .padding(16)
            }
            .navigationTitle(L10n.t("标签页 (\(tabManager.tabs.count))", "Tabs (\(tabManager.tabs.count))"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("关闭", "Done")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(profile.swiftColor)
                        .frame(width: 8, height: 8)
                    Text(profile.name)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 16))
                    }
                }

                Text(tab.title.isEmpty ? L10n.t("新标签页", "New Tab") : tab.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 16)

                Text(tab.isNewTab ? "prism://newtab" : (URL(string: tab.urlString)?.host ?? tab.urlString))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(height: 124, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}
