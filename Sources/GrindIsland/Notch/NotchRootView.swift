import SwiftUI
import AppKit
import Combine

public struct NotchRootView: View {
    @EnvironmentObject private var geom: NotchGeometry   // this display's island
    @ObservedObject private var musicTracker = MusicTracker.shared
    @ObservedObject private var lyricService = LyricService.shared
    @ObservedObject private var monitor = AgentMonitor.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var presence = IslandPresence.shared
    @ObservedObject private var notices = NoticeCenter.shared
    @ObservedObject private var focus = FocusTimer.shared
    @ObservedObject private var recorder = ScreenRecorder.shared
    @ObservedObject private var calendar = CalendarService.shared

    @State private var selectedTab: Int = NotchGeometry.launchTab // 0: Dynamic Lyrics, 1: Pixel Office, 2: Agent List
    @State private var hoverOpenTimer: Timer?
    @State private var songBanner = false
    @State private var bounce = false
    @Namespace private var tabNS
    /// Direction of the last tab change: the new page slides in from the side of the tab you picked.
    @State private var tabForward = true
    /// The pages in the order they are shown (the first `leftTabs` left of the notch). ⌥1… follow this order.
    static let tabs: [(id: Int, title: String, icon: String)] = [(0, "歌詞", "music.note"), (1, "Agents", "pawprint.fill"), (2, "計時", "timer"), (6, "控制", "slider.horizontal.3"), (3, "行事曆", "calendar"), (4, "暫存", "tray.full"), (5, "系統", "gauge.with.dots.needle.50percent")]

    public init() {}

    public var body: some View {
        let compactW: CGFloat = noticeKind != 0 ? max(340, geom.compactWidth) : geom.compactWidth
        // Nothing playing and no agent needing attention ("idle"): no island content at all. When the pointer comes
        // near the notch only a rim swells out around it (no music view); a click then opens the island.
        let idle = !presence.isActive && !geom.isExpanded
        let peeking = idle && geom.pointerNear
        // On a notched display the idle silhouette sits behind the notch (invisible) and simply grows out of it, so
        // it never fades. Without a notch there is nothing to hide behind, so it fades in and out instead.
        let visible = !idle || peeking || geom.integrated
        // Pointer resting on the collapsed island makes it swell slightly, like it is being "touched".
        let grow = geom.pointerNear && !geom.isExpanded && !idle
        let currentW = geom.isExpanded ? geom.expandedWidth
            : (idle ? geom.idleWidth + (peeking ? NotchGeometry.idleRimWidth : 0) : compactW + (grow ? geom.swellSize.width : 0))
        let currentH = geom.isExpanded ? geom.expandedHeight
            : (idle ? geom.idleHeight + (peeking ? NotchGeometry.idleRimHeight : 0) : geom.compactHeight + (grow ? geom.swellSize.height : 0))
        // Notch: concave shoulders and a modest radius. Capsule (no notch): fully round when collapsed, a rounded card
        // when expanded, so it morphs like the iPhone's Dynamic Island.
        // The fused capsule wraps the notch with a flat top flush with the screen edge; expanded, its lower corners match the notch's.
        let radius: CGFloat = geom.notchStyle ? (geom.isExpanded ? 18 : 11.5)
            : (geom.attached ? (geom.isExpanded ? NotchGeometry.notchCorner : min(28, currentH / 2)) : min(44, currentH / 2))

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                IslandOutline(notched: geom.notchStyle, flatTop: false, cornerRadius: radius)
                .fill(Color.black)
                // The hardware notch casts no shadow; the floating capsule gets a soft one, the "needs approval" alert glows.
                .shadow(
                    color: monitor.visibleAlert != nil ? Color.orange.opacity(0.35)
                        : (geom.integrated ? .clear : Color.black.opacity(0.35)),
                    radius: geom.integrated ? 6 : 8,
                    x: 0,
                    y: geom.integrated ? 1 : 2
                )

                // Edge light: a thin rim in the cover's colour that breathes while music plays (setting 外觀).
                // Not over notices, so it never competes with them.
                if settings.edgeLight && musicTracker.isPlaying && !idle && noticeKind == 0 && monitor.visibleAlert == nil {
                    IslandOutline(notched: geom.notchStyle, flatTop: false, cornerRadius: radius)
                        .stroke(musicTracker.artworkTint, lineWidth: 1.4)
                        .shadow(color: musicTracker.artworkTint.opacity(0.7), radius: 7)
                        .opacity(0.6)   // steady: a breathing rim redrew the whole island every frame
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                // Content Layer
                ZStack(alignment: .top) {
                    flyingArt(compactW: compactW, grow: grow)   // underneath, so the page's badges stay on top
                    if geom.isExpanded {
                        expandedNotchBody
                            .frame(width: geom.expandedWidth, height: geom.expandedHeight, alignment: .top)
                            .transition(.islandContent(scale: 0.86, blur: 14)
                                .animation(.spring(response: 0.46, dampingFraction: 0.8).delay(0.04)))
                    } else if !idle {
                        // Wings and lyric row follow the swell, so the cover / bars move outward with the shape.
                        Group {
                            if geom.integrated {
                                compactNotchBar(width: compactW, swell: grow)
                            } else {
                                capsuleBar(width: compactW, swell: grow)
                            }
                        }
                            .frame(width: compactW, height: geom.compactHeight)
                            .transition(.asymmetric(
                                insertion: .islandContent(scale: 0.8, blur: 8).animation(.easeOut(duration: 0.32).delay(0.08)),
                                removal: .islandContent(scale: 0.8, blur: 6).animation(.easeIn(duration: 0.22))))
                    }
                }
                .frame(width: currentW, height: currentH, alignment: .top)
                // Music ↔ agent notice: the wing items swap with a scale-blur crossfade on one spring.
                .animation(.spring(response: 0.42, dampingFraction: 0.82), value: noticeKind)
                .clipShape(IslandOutline(notched: geom.notchStyle, flatTop: false, cornerRadius: radius))
            }
            .frame(width: currentW, height: currentH)
            // The tap area is the island as drawn (it swells when the pointer comes near), not the fixed-size
            // content inside it: otherwise the swollen rim was visible but did nothing when clicked.
            .contentShape(Rectangle())
            .onTapGesture { expandFromClick() }
            .padding(.top, geom.insetTop(idle: idle))
            // Idle and the pointer is away: the silhouette fades out (it only exists as the rim around the notch).
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: visible)
            .onHover { isHovered in
            if isHovered {
                // Not while a session waits: expanding would hide the ✕/✓ (or jump) button the pointer is heading for.
                if !geom.isExpanded && settings.hoverToOpen && monitor.noticeSession?.state != .waitingApproval {
                    hoverOpenTimer?.invalidate()
                    hoverOpenTimer = Timer.commonModeTimer(interval: 0.3, repeats: false) { _ in
                        DispatchQueue.main.async {
                            guard monitor.noticeSession?.state != .waitingApproval else { return }   // a request arrived during the 0.3s wait
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                if monitor.noticeSession != nil { selectedTab = 1 }   // same as a click: a notice opens on the Agents page
                                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                                geom.isExpanded = true
                            }
                        }
                    }
                }
            } else {
                hoverOpenTimer?.invalidate()
                hoverOpenTimer = nil
            }
        }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // ONE animation drives every change of the island (open, close, swell, peek, going idle, an agent alert
        // appearing, the lyric size changing the height...): whatever changes the state or the target size is animated,
        // so no situation can make the island jump. It lives on the ROOT, outside the centering frame above, so the
        // size and the centered position animate together (inside, one edge would jump first).
        .overlay(alignment: .top) {
            // `--draw-notch`: screenshots do not capture the hardware notch, so draw a stand-in to judge how the island joins it.
            if CommandLine.arguments.contains("--draw-notch") && geom.hasNotch {
                UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8)
                    .fill(Color.black)
                    .frame(width: geom.realNotchSize.width, height: geom.realNotchSize.height)
                    .offset(x: geom.realNotchDX)
                    .allowsHitTesting(false)
            }
        }
        .animation(islandSpring(expanded: geom.isExpanded, idle: idle, nearNotch: geom.pointerNear),
                   value: IslandState(expanded: geom.isExpanded, idle: idle, peeking: peeking, grow: grow,
                                      width: currentW, height: currentH))
        .onChange(of: musicTracker.currentTrack.title) { oldTitle, _ in
            guard !geom.isExpanded, oldTitle != TrackInfo().title else { return }
            songBanner = true
            pop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { songBanner = false }
        }
        // A notice arriving (or handing over to another feature) gives the collapsed island the same little pop.
        .onChange(of: noticeKind) { _, kind in
            geom.wideBar = kind != 0
            if kind != 0 && !geom.isExpanded { pop() }
        }
        // An agent starting to need you cuts short a passive Mac notice, but not the volume/brightness being changed.
        .onChange(of: monitor.noticeSession?.id) { _, id in
            if id != nil, let n = notices.current, n.meter == nil { NoticeCenter.shared.dismiss() }
        }
        // A page turned off in settings while open: go to the first page still shown.
        .onChange(of: settings.hiddenTabs) { _, hidden in
            if hidden.contains(selectedTab), let first = Self.tabs.first(where: { !hidden.contains($0.id) }) { switchTab(first.id) }
        }
        // Review mode ends when the request is answered (here or in the terminal), the island closes, or a tab is picked.
        .onChange(of: monitor.pendingApprovals.map(\.id)) { _, ids in
            if let r = geom.reviewingApproval, !ids.contains(r) { withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { geom.reviewingApproval = nil } }
        }
        .onChange(of: geom.isExpanded) { _, open in if !open { geom.reviewingApproval = nil } }
        .onChange(of: selectedTab) { _, _ in geom.reviewingApproval = nil }
        .onChange(of: geom.requestedTab) { _, tab in
            guard let tab = tab else { return }
            geom.requestedTab = nil
            if tab != selectedTab { switchTab(tab) }
        }
    }

    // MARK: - Compact Notch Mode
    /// What the collapsed island shows, most important first:
    /// 1. A Mac notice (volume, brightness, charging, AirPods…): it lasts seconds, and what you just adjusted must
    ///    answer at once, so it goes over everything.
    /// 2. An agent notice: it stays until handled, so it simply comes back when the Mac notice ends. An agent that
    ///    starts needing you cuts short a passive Mac notice (not the volume or brightness you are changing).
    /// 3. A meeting about to start, 4. music, 5. the focus timer.
    private var sysNotice: IslandNotice? { notices.current }
    /// The agent notice, when no Mac notice is over it.
    private var agentNotice: LocalAgentSession? { sysNotice == nil ? monitor.noticeSession : nil }
    /// The focus timer owns the collapsed bar when it runs and no music plays (with music it sits in the right wing).
    private var timerBar: Bool { noticeKind == 3 }
    /// A meeting about to start: over the music only in its last 2 minutes, otherwise when nothing plays.
    private var meeting: CalendarService.Item? {
        guard let m = calendar.upcoming else { return nil }
        return !musicTracker.isPlaying || m.start.timeIntervalSince(calendar.now) <= 120 ? m : nil
    }
    /// What the collapsed island is showing: 0 music, 1 an agent notice, 2 a Mac notice, 3 the focus timer,
    /// 4 a meeting about to start, 5 a screen recording. Ranked as described at `sysNotice` (a recording right after
    /// the agent: its stop button must stay at hand).
    private var noticeKind: Int {
        Self.rank(macNotice: notices.current != nil, agent: monitor.noticeSession != nil, meeting: meeting != nil,
                  timerAlone: focus.clock.isActive && !musicTracker.isPlaying, recording: recorder.recording)
    }

    static func rank(macNotice: Bool, agent: Bool, meeting: Bool, timerAlone: Bool, recording: Bool = false) -> Int {
        macNotice ? 2 : agent ? 1 : recording ? 5 : meeting ? 4 : timerAlone ? 3 : 0
    }

    /// Recording: a red dot that breathes; the right wing stops it.
    private var recordingIcon: some View {
        Image(systemName: "record.circle.fill").font(.system(size: 22, weight: .semibold)).foregroundColor(.red)
            .symbolEffect(.pulse, options: .repeating)
            .frame(width: 36, alignment: .center)
    }

    private var recordingStop: some View {
        approvalButton("stop.fill", Color.red, "停止錄影") { recorder.stop() }
    }

    /// Identity of the compact lyric row: it changes (and so slides) with the lyric line, but not while a notification
    /// is showing, or the notice text would scroll every time the lyric moves on.
    private var lyricRowID: Int {
        songBanner ? -1 : sysNotice != nil ? -5 : agentNotice != nil ? -3 : noticeKind == 5 ? -8 : noticeKind == 4 ? -7 : timerBar ? -6 : lyricService.isIntro ? -2 : lyricService.isInterlude ? -4 : lyricService.compactLineIndex
    }

    private func compactNotchBar(width: CGFloat, swell: Bool) -> some View {
        // The island shape grows by +24 wide / +18 tall (measured from the reference app). Instead of re-laying
        // the content out (which does not animate smoothly), the wings and lyric row are driven by the same
        // value: near-critically-damped springs, so everything settles in ~0.25s without bouncing, and the
        // lyric row drops down with the bulge like a hanging drop.
        let wingSpring = Animation.spring(response: 0.3, dampingFraction: 0.78)
        let rowSpring = Animation.spring(response: 0.3, dampingFraction: 0.82)
        let wing = (width - geom.notchWidth) / 2
        // While swollen each wing is swell.width/2 wider (its centre moves out by a quarter) and the capsule is
        // swell.height taller (its centre moves down by half): move the content by exactly that so it stays centred.
        let swellX = swell ? geom.swellSize.width / 4 : 0
        let swellY = swell ? geom.swellSize.height / 2 : 0
        let tint: Color = musicTracker.artworkTint

        return VStack(spacing: 0) {
            // Row 1: wings on both sides of the camera cutout
            HStack(spacing: 0) {
                // A ZStack, not an HStack with spacers: while one item swaps for another both exist for a moment,
                // and side by side they pushed each other off centre. Overlapping, each stays at the wing's centre.
                ZStack {
                    if let n = agentNotice {
                        CatAvatar(state: n.state, look: noticeLook(n))
                            .frame(width: 30, height: 30)
                            .transition(.wingSwap)
                    } else if let sn = sysNotice {
                        noticeIcon(sn).transition(.wingSwap)
                    } else if noticeKind == 5 {
                        recordingIcon.transition(.wingSwap)
                    } else if noticeKind == 4, let m = meeting {
                        meetingIcon(m).transition(.wingSwap)
                    } else if timerBar {
                        timerIcon.transition(.wingSwap)
                    } else if let nsImg = musicTracker.currentArtwork {
                        Image(nsImage: nsImg)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
                            .scaleEffect(swell ? 1.1 : 1)
                            .opacity(artFlies ? 0 : 1)   // drawn by `flyingArt` instead, keeps the layout
                            .transition(.wingSwap)
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                .frame(width: wing, height: geom.notchHeight)
                .offset(x: -swellX, y: (geom.compactHeight - geom.notchHeight) / 2 + swellY)   // centred on the whole capsule, not just the notch band
                .animation(wingSpring, value: swell)

                Spacer()
                    .frame(width: geom.notchWidth, height: geom.notchHeight)

                ZStack {   // overlapping, like the left wing
                    if let n = agentNotice {
                        // Two buttons fill most of the wing: keep them clear of the island's rounded end.
                        noticeBadge(n).padding(.trailing, 8).transition(.wingSwap)
                    } else if let sn = sysNotice {
                        noticeTrailing(sn).transition(.wingSwap)
                    } else if noticeKind == 5 {
                        recordingStop.padding(.trailing, 8).transition(.wingSwap)
                    } else if noticeKind == 4, let m = meeting {
                        meetingTrailing(m).transition(.wingSwap)
                    } else if timerBar {
                        timerTrailing.transition(.wingSwap)
                    } else if focus.clock.isActive {
                        timerMini.transition(.wingSwap)   // music plays: the timer shares the right wing
                    } else {
                        MiniAudioVisualizer(isPlaying: musicTracker.isPlaying, tint: tint)
                            .scaleEffect(swell ? 1.12 : 1)
                            .transition(.wingSwap)
                    }
                }
                .frame(width: wing, height: geom.notchHeight)
                .offset(x: swellX, y: (geom.compactHeight - geom.notchHeight) / 2 + swellY)
                .animation(wingSpring.delay(0.015), value: swell)
            }
            .frame(width: width, height: geom.notchHeight)

            // Row 2: lyric rows, physically below the camera cutout
            do {
                // The old and new line share one ZStack cell, so while both exist they overlap in place. (In a stack
                // they were laid out one above the other, which made the whole row jump up for a frame.)
                ZStack {
                    compactLyricRows(width: width, tint: tint, lineIndex: lyricService.compactLineIndex)
                        .id(lyricRowID)
                        // Old line lifts away while the new one rises in, overlapping, so there is no empty gap.
                        .transition(.asymmetric(
                            insertion: .lyricSlide(y: 10).animation(.easeInOut(duration: 0.34)),
                            removal: .lyricSlide(y: -10).animation(.easeInOut(duration: 0.34))))
                }
                .animation(.easeInOut(duration: 0.34), value: lyricRowID)   // the swap needs a transaction, or the transition above never runs and the line hard-cuts
                .frame(width: width, height: geom.compactHeight - geom.notchHeight)
                    .offset(y: swellY > 0 ? swellY - 1 : 0)   // -1: the 1.05 scale below already pushes the text down a little
                    .scaleEffect(swell ? 1.05 : 1, anchor: .top)
                    .animation(rowSpring, value: swell)
            }
        }
        .scaleEffect(bounce ? 1.07 : 1, anchor: .top)
    }

    /// No notch: everything on one line inside a floating capsule, like the iPhone's Dynamic Island:
    /// round cover on the left, the lyric in the middle, the bars on the right.
    private func capsuleBar(width: CGFloat, swell: Bool) -> some View {
        let tint: Color = musicTracker.artworkTint
        let side = NotchGeometry.capsuleSide
        let lyricWidth = width - 2 * side
        return HStack(spacing: 0) {
            ZStack {
                if let n = agentNotice {
                    CatAvatar(state: n.state, look: noticeLook(n)).frame(width: 28, height: 28)
                        .transition(.wingSwap)
                } else if let sn = sysNotice {
                    noticeIcon(sn).transition(.wingSwap)
                } else if noticeKind == 5 {
                    recordingIcon.transition(.wingSwap)
                } else if noticeKind == 4, let m = meeting {
                    meetingIcon(m).transition(.wingSwap)
                } else if timerBar {
                    timerIcon.transition(.wingSwap)
                } else if let nsImg = musicTracker.currentArtwork {
                    Image(nsImage: nsImg)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 24, height: 24)
                        .clipShape(Circle())
                        .transition(.wingSwap)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            .frame(width: side)

            ZStack {
                // compactLyricRows pads 22pt on each side, so hand it 44pt more than the room it really has.
                compactLyricRows(width: lyricWidth + 44, tint: tint, lineIndex: lyricService.compactLineIndex)
                    .id(lyricRowID)
                    .transition(.asymmetric(
                        insertion: .lyricSlide(y: 10).animation(.easeInOut(duration: 0.34)),
                        removal: .lyricSlide(y: -10).animation(.easeInOut(duration: 0.34))))
            }
                .animation(.easeInOut(duration: 0.34), value: lyricRowID)   // the swap needs a transaction, or the transition above never runs and the line hard-cuts
            .frame(width: lyricWidth)
            .clipped()

            ZStack {
                if let n = agentNotice {
                    noticeBadge(n).transition(.wingSwap)
                } else if let sn = sysNotice {
                    noticeTrailing(sn).transition(.wingSwap)
                } else if noticeKind == 5 {
                    recordingStop.transition(.wingSwap)
                } else if noticeKind == 4, let m = meeting {
                    meetingTrailing(m).transition(.wingSwap)
                } else if timerBar {
                    timerTrailing.transition(.wingSwap)
                } else if focus.clock.isActive {
                    timerMini.transition(.wingSwap)
                } else {
                    MiniAudioVisualizer(isPlaying: musicTracker.isPlaying, tint: tint).transition(.wingSwap)
                }
            }
            .frame(width: side)
        }
        .frame(width: width, height: geom.compactHeight)
        .scaleEffect(swell ? 1.04 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: swell)
        .scaleEffect(bounce ? 1.07 : 1)
    }

    private func meetingIcon(_ m: CalendarService.Item) -> some View {
        Image(systemName: "calendar").font(.system(size: 22, weight: .semibold)).foregroundColor(m.color)
            .symbolEffect(.bounce, options: .repeat(2), value: m.id)
    }

    private func meetingTrailing(_ m: CalendarService.Item) -> some View {
        Text(CalendarService.countdown(to: m.start, now: calendar.now).replacingOccurrences(of: " 分鐘後", with: " 分"))
            .font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundColor(m.color).lineLimit(1)
            .contentTransition(.numericText(countsDown: true))
    }

    private var timerIcon: some View {
        let c = focus.clock
        return ZStack {
            FocusRing(progress: c.progress(at: focus.now), tint: focus.tint, lineWidth: 3.2)
            Image(systemName: c.phase == .focus ? "flame.fill" : "cup.and.saucer.fill")
                .font(.system(size: 13, weight: .bold)).foregroundColor(focus.tint)
                .symbolEffect(.pulse, options: .repeating, isActive: c.isRunning)
        }
        .frame(width: 30, height: 30)
    }

    private var timerTrailing: some View {
        Text(FocusClock.format(focus.clock.remaining(at: focus.now)))
            .font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundColor(focus.tint)
            .contentTransition(.numericText(countsDown: true))
            .animation(.snappy, value: Int(focus.clock.remaining(at: focus.now)))
    }

    /// The timer squeezed beside the music: a small ring with the minutes left inside.
    private var timerMini: some View {
        let c = focus.clock
        return ZStack {
            FocusRing(progress: c.progress(at: focus.now), tint: focus.tint, lineWidth: 2.2)
            Text("\(Int((c.remaining(at: focus.now) / 60).rounded(.up)))")
                .font(.system(size: 9, weight: .bold)).monospacedDigit().foregroundColor(focus.tint)
        }
        .frame(width: 20, height: 20)
    }

    @ViewBuilder
    private func noticeIcon(_ n: IslandNotice) -> some View {
        if let level = n.battery {
            BatteryGauge(percent: level, charging: n.charging, tint: n.tint)
        } else if let pods = n.earbuds {
            DeviceRing(icon: n.icon, level: pods.buds)
        } else {
            // A level (volume, brightness, keyboard light) fills the symbol's variable parts and bounces on every step;
            // other notices pulse while they show (AirPods stay solid white like the system's own pop-up).
            Image(systemName: n.icon, variableValue: n.meter).font(.system(size: 24, weight: .semibold)).foregroundColor(n.tint)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce.wholeSymbol, value: n.meter)   // whole symbol: by-layer bounce moved the waves sideways
                .symbolEffect(.pulse, options: .repeating, isActive: n.meter == nil && !n.icon.hasPrefix("airpods"))
        }
    }

    @ViewBuilder
    private func noticeTrailing(_ n: IslandNotice) -> some View {
        Group {
            if let level = n.battery {
                BatteryPercentText(percent: level)
            } else if let pods = n.earbuds, let c = pods.caseLevel {
                DeviceRing(icon: pods.caseIcon, level: c, size: 30)
            } else {
                Text(n.trailing).contentTransition(.numericText())   // digits roll when the value changes
            }
        }
        .font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundColor(n.tint).lineLimit(1)
    }

    /// The island swells a little and springs back.
    private func pop() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.45)) { bounce = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { bounce = false }
        }
    }

    private let tabSpacing: CGFloat = 5
    private static let leftTabs = 4

    private func tabButtons(_ list: ArraySlice<(id: Int, title: String, icon: String)>) -> some View {
        ForEach(list, id: \.id) { t in
            TabButton(title: t.title, icon: t.icon, isSelected: selectedTab == t.id, namespace: tabNS,
                      badgeCount: t.id == 1 && monitor.visibleAlert != nil ? 1 : nil) { switchTab(t.id) }
        }
    }

    private func switchTab(_ id: Int) {
        guard id != selectedTab else { return }
        tabForward = id > selectedTab
        DispatchQueue.main.async {   // after `tabForward` is rendered, so the old page leaves in the right direction
            withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) { selectedTab = id }
        }
    }

    /// The cat of the session a notification is about (same look as its card).
    private func noticeLook(_ n: LocalAgentSession) -> CatLook {
        CatLook.assign(monitor.sessions.map { (id: $0.id, seed: $0.cwd.isEmpty ? $0.name : $0.cwd) })[n.id] ?? CatLook.all[0]
    }

    /// Right wing of a notification: ✕ / ✓ while a permission request waits for you, an orange dot for a plain
    /// "waiting" state, a green check when done.
    @ViewBuilder
    private func noticeBadge(_ n: LocalAgentSession) -> some View {
        if let p = monitor.pendingApproval(for: n) {
            HStack(spacing: 4) {
                approvalButton("xmark", Color(red: 0.95, green: 0.35, blue: 0.35), "拒絕") { monitor.resolve(p, .deny) }
                if p.request.complete && (p.request.summaryIsInput || settings.quickApprove) {
                    approvalButton("checkmark", Color(red: 0.3, green: 0.8, blue: 0.45), "允許") { monitor.resolve(p, .allow) }
                } else {
                    // The line shows a description, not the command: ✓ opens the card with the real command first.
                    approvalButton("checkmark", Color(red: 0.3, green: 0.8, blue: 0.45), "看完整內容再允許") {
                        // Open a taller island showing the whole request, with the buttons under it.
                        geom.reviewingApproval = p.id
                        withAnimation(.spring(response: 0.46, dampingFraction: 0.78)) { geom.isExpanded = true }
                    }
                }
            }
        } else if n.state == .waitingApproval {
            // Waiting, but the request never reached our hook (timed out, or a question only the terminal can
            // answer): offer a jump to the session instead of buttons that could not work.
            approvalButton("arrow.up.forward", .orange, "前往終端機回覆") { monitor.focusHost(of: n) }
        } else {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(Color(red: 0.4, green: 0.87, blue: 0.6))
        }
    }

    private func approvalButton(_ icon: String, _ color: Color, _ label: String, _ action: @escaping () -> Void) -> some View {
        // A tap gesture, not a Button: a Button's click also reached the island's own tap and expanded it;
        // a child's tap gesture wins over the parent's, so the click stays here.
        let tap = {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            action()
        }
        return Image(systemName: icon)
            .font(.system(size: 10.5, weight: .heavy))
            .foregroundColor(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(color))
            .contentShape(Circle())
            .onTapGesture(perform: tap)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(label)
            .accessibilityAction { tap() }
    }

    /// The cover is one view on top of both layouts, so opening grows the wing cover into the page's artwork (and
    /// closing shrinks it back) on the island's own spring, instead of one image fading out while another fades in.
    private var artFlies: Bool {
        geom.integrated && musicTracker.currentArtwork != nil && (presence.isActive || geom.isExpanded)
            && (geom.isExpanded ? selectedTab == 0 && geom.reviewingApproval == nil : noticeKind == 0)
    }

    @ViewBuilder
    private func flyingArt(compactW: CGFloat, grow: Bool) -> some View {
        if artFlies, let img = musicTracker.currentArtwork {
            let open = geom.isExpanded
            // Same as the bar's song-change bounce: scaled about the island's top centre, which is this view's origin.
            let k: CGFloat = !open && bounce ? 1.07 : 1
            let side: CGFloat = (open ? 120 : (grow ? 24 * 1.1 : 24)) * k
            // Centres relative to the island's top centre: the left wing's middle (plus the swell shift), or the
            // now-playing page's artwork slot (top bar, 8pt padding, `contentEdge` inset).
            let wing = (compactW - geom.notchWidth) / 2
            let cx = open ? -geom.expandedWidth / 2 + geom.contentEdge + 60
                : -compactW / 2 + wing / 2 - (grow ? geom.swellSize.width / 4 : 0)
            let cy = open ? geom.topBarHeight + 8 + 60
                : geom.compactHeight / 2 + (grow ? geom.swellSize.height / 2 : 0)
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: open ? 18 : 6.5 * side / 24, style: .continuous))
                .offset(x: cx * k, y: cy * k - side / 2)
                .allowsHitTesting(false)
                .transition(.opacity)   // not wingSwap: its scale would pull the offset cover toward the island's centre
        }
    }

    /// Click on the collapsed island: expand it (straight to the Agents page when an agent needs approval).
    private func expandFromClick() {
        guard !geom.isExpanded else { return }
        // A "waiting" notice the island cannot answer: the click means "take me there", not "open the island".
        if let n = agentNotice, n.state == .waitingApproval, monitor.pendingApproval(for: n) == nil {
            monitor.focusHost(of: n)
            return
        }
        withAnimation(.spring(response: 0.46, dampingFraction: 0.68)) {
            // Open on the page of whatever the collapsed island was showing.
            switch noticeKind {
            case 1: selectedTab = 1
            case 3: selectedTab = 2
            case 4: selectedTab = 3
            case 5: selectedTab = 6   // recording: the controls page has its stop button
            default: break
            }
            geom.isExpanded = true
        }
    }

    /// Sweep progress of the line at `index`: lines already sung are fully lit, lines to come are unlit, and only the
    /// current line follows the live progress. A line sliding out therefore keeps its lit state instead of
    /// snapping to dim when the next line becomes current.
    private func sweepProgress(forLine index: Int) -> CGFloat {
        let current = lyricService.compactLineIndex
        if index < current { return 1 }
        if index > current { return 0 }
        return lyricService.compactLineProgress
    }

    @ViewBuilder
    private func compactLyricRows(width: CGFloat, tint: Color, lineIndex: Int) -> some View {
        VStack(alignment: .center, spacing: 1) {
            if songBanner {
                Text("\(musicTracker.currentTrack.title)  ·  \(musicTracker.currentTrack.artist)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(tint)
                    .lineLimit(1)
            } else if let alert = agentNotice {
                HStack(spacing: 5) {
                    Text("\(alert.name):")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundColor(alert.state == .waitingApproval ? .yellow : Color(red: 0.4, green: 0.87, blue: 0.6))
                    Text(alert.state == .waitingApproval ? (alert.prompt ?? "請求授權") : "完成了")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
            } else if let sn = sysNotice {
                if let level = sn.meter {
                    MeterBar(value: level).padding(.top, 4)
                } else {
                    HStack(spacing: 5) {
                        Text("\(sn.title):").font(.system(size: 11.5, weight: .bold)).foregroundColor(sn.tint)
                        Text(sn.detail).font(.system(size: 11.5, weight: .medium)).foregroundColor(.white).lineLimit(1)
                    }
                }
            } else if noticeKind == 5 {
                HStack(spacing: 5) {
                    Text("錄影中:").font(.system(size: 11.5, weight: .bold)).foregroundColor(.red)
                    Text(ScreenRecorder.elapsed(recorder.now.timeIntervalSince(recorder.started ?? recorder.now)))
                        .font(.system(size: 11.5, weight: .semibold)).monospacedDigit().foregroundColor(.white)
                        .contentTransition(.numericText())
                }
            } else if noticeKind == 4, let m = meeting {
                HStack(spacing: 5) {
                    Text("會議:").font(.system(size: 11.5, weight: .bold)).foregroundColor(m.color)
                    Text(m.title).font(.system(size: 11.5, weight: .medium)).foregroundColor(.white).lineLimit(1)
                }
            } else if timerBar {
                let c = focus.clock
                HStack(spacing: 5) {
                    Text(c.phase == .focus ? (c.isRunning ? "專注中:" : "已暫停:") : "休息中:")
                        .font(.system(size: 11.5, weight: .bold)).foregroundColor(focus.tint)
                    Text(c.phase == .focus ? "第 \(c.cycles + 1) 輪・\(c.preset.focus) 分鐘" : "休息 \(c.preset.rest) 分鐘")
                        .font(.system(size: 11.5, weight: .medium)).foregroundColor(.white).lineLimit(1)
                }
            } else if lyricService.isInterlude {
                InterludeDots(tint: tint, progress: { lyricService.liveInterludeProgress() })
            } else if lyricService.isIntro, lyricService.compactLyrics?.lines.isEmpty == false {
                // Intro: no lyric yet, so just the song title.
                Text(musicTracker.currentTrack.title)
                    .font(.system(size: 13 * CGFloat(settings.lyricFontScale), weight: .semibold))
                    .foregroundColor(tint)
                    .lineLimit(1)
            } else if let doc = lyricService.compactLyrics, !doc.lines.isEmpty {
                let idx = min(max(lineIndex, 0), doc.lines.count - 1)
                let line = doc.lines[idx]
                let progress = sweepProgress(forLine: idx)
                let live: () -> CGFloat = { [lyricService] in lyricService.liveCompactProgress(forLine: idx) }

                let so = CGFloat(settings.lyricFontScale)

                if settings.showTranslation, settings.translationSideBySide, let tr = line.translation {
                    // Left / right: original and translation each get half the row around a fixed divider;
                    // whichever half is too long scrolls as a marquee inside its own half.
                    let half = (width - 44 - 13 - 20) / 2   // 20 narrower than the full row: keeps the two centred texts a little closer together
                    HStack(spacing: 0) {
                        FlowingKaraokeView(
                            text: line.text, progress: progress, progressProvider: live,
                            fontSize: 13 * so, highlight: tint, glow: false, weight: .semibold, centered: true
                        )
                        .frame(width: half)
                        Color.clear.frame(width: 13)   // gap between the two halves (no divider line)
                        FlowingKaraokeView(
                            text: tr, progress: progress, progressProvider: live,
                            fontSize: 13 * so, highlight: tint.opacity(0.75), glow: false, weight: .semibold, centered: true
                        )
                        .frame(width: half)
                    }
                    .frame(width: width - 44)
                } else {
                    FlowingKaraokeView(
                        text: line.text,
                        translation: nil,
                        progress: progress, progressProvider: live,
                        fontSize: 13 * so,
                        highlight: tint,
                        glow: false,
                        weight: .semibold,
                        centered: true
                    )
                    .frame(width: width - 44)

                    if settings.showTranslation, let tr = line.translation {
                        // Same marquee as the lyric when the translation is wider than the row.
                        FlowingKaraokeView(
                            text: tr, progress: progress, progressProvider: live,
                            fontSize: 13 * so, highlight: tint.opacity(0.7), glow: false, weight: .semibold, centered: true
                        )
                        .frame(width: width - 44)
                    }
                }
            } else if !musicTracker.hasTrack {
                Text("尚未播放音樂")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
            } else {
                Text("\(musicTracker.currentTrack.title)  ·  \(musicTracker.currentTrack.artist)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 22)   // keep text clear of the rounded bottom corners
        .frame(maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Expanded Notch Mode (510x205)
    private var expandedNotchBody: some View {
        VStack(spacing: 0) {
            // Top Bar: Tab Switcher (Left), Cutout Space (Center), Tool Controls (Right)
            HStack(spacing: 0) {
                // Top-Left Tabs: [ 🎵 歌詞 ] [ 🏢 辦公室 ] [ >_ Agents ]
                // Tabs are split around the camera (3 left, the rest right) so none ever sits under the notch.
                HStack(spacing: tabSpacing) { tabButtons(Self.tabs.prefix(Self.leftTabs).filter { !settings.hiddenTabs.contains($0.id) }[...]) }
                .padding(.leading, geom.contentEdge)

                Spacer()

                // Camera gap: only the notch layout has the hardware in the way of the top bar.
                if geom.integrated {
                    Spacer().frame(width: geom.notchWidth, height: geom.notchHeight)
                    Spacer()
                }

                // Top-Right: the remaining tabs, then [ ⚙ ] (the 譯 toggle is on the music page)
                HStack(spacing: 4) {   // tight: the first tab must clear the notch
                    HStack(spacing: tabSpacing) { tabButtons(Self.tabs.dropFirst(Self.leftTabs).filter { !settings.hiddenTabs.contains($0.id) }[...]) }
                    // Settings: opens the settings window and tucks the island away.
                    Button(action: { geom.collapseAndShowSettings() }) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.8))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.trailing, geom.contentEdge - 5)   // the gear glyph sits 5pt inside its 22pt tap area: align the glyph, not the box
            }
            .frame(height: geom.topBarHeight)

            // Content area fills everything below the notch, so the top bar never moves between tabs.
            ZStack {
                if let id = geom.reviewingApproval, let p = monitor.pendingApprovals.first(where: { $0.id == id }) {
                    ApprovalReviewView(item: p).transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else {
                Group {
                    switch selectedTab {
                    case 0: NowPlayingView(hideArtwork: artFlies)
                    case 2: FocusTimerView()
                    case 3: CalendarPageView()
                    case 4: ShelfPage()
                    case 5: SystemPageView()
                    case 6: ControlsView()
                    default: AgentListView()
                    }
                }
                .id(selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.asymmetric(insertion: .tabSlide(x: tabForward ? 36 : -36),
                                        removal: .tabSlide(x: tabForward ? -36 : 36)))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Tab Switcher Button
private struct TabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    var width: CGFloat = 34
    let namespace: Namespace.ID
    var badgeCount: Int? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .symbolEffect(.bounce, value: isSelected)
                .frame(width: width, height: 26)
                .foregroundColor(isSelected ? .white : .white.opacity(0.45))
                .background {
                    // One highlight that slides between the tabs.
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.14))
                            .matchedGeometryEffect(id: "tabPill", in: namespace)
                    }
                }
                // A transparent background is not clickable in SwiftUI: without this, an unselected tab only reacted
                // when the click landed exactly on the icon's strokes.
                .contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    if let count = badgeCount, count > 0 {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 7, height: 7)
                            .offset(x: -3, y: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

// MARK: - Mini Audio Visualizer
private struct MiniAudioVisualizer: View {
    let isPlaying: Bool
    let tint: Color

    var body: some View {
        // Paused: the timeline stops and the bars rest flat.
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !isPlaying)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<4, id: \.self) { i in
                    let wave = (sin(t * (3.1 + Double(i) * 0.9) + Double(i) * 1.7) + 1) / 2
                    Capsule()
                        .fill(tint.opacity(isPlaying ? 0.9 : 0.45))
                        .frame(width: 2.6, height: isPlaying ? 5 + 9 * CGFloat(wave) : 4)
                }
            }
            .frame(height: 16)
        }
    }
}

// MARK: - Island content transition
/// Scales (anchored at the top), fades and blurs content in/out so the island content morphs with the shape.
private struct IslandContentEffect: ViewModifier {
    let scale: CGFloat
    let blur: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale, anchor: .top)
            .blur(radius: blur)
            .opacity(opacity)
    }
}

/// Instrumental break: three dots that light up one after another over the break and breathe gently
/// (the convention of Apple Music's lyrics view).
private struct InterludeDots: View {
    let tint: Color
    let progress: () -> CGFloat

    var body: some View {
        TimelineView(.animation) { t in
            let p = progress()
            let breathe = 1 + 0.12 * sin(t.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.6)
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    let lit = min(max(p * 3 - CGFloat(i), 0), 1)   // dot i fills during its third of the break
                    Circle()
                        .fill(tint.opacity(0.3 + 0.7 * lit))
                        .frame(width: 6, height: 6)
                        .scaleEffect(breathe)
                }
            }
        }
    }
}

private extension AnyTransition {
    /// A wing item handing over to the other feature's (cover ↔ cat, bars ↔ badge): the old item clears out almost at
    /// once (blurring), the new one blooms in a beat later, once the island has started to reshape (as the best
    /// notch apps do: never two contents on top of each other).
    static var wingSwap: AnyTransition {
        .asymmetric(insertion: .islandContent(scale: 0.6, blur: 10).animation(.spring(response: 0.42, dampingFraction: 0.78).delay(0.1)),
                    removal: .islandContent(scale: 0.8, blur: 8).animation(.easeIn(duration: 0.09)))
    }

    static func islandContent(scale: CGFloat, blur: CGFloat) -> AnyTransition {
        .modifier(
            active: IslandContentEffect(scale: scale, blur: blur, opacity: 0),
            identity: IslandContentEffect(scale: 1, blur: 0, opacity: 1)
        )
    }
}

private struct TabSlideEffect: ViewModifier {
    let x: CGFloat
    let opacity: Double
    let blur: CGFloat
    func body(content: Content) -> some View { content.offset(x: x).opacity(opacity).blur(radius: blur) }
}

// MARK: - Lyric line transition
/// Moves vertically while fading, so a new lyric line rises into place and the old one lifts away.
private struct LyricSlideEffect: ViewModifier {
    let y: CGFloat
    let opacity: Double
    func body(content: Content) -> some View { content.offset(y: y).opacity(opacity) }
}

private extension AnyTransition {
    /// A page sliding sideways (with a little blur) as you change tabs.
    static func tabSlide(x: CGFloat) -> AnyTransition {
        .modifier(active: TabSlideEffect(x: x, opacity: 0, blur: 6), identity: TabSlideEffect(x: 0, opacity: 1, blur: 0))
    }

    static func lyricSlide(y: CGFloat) -> AnyTransition {
        .modifier(active: LyricSlideEffect(y: y, opacity: 0), identity: LyricSlideEffect(y: 0, opacity: 1))
    }
}

// MARK: - Island animation
/// Everything that determines how the island looks: when any of it changes, the island animates.
private struct IslandState: Equatable {
    var expanded: Bool
    var idle: Bool
    var peeking: Bool
    var grow: Bool
    var width: CGFloat
    var height: CGFloat
}

/// The spring for the current situation: opening has a little overshoot, tucking into the notch is smooth and
/// unhurried (no bounce), swelling toward the pointer is quick.
private func islandSpring(expanded: Bool, idle: Bool, nearNotch: Bool) -> Animation {
    if expanded { return .spring(response: 0.46, dampingFraction: 0.68) }
    if idle { return .spring(response: 0.5, dampingFraction: 0.9) }
    if nearNotch { return .spring(response: 0.3, dampingFraction: 0.8) }
    return .spring(response: 0.38, dampingFraction: 0.88)
}

// MARK: - Island outline
/// The island's silhouette: the notch shape (concave shoulders) on a notched display, a capsule / rounded card on a
/// display without one. The corner radius animates, so a capsule morphs smoothly into the expanded card.
struct IslandOutline: Shape {
    var notched: Bool
    /// Flat top flush with the screen edge, only the lower corners rounded (the fused capsule).
    var flatTop = false
    var cornerRadius: CGFloat

    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        if notched { return NotchShape(cornerRadius: cornerRadius, earRadius: 6).path(in: rect) }
        let r = min(cornerRadius, rect.height / 2)
        if flatTop { return UnevenRoundedRectangle(bottomLeadingRadius: r, bottomTrailingRadius: r, style: .continuous).path(in: rect) }
        return RoundedRectangle(cornerRadius: r, style: .continuous).path(in: rect)
    }
}
