import SwiftUI

struct HomeNewTabView: View {
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var tabManager: TabManager
    @State private var query: String = ""
    @State private var showAddShortcut: Bool = false
    @State private var newTitle: String = ""
    @State private var newUrl: String = ""
    @State private var showWeatherPicker: Bool = false
    @State private var weatherTemp: String = "--°C"
    @State private var weatherLabel: String = ""
    @State private var weatherSymbol: String = "cloud.sun.fill"
    @State private var weatherReloadToken = UUID()
    @Environment(\.colorScheme) private var colorScheme

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        let isDark = colorScheme == .dark
        let bg = isDark ? Color(hex: "#202124")! : Color.white
        let loc = syncEngine.homeConfig.weatherLocation ?? WeatherLocationConfig()

        ScrollView {
            VStack(spacing: 24) {
                // Top-Right Weather Pill
                HStack {
                    Spacer()
                    Button {
                        showWeatherPicker = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: weatherSymbol)
                                .font(.system(size: 13, weight: .semibold))
                                .symbolRenderingMode(.multicolor)
                            Text(weatherLabel.isEmpty ? "\(weatherTemp) · \(loc.name)" : "\(weatherTemp) · \(weatherLabel) · \(loc.name)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(isDark ? Color(hex: "#303134")! : Color(hex: "#F1F3F4")!, in: Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)

                Spacer(minLength: 24)

                // Chrome-minimalist Prism Wordmark
                HStack(spacing: 4) {
                    Text("Prism")
                        .font(.system(size: 48, weight: .semibold, design: .rounded))
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
                    .keyboardType(.default)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.search)
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
        .refreshable {
            await loadWeather(forceRefresh: true)
            await syncEngine.syncNow(forceFullPull: false)
        }
        .task(id: weatherReloadToken) {
            await loadWeather(forceRefresh: false)
        }
        .background(bg.ignoresSafeArea())
        .sheet(isPresented: $showWeatherPicker) {
            WeatherCityPickerSheet(
                currentLocation: syncEngine.homeConfig.weatherLocation ?? WeatherLocationConfig(),
                onSelect: { updated in
                    syncEngine.homeConfig.weatherLocation = updated
                    syncEngine.notifyScopeDirty("home_shortcuts")
                    weatherReloadToken = UUID()
                    Task { await loadWeather(forceRefresh: true) }
                }
            )
        }
        .sheet(isPresented: $showAddShortcut) {
            NavigationStack {
                Form {
                    TextField(L10n.t("网站名称", "Name"), text: $newTitle)
                        .keyboardType(.default)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    TextField(L10n.t("网址 (例如 https://example.com)", "URL (e.g. https://example.com)"), text: $newUrl)
                        .keyboardType(.default)
                        .submitLabel(.search)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
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

    private func loadWeather(forceRefresh: Bool) async {
        let loc = syncEngine.homeConfig.weatherLocation ?? WeatherLocationConfig()
        let cacheKey = "prism.weather.\(String(format: "%.2f_%.2f_%@", loc.latitude, loc.longitude, loc.unit))"
        if !forceRefresh,
           let savedAt = UserDefaults.standard.object(forKey: "\(cacheKey).ts") as? Double,
           Date().timeIntervalSince1970 - savedAt < 1800,
           let temp = UserDefaults.standard.string(forKey: "\(cacheKey).temp"),
           let lbl = UserDefaults.standard.string(forKey: "\(cacheKey).lbl"),
           let sym = UserDefaults.standard.string(forKey: "\(cacheKey).sym") {
            weatherTemp = temp
            weatherLabel = lbl
            weatherSymbol = sym
            return
        }

        let unitParam = loc.unit == "F" ? "fahrenheit" : "celsius"
        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(loc.latitude)&longitude=\(loc.longitude)&current=temperature_2m,weather_code&temperature_unit=\(unitParam)&timezone=auto") else {
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let cur = root["current"] as? [String: Any],
               let t = cur["temperature_2m"] as? Double {
                let code = cur["weather_code"] as? Int ?? 0
                let tempStr = "\(Int(t.rounded()))°\(loc.unit)"
                let (lbl, sym) = describeWeatherCode(code)
                weatherTemp = tempStr
                weatherLabel = lbl
                weatherSymbol = sym
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "\(cacheKey).ts")
                UserDefaults.standard.set(tempStr, forKey: "\(cacheKey).temp")
                UserDefaults.standard.set(lbl, forKey: "\(cacheKey).lbl")
                UserDefaults.standard.set(sym, forKey: "\(cacheKey).sym")
            }
        } catch {
            // Keep existing display quietly
        }
    }

    private func describeWeatherCode(_ code: Int) -> (String, String) {
        switch code {
        case 0: return (L10n.t("晴", "Clear"), "sun.max.fill")
        case 1, 2: return (L10n.t("少云", "Mostly Clear"), "cloud.sun.fill")
        case 3: return (L10n.t("阴", "Cloudy"), "cloud.fill")
        case 45, 48: return (L10n.t("雾", "Fog"), "cloud.fog.fill")
        case 51...67, 80...82: return (L10n.t("雨", "Rain"), "cloud.rain.fill")
        case 71...77, 85, 86: return (L10n.t("雪", "Snow"), "cloud.snow.fill")
        case 95...99: return (L10n.t("雷雨", "Storm"), "cloud.bolt.rain.fill")
        default: return (L10n.t("多云", "Cloudy"), "cloud.sun.fill")
        }
    }
}

private struct WeatherCityPickerSheet: View {
    let currentLocation: WeatherLocationConfig
    let onSelect: (WeatherLocationConfig) -> Void

    @State private var searchQuery = ""
    @State private var results: [WeatherLocationConfig] = []
    @State private var unit: String = "C"
    @State private var locating = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(L10n.t("温度单位", "Unit"), selection: $unit) {
                        Text("°C").tag("C")
                        Text("°F").tag("F")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: unit) { _, newUnit in
                        var updated = currentLocation
                        updated.unit = newUnit
                        onSelect(updated)
                    }

                    Button {
                        Task { await autoLocate() }
                    } label: {
                        HStack {
                            Image(systemName: "location.fill")
                            Text(L10n.t("📍 自动按网络定位", "📍 Auto-locate via network"))
                            if locating { Spacer(); ProgressView() }
                        }
                    }
                }

                Section(L10n.t("搜索城市", "Search City")) {
                    TextField(L10n.t("输入城市名（如 北京 / Shanghai / Tokyo）", "City name..."), text: $searchQuery)
                        .keyboardType(.default)
                        .submitLabel(.search)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .onChange(of: searchQuery) { _, val in
                            Task { await searchCities(val) }
                        }
                    ForEach(results, id: \.name) { item in
                        Button {
                            var picked = item
                            picked.unit = unit
                            onSelect(picked)
                            dismiss()
                        } label: {
                            HStack {
                                Text(item.name).foregroundStyle(.primary)
                                Spacer()
                                Text(String(format: "%.2f, %.2f", item.latitude, item.longitude))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.t("地区天气设置", "Weather Location"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("完成", "Done")) { dismiss() }
                }
            }
            .onAppear { unit = currentLocation.unit }
        }
        .presentationDetents([.medium, .large])
    }

    private func searchCities(_ q: String) async {
        let clean = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2,
              let encoded = clean.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(encoded)&count=6&language=\(L10n.isEnglish ? "en" : "zh")") else {
            return
        }
        if let (data, _) = try? await URLSession.shared.data(from: url),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = root["results"] as? [[String: Any]] {
            results = arr.compactMap { row in
                guard let name = row["name"] as? String,
                      let lat = row["latitude"] as? Double,
                      let lon = row["longitude"] as? Double else { return nil }
                let admin = (row["admin1"] as? String) ?? (row["country"] as? String) ?? ""
                let label = admin.isEmpty ? name : "\(name) · \(admin)"
                return WeatherLocationConfig(name: label, latitude: lat, longitude: lon, autoLocate: false, unit: unit)
            }
        }
    }

    private func autoLocate() async {
        locating = true
        defer { locating = false }
        if let url = URL(string: "https://ipapi.co/json/"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let city = obj["city"] as? String,
           let lat = obj["latitude"] as? Double,
           let lon = obj["longitude"] as? Double {
            let loc = WeatherLocationConfig(name: city, latitude: lat, longitude: lon, autoLocate: true, unit: unit)
            onSelect(loc)
            dismiss()
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
