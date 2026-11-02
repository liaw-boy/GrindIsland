import SwiftUI
import AppKit

/// Expanded "now playing" page. Measurements follow the reference layout: 120pt artwork, a 175pt
/// player column, and a 182pt bilingual lyric window that slides upward on every line change.
struct NowPlayingView: View {
    @ObservedObject private var music = MusicTracker.shared
    @ObservedObject private var lyrics = LyricService.shared
    @EnvironmentObject private var geom: NotchGeometry   // this display's island
    @ObservedObject private var settings = AppSettings.shared
    /// The island draws the cover itself while it grows into this slot (see `NotchRootView.flyingArt`).
    var hideArtwork = false

    private let artworkSize: CGFloat = 120
    private let playerWidth: CGFloat = 175
    /// 540pt of content = cover 120 + gap 14 + player 175 + gap 18 + lyrics 213: the margins left and right are equal.
    private let lyricWidth: CGFloat = 213

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            artwork
            playerColumn
                .frame(width: playerWidth, height: artworkSize)
                .padding(.leading, 14)
            lyricColumn
                .frame(width: lyricWidth, height: artworkSize, alignment: .center)
                .clipped()
                // Nothing to click here, and the rows above and below the window are only clipped from view, not from
                // the pointer: they sat over the tab bar and swallowed clicks on the right-hand tabs.
                .allowsHitTesting(false)
                .padding(.leading, 18)
        }
        .padding(.leading, geom.contentEdge)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Artwork

    private var artwork: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let img = music.currentArtwork {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.1))
                        .overlay(Image(systemName: "music.note").font(.system(size: 28)).foregroundColor(.white.opacity(0.5)))
                }
            }
            .frame(width: artworkSize, height: artworkSize)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .opacity(hideArtwork ? 0 : 1)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(red: 0.98, green: 0.22, blue: 0.38))
                .frame(width: 24, height: 24)
                .overlay(Image(systemName: "music.note").font(.system(size: 13, weight: .bold)).foregroundColor(.white))
                .offset(x: 6, y: 0)
        }
        .frame(width: artworkSize, height: artworkSize)
    }

    // MARK: - Player

    private var playerColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(music.currentTrack.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(music.currentTrack.artist)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                // Translation on/off; an orange dot when this song's translation is macOS's own.
                Button(action: { settings.showTranslation.toggle() }) {
                    Text("譯")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(settings.showTranslation ? Color(red: 0.35, green: 0.8, blue: 1.0) : Color.white.opacity(0.45))
                        .frame(width: 22, height: 18)
                        .background(settings.showTranslation ? Color.cyan.opacity(0.2) : Color.white.opacity(0.08))
                        .cornerRadius(4)
                        .overlay(alignment: .topTrailing) {
                            if lyrics.translationIsMachine {
                                Circle().fill(Color.orange).frame(width: 5, height: 5).offset(x: 2, y: -2)
                            }
                        }
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(lyrics.translationIsMachine ? "翻譯（這首沒有現成翻譯，由 macOS 自動翻譯）" : "翻譯")
                Button(action: { music.toggleFavorite() }) {
                    Image(systemName: music.isFavorited ? "heart.fill" : "heart")
                        .font(.system(size: 14))
                        .foregroundColor(music.isFavorited ? Color(red: 1.0, green: 0.35, blue: 0.5) : .white.opacity(0.8))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(height: 40, alignment: .top)

            progressBar
                .padding(.top, 12)

            Spacer(minLength: 0)

            HStack(spacing: 15) {
                modeButton("shuffle", on: music.shuffle, help: music.shuffle ? "隨機播放：開" : "隨機播放：關") { music.toggleShuffle() }
                controlButton("backward.fill", size: 16) { music.previousTrack() }
                Button(action: { music.togglePlayPause() }) {
                    Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                controlButton("forward.fill", size: 16) { music.nextTrack() }
                modeButton(music.repeatMode == "one" ? "repeat.1" : "repeat", on: music.repeatMode != "off",
                           help: music.repeatMode == "one" ? "單曲循環" : music.repeatMode == "all" ? "全部循環" : "循環播放：關") { music.cycleRepeat() }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
        }
    }

    private var progressBar: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { _ in
            let duration = music.currentTrack.duration
            let pos = music.livePosition()
            let fraction = duration > 0 ? min(max(pos / duration, 0), 1) : 0
            progressContent(fraction: fraction, position: TrackInfo(duration: duration, position: pos).formattedPosition)
        }
    }

    private func progressContent(fraction: Double, position: String) -> some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                    Capsule()
                        .fill(Color.white)
                        .frame(width: max(geo.size.width * CGFloat(fraction), 4))
                }
                .frame(height: 5)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { value in
                        let f = min(max(value.location.x / geo.size.width, 0), 1)
                        music.seek(to: music.currentTrack.duration * Double(f))
                    }
                )
            }
            .frame(height: 10)

            HStack {
                Text(position)
                Spacer()
                Text(music.currentTrack.formattedDuration)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white.opacity(0.55))
        }
    }

    /// Shuffle / repeat: lit in the artwork's colour when on, dim when off.
    private func modeButton(_ symbol: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(on ? music.artworkTint : .white.opacity(0.4))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func controlButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundColor(.white)
                .frame(width: 24, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Lyrics

    // Fixed sizes: the font-size settings only apply to the collapsed island. The original lyric leads.
    private let rowHeight: CGFloat = 64
    private var windowHeight: CGFloat { artworkSize }

    @ViewBuilder
    private var lyricColumn: some View {
        if lyrics.isIntro, lyrics.currentLyrics?.lines.isEmpty == false {
            // Intro: no lyric yet, so just the song title.
            VStack(spacing: 4) {
                Text(music.currentTrack.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(music.artworkTint)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Text(music.currentTrack.artist)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .frame(width: lyricWidth, height: windowHeight)
        } else if let doc = lyrics.currentLyrics, !doc.lines.isEmpty {
            let active = min(max(lyrics.currentLineIndex, 0), doc.lines.count - 1)
            let range = max(active - 2, 0)...min(active + 2, doc.lines.count - 1)

            // Every row is the same view; a line change only slides the rows upward.
            ZStack(alignment: .topLeading) {
                ForEach(Array(range), id: \.self) { i in
                    lyricRow(doc.lines[i], relative: i - active)
                        .frame(width: lyricWidth, height: rowHeight, alignment: .center)
                        .offset(y: (windowHeight - rowHeight) / 2 + CGFloat(i - active) * rowHeight)
                }
            }
            .frame(width: lyricWidth, height: windowHeight, alignment: .topLeading)
            .animation(.spring(response: 0.5, dampingFraction: 0.9), value: active)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.2),
                        .init(color: .black, location: 0.8),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
        } else {
            VStack(spacing: 6) {
                Image(systemName: "music.quarternote.3")
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.3))
                Text(lyrics.isLoading ? "歌詞載入中…" : (music.hasTrack ? "找不到這首歌的歌詞" : "尚未播放音樂"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
            }
            .frame(width: lyricWidth, height: windowHeight)
        }
    }

    /// `relative` is the row's offset from the active line. Rows keep the same colors while they slide: lines
    /// already sung are fully lit, the active line is partly lit, lines to come are unlit - so when a line
    /// becomes active (or stops being active) only its position and opacity change, never its color.
    private func lyricRow(_ line: LyricLine, relative: Int) -> some View {
        let isActive = relative == 0
        let distance = abs(relative)
        let translation = settings.showTranslation ? line.translation : nil

        return VStack(alignment: .center, spacing: 4) {
            SweptLine(text: line.text, state: relative < 0 ? .sung : isActive ? .singing : .coming, litColor: music.artworkTint)
                .font(.system(size: 15, weight: .bold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let tr = translation {
                Text(tr)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .opacity(isActive ? 1 : (distance == 1 ? 0.7 : 0.3))
        .scaleEffect(isActive ? 1 : 0.96)
    }
}

/// One lyric line lit up to the sung share. Only the line being sung watches the per-frame progress, so the rest
/// of the page (and its buttons) does not redraw 60 times a second.
private struct SweptLine: View {
    enum State { case sung, singing, coming }
    let text: String
    let state: State
    let litColor: Color

    var body: some View {
        if state == .singing { Live(text: text, litColor: litColor) } else { Self.render(text, lit: state == .sung ? 1 : 0, litColor) }
    }

    private struct Live: View {
        let text: String
        let litColor: Color
        @ObservedObject private var progress = LyricProgress.shared
        var body: some View { SweptLine.render(text, lit: progress.expanded, litColor) }
    }

    static func render(_ text: String, lit share: CGFloat, _ litColor: Color) -> Text {
        let chars = Array(text)
        let lit = Int((CGFloat(chars.count) * min(max(share, 0), 1)).rounded(.down))
        return Text(String(chars.prefix(lit))).foregroundColor(litColor) + Text(String(chars.dropFirst(lit))).foregroundColor(.white.opacity(0.55))
    }
}
