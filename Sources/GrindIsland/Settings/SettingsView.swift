import SwiftUI
import AppKit

struct SettingsView: View {
    enum Page: String, CaseIterable, Identifiable {
        case general = "一般", features = "功能", lyrics = "歌詞", notices = "提示", agents = "Agent", shelf = "暫存", privacy = "隱私", permissions = "權限", about = "關於"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: return "rectangle.topthird.inset.filled"
            case .features: return "square.grid.2x2.fill"
            case .lyrics: return "music.note"
            case .notices: return "bell.badge"
            case .agents: return "pawprint.fill"
            case .shelf: return "tray.full"
            case .privacy: return "hand.raised.fill"
            case .permissions: return "lock.shield.fill"
            case .about: return "info.circle"
            }
        }
        var tint: Color {
            switch self {
            case .general: return .blue
            case .features: return .indigo
            case .lyrics: return .pink
            case .notices: return .orange
            case .agents: return .purple
            case .shelf: return .teal
            case .privacy: return .green
            case .permissions: return .cyan
            case .about: return .gray
            }
        }
    }

    @ObservedObject private var s = AppSettings.shared
    @ObservedObject private var shelf = ShelfStore.shared
    // `--settings-page=功能` opens on that page (screenshots).
    @State private var page: Page = CommandLine.arguments.first { $0.hasPrefix("--settings-page=") }
        .flatMap { Page(rawValue: String($0.dropFirst("--settings-page=".count))) } ?? .general
    @State private var cachedCount = LyricCache.shared.count()
    @State private var modelsKnown = VolumeMonitor.knownModels.count
    @State private var confirmReset = false
    @State private var autoUpdate = Updater.shared.automaticChecks
    @ObservedObject private var clip = ClipboardHistory.shared
    @Namespace private var sideNS
    private typealias K = IslandStyleKit

    /// The app icon at the size the header draws it (asking for that size picks the sharp 32/64 px artwork
    /// instead of scaling the 1024 px one down, which left jagged edges).
    static let appIcon: NSImage = {
        let i = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        i.size = NSSize(width: 34, height: 34)
        return i
    }()

    /// "1.0.0 (1)" from the bundle's Info.plist; the bare executable (swift run / tests) has none.
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let v = info["CFBundleShortVersionString"] as? String else { return "開發版" }
        return "\(v) (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(page.rawValue).font(.system(size: 22, weight: .bold)).foregroundColor(.white)
                    content
                }
                .padding(.horizontal, 24).padding(.top, 34).padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(page)
                .transition(.opacity.combined(with: .offset(y: 6)).combined(with: .blurReplace))
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: page)
        }
        .toggleStyle(IslandSwitch())
        .font(.system(size: 13))
        .foregroundColor(.white)
        .frame(width: 780, height: 600)
        .background(Color(white: 0.115))
        .environment(\.colorScheme, .dark)
    }

    /// Like the island's tab bar: white glyphs, the chosen page on a pill that slides to it.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(nsImage: Self.appIcon).resizable().interpolation(.high).antialiased(true).frame(width: 34, height: 34)
                Text("GrindIsland").font(.system(size: 17, weight: .bold)).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 12).padding(.top, 38).padding(.bottom, 14)
            ForEach(Page.allCases) { p in
                HStack(spacing: 10) {
                    Image(systemName: p.icon).font(.system(size: 12, weight: .semibold))
                        .foregroundColor(page == p ? p.tint : .white.opacity(0.55)).frame(width: 18)
                    Text(p.rawValue).font(.system(size: 13, weight: page == p ? .semibold : .regular))
                        .foregroundColor(page == p ? .white : .white.opacity(0.7))
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background {
                    if page == p {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.1))
                            .matchedGeometryEffect(id: "side", in: sideNS)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(K.spring) { page = p } }
            }
            Spacer()
            Text(Self.version).font(.system(size: 10)).foregroundColor(.white.opacity(0.3)).padding(12)
        }
        .padding(.horizontal, 8)
        .frame(width: 196)
        .background(Color(white: 0.085))
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .general: general
        case .features: features
        case .lyrics: lyrics
        case .notices: notices
        case .agents: agents
        case .shelf: shelfPage
        case .privacy: privacy
        case .permissions: PermissionsPage()
        case .about: about
        }
    }

    // MARK: Pages

    private var general: some View {
        VStack(alignment: .leading, spacing: 14) {
            card("外觀") {
                row("樣式") {
                    IslandSegmented(selection: $s.islandStyle, options: IslandStyle.allCases.map { ($0, $0.label) })
                }
                Toggle("播放音樂時，島的邊緣亮起封面的顏色", isOn: $s.edgeLight)
                row("顯示在") {
                    IslandMenu(selection: $s.targetScreenName,
                               options: [("", "自動（內建螢幕）"), (AppSettings.allScreens, "所有螢幕")]
                                   + NSScreen.screens.map { ($0.localizedName, $0.localizedName) })
                }
            }
            card("快捷鍵") {
                row("開關島") {
                    IslandMenu(selection: $s.islandHotkey, options: HotKeys.choices.map { ($0.id, $0.label) })
                }
                Text("島打開時：⌥1～⌥7 依順序切換分頁、Esc 收起。這幾個鍵只在島打開時使用，平常不會佔用。")
                    .font(.system(size: 11)).foregroundColor(K.secondary).fixedSize(horizontal: false, vertical: true)
            }
            card("行為") {
                Toggle("沒有播放時自動隱藏", isOn: $s.autoHideWhenIdle)
                Toggle("滑鼠停靠時自動打開", isOn: $s.hoverToOpen)
            }
            hint("展開後的分頁：歌詞、Agents、計時、行事曆、暫存、系統。把檔案拖到瀏海會直接打開暫存。")
        }
    }

    /// The expanded pages shown in the island, and optional tools.
    private var features: some View {
        VStack(alignment: .leading, spacing: 14) {
            card("展開後的分頁") {
                ForEach(Self.pages, id: \.id) { p in
                    Toggle(isOn: Binding(
                        get: { !s.hiddenTabs.contains(p.id) },
                        set: { on in
                            var h = s.hiddenTabs
                            if on { h.remove(p.id) } else if Self.pages.count - h.count > 1 { h.insert(p.id) }   // keep one
                            s.hiddenTabs = h
                        })) {
                        HStack(spacing: 8) {
                            Image(systemName: p.icon).frame(width: 18).foregroundColor(K.secondary)
                            Text(p.title)
                        }
                    }
                }
            }
            card("工具") {
                Toggle(isOn: $s.screenRecording) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("螢幕錄影")
                        Text("「控制」分頁與狀態列選單可以開始錄影（錄滑鼠所在的螢幕）；錄影中島上顯示時間與停止鍵。影片存到截圖位置。第一次需要允許「螢幕與系統錄音」。")
                            .font(.system(size: 11)).foregroundColor(K.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Toggle(isOn: $s.screenshotShelf) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("截圖暫存區")
                        Text("暫存分頁可切換到「截圖」：點一下複製圖片、可直接拖出去。截圖時島上會提示。只讀取截圖位置，不複製也不移動檔案。")
                            .font(.system(size: 11)).foregroundColor(K.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if s.screenshotShelf {
                    row("顯示最近") {
                        IslandSegmented(selection: $s.screenshotKeepDays, options: [(1, "1 天"), (3, "3 天"), (7, "7 天")])
                    }
                    row("自動清除") {
                        IslandSegmented(selection: $s.screenshotTrashDays, options: [(0, "不清除"), (3, "3 天"), (7, "7 天"), (30, "30 天")])
                    }
                    Text("自動清除：超過天數都沒打開過的截圖移到垃圾桶（可從垃圾桶復原）。只處理截圖位置裡的截圖，其他檔案不會動。")
                        .font(.system(size: 11)).foregroundColor(K.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Toggle(isOn: $s.clipboardHistory) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("剪貼簿歷史")
                        Text("暫存分頁可切換到「剪貼簿」：最近複製的文字（最多 50 段、每段 5,000 字內），點一下再複製、可釘選。只存在記憶體；密碼管理器標記為機密的內容不會記錄。")
                            .font(.system(size: 11)).foregroundColor(K.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if s.clipboardHistory {
                    row("保留") {
                        IslandSegmented(selection: $s.clipboardKeepHours, options: [(1, "1 小時"), (24, "1 天"), (168, "7 天")])
                    }
                    Text("超過時間的自動清掉，釘選的保留。")
                        .font(.system(size: 11)).foregroundColor(K.secondary)
                }
                Toggle(isOn: $s.usageStats) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI 用量統計")
                        Text("Agents 分頁可切換到「用量」：今天與近 14 天的 Claude Code token、最常用的專案與模型。只讀本機紀錄裡的數字，不讀對話內容。")
                            .font(.system(size: 11)).foregroundColor(K.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            hint("關掉的分頁不會出現在島上；Agent 需要你批准時，點通知仍會打開 Agents 頁。至少要留一個分頁。")
        }
    }

    static let pages: [(id: Int, title: String, icon: String)] = [
        (0, "歌詞", "music.note"), (1, "Agents", "pawprint.fill"), (2, "計時", "timer"), (6, "控制", "slider.horizontal.3"),
        (3, "行事曆", "calendar"), (4, "暫存", "tray.full"), (5, "系統", "gauge.with.dots.needle.50percent")]

    private var lyrics: some View {
        VStack(alignment: .leading, spacing: 14) {
            card("顯示") {
                slider("歌詞大小", value: $s.lyricFontScale, range: 0.6...1.5, step: 0.05,
                       text: "\(Int((s.lyricFontScale * 100).rounded()))%")
                Toggle("顯示翻譯", isOn: $s.showTranslation)
                if s.showTranslation {
                    row("翻譯排列") { IslandSegmented(selection: $s.translationSideBySide, options: [(false, "上下"), (true, "左右")]) }
                    Toggle("翻譯轉為繁體中文", isOn: $s.translationTraditional)
                }
            }
            card("同步") {
                HStack {
                    slider("時間微調", value: $s.lyricLead, range: -1...1, step: 0.05, text: String(format: "%+.2f 秒", s.lyricLead))
                    Button("重設") { s.resetLyricLead() }.buttonStyle(IslandButton())
                }
            }
            card("快取") {
                HStack {
                    Text("已快取歌詞")
                    Spacer()
                    Text("\(cachedCount) 首").monospacedDigit().foregroundColor(K.secondary)
                    Button("清除") { LyricCache.shared.clear(); cachedCount = LyricCache.shared.count() }.buttonStyle(IslandButton(danger: true))
                }
            }
            hint("字體大小與翻譯排列只影響收合狀態。歌詞比聲音慢就把時間微調往正值調。常聽的歌詞會保留；超過 14 天沒播放才清除。沒有翻譯的外語歌會用 macOS 內建翻譯，「譯」按鈕右上角會出現橘點。")
        }
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: 14) {
            card("島上提示") {
                Toggle("充電、低電量、低耗電模式、過熱", isOn: $s.batteryNotices)
                Toggle("音量、螢幕與鍵盤亮度、耳機連線", isOn: $s.volumeNotices)
                Toggle("網路斷線與恢復、外接螢幕", isOn: $s.systemNotices)
                Toggle("切換輸入法", isOn: $s.inputSourceNotices)
                Toggle("會議即將開始（行事曆）", isOn: $s.meetingAlerts)
            }
            card("按鍵") {
                Toggle(isOn: $s.takeOverMediaKeys) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("由島處理音量與亮度鍵")
                        Text("按音量、螢幕亮度、鍵盤背光鍵時只顯示島上的提示，不出現系統原本的提示。需要在「系統設定 › 隱私權與安全性 › 輔助使用」允許 GrindIsland。按 ⌥⇧ 可以細調。")
                            .font(.system(size: 11)).foregroundColor(K.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if s.takeOverMediaKeys && !MediaKeys.shared.trusted {
                    HStack {
                        Text("尚未允許輔助使用，按鍵仍由系統處理").font(.system(size: 11)).foregroundColor(.orange)
                        Spacer()
                        Button("打開設定") {
                            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(u) }
                        }
                        .buttonStyle(IslandButton())
                    }
                }
            }
            hint("提示只在島上短暫出現，不發出聲音。Agent 需要你批准時一定會顯示。其他 app 的通知（訊息、郵件）macOS 不開放讀取，所以不會顯示在島上。")
        }
    }

    private var agents: some View {
        VStack(alignment: .leading, spacing: 14) {
            card("Claude Code 批准") {
                HStack {
                    Image(systemName: Self.hookInstalled ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundColor(Self.hookInstalled ? K.on : K.secondary)
                    Text(Self.hookInstalled ? "已啟用：權限請求會出現在島上，可直接按 ✓ / ✕" : "未啟用：權限請求只會出現在終端機")
                }
                Toggle(isOn: $s.quickApprove) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("收合時 ✓ 直接允許")
                        Text("關閉時，收合列顯示的是 Agent 自己寫的說明，按 ✓ 會先展開讓你看真正的指令或改動。打開後直接放行（你沒看到內容）。指令太長、島上看不完整的仍會先展開。")
                            .font(.system(size: 11)).foregroundColor(K.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            hint("在終端機回覆後，島上的詢問會自動消失。點「等你回覆」的通知會跳到該 Agent 的終端機分頁（cmux）。")
        }
    }

    private var shelfPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            card("暫存檔案") {
                HStack {
                    Text("目前暫存")
                    Spacer()
                    Text("\(shelf.items.count) 個").monospacedDigit().foregroundColor(K.secondary)
                    Button("全部移除") { shelf.clear() }.buttonStyle(IslandButton(danger: true))
                        .disabled(shelf.items.isEmpty).opacity(shelf.items.isEmpty ? 0.4 : 1)
                }
                HStack {
                    Text("Taildrop")
                    Spacer()
                    Text(Taildrop.cli != nil ? "已偵測到 Tailscale" : "未安裝 Tailscale").foregroundColor(K.secondary)
                }
            }
            hint("暫存只記住檔案位置，不複製也不移動原檔；24 小時後自動移除。")
        }
    }

    /// What GrindIsland keeps on this Mac, each with a way to clear it.
    private var privacy: some View {
        VStack(alignment: .leading, spacing: 14) {
            card("存在這台 Mac 的資料") {
                dataRow("歌詞快取", "播放過的歌詞，14 天沒播放自動刪除", "\(cachedCount) 首", empty: cachedCount == 0) {
                    LyricCache.shared.clear(); cachedCount = LyricCache.shared.count()
                }
                dataRow("暫存的檔案", "只記檔案位置，清除不會刪除原檔", "\(shelf.items.count) 個", empty: shelf.items.isEmpty) {
                    shelf.clear()
                }
                dataRow("耳機型號記錄", "讓耳機重新連線時立刻顯示正確型號", "\(modelsKnown) 副", empty: modelsKnown == 0) {
                    VolumeMonitor.forgetModels(); modelsKnown = 0
                }
                dataRow("剪貼簿歷史", "只在記憶體，超過保留時間自動清掉", "\(clip.items.count) 筆・約 \(ByteCountFormatter.string(fromByteCount: Int64(clip.bytes), countStyle: .memory))", empty: clip.items.isEmpty) {
                    clip.clear()
                }
            }
            card("只讀取、不另外儲存") {
                Text("截圖暫存區、AI 用量統計、行事曆與提醒事項、Agent 狀態、系統資訊：都是需要時才讀，不複製也不另外保存（截圖的「自動清除」打開時，舊截圖會移到垃圾桶）。會連網的只有兩處：歌詞查詢把歌名與歌手送到網易雲音樂或 LRCLIB，以及每天到 GitHub 檢查新版本；其餘資料都不會離開這台 Mac。")
                    .font(.system(size: 12)).foregroundColor(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
            }
            card("權限與設定") {
                HStack {
                    Text("行事曆、提醒事項、輔助使用、控制其他 App")
                    Spacer()
                    Button("打開系統設定") {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") { NSWorkspace.shared.open(u) }
                    }
                    .buttonStyle(IslandButton())
                }
                HStack {
                    Text("所有設定還原為預設值")
                    Spacer()
                    Button("重設…") { confirmReset = true }.buttonStyle(IslandButton(danger: true))
                }
            }
        }
        .alert("重設所有設定？", isPresented: $confirmReset) {
            Button("取消", role: .cancel) {}
            Button("重設並重新啟動", role: .destructive) { Self.resetAllSettings() }
        } message: {
            Text("所有選項會回到預設值，GrindIsland 會重新啟動。歌詞快取與暫存不受影響。")
        }
    }

    private func dataRow(_ title: String, _ note: String, _ amount: String, empty: Bool, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(note).font(.system(size: 11)).foregroundColor(K.secondary)
            }
            Spacer()
            Text(amount).monospacedDigit().foregroundColor(K.secondary)
            Button("清除", action: clear).buttonStyle(IslandButton(danger: true)).disabled(empty).opacity(empty ? 0.4 : 1)
        }
    }

    /// Fixed links only (never built from input).
    static func openLink(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }

    /// Clears this app's preferences (except the shelf list and earbud models, cleared above if wanted) and relaunches.
    static func resetAllSettings() {
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let keep: Set<String> = ["shelfItems", "earbudModels"]
        let old = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        UserDefaults.standard.setPersistentDomain(old.filter { keep.contains($0.key) }, forName: domain)
        // Quit first, then open again from a detached shell: a new copy started while this one runs would find the
        // approval socket and the hot keys still taken. The path goes in as an argument ($0), not into the script.
        if Bundle.main.bundleIdentifier != nil {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
            try? p.run()
        }
        NSApp.terminate(nil)
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 14) {
            card("GrindIsland") {
                HStack { Text("版本"); Spacer(); Text(Self.version).monospacedDigit().foregroundColor(K.secondary) }
                HStack { Text("授權"); Spacer(); Text("MIT，開放原始碼").foregroundColor(K.secondary) }
            }
            if Updater.shared.available {
                card("更新") {
                    Toggle("每天自動檢查新版本", isOn: Binding(get: { autoUpdate }, set: { autoUpdate = $0; Updater.shared.automaticChecks = $0 }))
                    HStack {
                        Text(Updater.shared.lastCheck.map { "上次檢查：\($0.formatted(.dateTime.locale(Locale(identifier: "zh_Hant_TW")).month().day().hour().minute()))" } ?? "還沒檢查過")
                            .font(.system(size: 11)).foregroundColor(K.secondary)
                        Spacer()
                        Button("檢查更新…") { Updater.shared.checkNow() }.buttonStyle(IslandButton())
                    }
                    Text("新版本從 GitHub 下載，安裝前會先驗證簽章，確認是原作者發布的。")
                        .font(.system(size: 11)).foregroundColor(K.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            card("連結") {
                HStack(spacing: 8) {
                    Button("GitHub 專案頁") { Self.openLink("https://github.com/liaw-boy/GrindIsland") }.buttonStyle(IslandButton())
                    Button("回報問題") { Self.openLink("https://github.com/liaw-boy/GrindIsland/issues") }.buttonStyle(IslandButton())
                    Button("版本紀錄") { Self.openLink("https://github.com/liaw-boy/GrindIsland/releases") }.buttonStyle(IslandButton())
                }
            }
            hint("會連網的只有：查歌詞（把歌名與歌手送到網易雲音樂或 LRCLIB）與檢查新版本（GitHub）。其他資料都只在這台 Mac，詳見「隱私」。")
        }
    }

    // MARK: Building blocks

    /// Like the island's system-page cards: translucent white on black, continuous corners.
    private func card<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.45)).textCase(.uppercase)
            VStack(alignment: .leading, spacing: 12) { c() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(K.card))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(K.cardLine, lineWidth: 0.5))
        }
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 64, alignment: .leading)
            c()
        }
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, text: String) -> some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 64, alignment: .leading)
            IslandSlider(value: value, range: range, step: step)
            Text(text).monospacedDigit().foregroundColor(K.secondary).frame(width: 64, alignment: .trailing)
        }
    }

    private func hint(_ t: String) -> some View {
        Text(t).font(.system(size: 11)).foregroundColor(.white.opacity(0.4)).fixedSize(horizontal: false, vertical: true)
    }

    /// Whether ~/.claude/settings.json runs our permission hook (read-only check).
    static var hookInstalled: Bool {
        let path = NSHomeDirectory() + "/.claude/settings.json"
        guard let data = FileManager.default.contents(atPath: path), data.count < 2_000_000,
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("GrindIsland") && text.contains("--permission-hook")
    }
}

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "GrindIsland 設定"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(white: 0.115, alpha: 1)
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
