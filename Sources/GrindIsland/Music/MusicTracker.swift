import Foundation
import AppKit
import Combine
import SwiftUI

public struct TrackInfo: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var duration: Double
    public var position: Double
    public var isPlaying: Bool

    public init(
        title: String = "No Track Playing",
        artist: String = "Apple Music",
        duration: Double = 0.0,
        position: Double = 0.0,
        isPlaying: Bool = false
    ) {
        self.title = title
        self.artist = artist
        self.duration = duration
        self.position = position
        self.isPlaying = isPlaying
    }

    public var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1.0)
    }

    public var formattedPosition: String {
        formatTime(position)
    }

    public var formattedDuration: String {
        formatTime(duration)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds >= 0, !seconds.isNaN, !seconds.isInfinite else { return "0:00" }
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

public final class MusicTracker: ObservableObject, @unchecked Sendable {
    public static let shared = MusicTracker()

    @Published public var currentTrack: TrackInfo = TrackInfo()
    @Published public var currentArtwork: NSImage? = nil
    @Published public var isPlaying: Bool = false
    @Published public var isFavorited: Bool = false
    @Published public var shuffle: Bool = false
    @Published public var repeatMode: String = "off"   // "off" / "all" / "one"
    /// True while Music has a current track (playing or paused); false once it stopped or quit.
    @Published public var hasTrack: Bool = false
    /// Vivid color sampled from the artwork, used to tint the highlighted lyric.
    @Published public var artworkTint: Color = .white

    private var anchorTime: Double = 0.0
    private var anchorPosition: Double = 0.0
    private var pollTimer: Timer?
    private var playerInfoObserver: NSObjectProtocol?
    private var idleStreak = 0    // consecutive polls without a track (main thread)
    private var polling = false   // only touched on `queue`: skip a poll while one is still running
    private var pollScript: NSAppleScript?   // only touched on `queue`

    /// Continuous playback position (main thread): the last polled position plus elapsed time, so
    /// lyrics and the progress bar advance smoothly between the 1s AppleScript polls.
    public func livePosition(forLyrics: Bool = false) -> Double {
        guard isPlaying else { return anchorPosition }
        let lead = forLyrics ? AppSettings.shared.lyricLead : 0
        let p = anchorPosition + (CACurrentMediaTime() - anchorTime) + lead
        let d = currentTrack.duration
        return d > 0 ? min(p, d) : p
    }
    private let queue = DispatchQueue(label: "com.grindisland.music.tracker", qos: .userInitiated)

    private init() {}

    public func start() {
        stop()
        poll()
        DispatchQueue.main.async { [weak self] in
            self?.pollTimer = Timer.commonModeTimer(interval: 0.5, repeats: true) { [weak self] _ in
                self?.poll()
            }
        }
        // Music posts this on track change, play and pause: sync immediately instead of waiting for the timer.
        playerInfoObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: nil
        ) { [weak self] _ in
            self?.poll()
        }
    }

    public func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.pollTimer?.invalidate()
            self?.pollTimer = nil
        }
    }

    public func poll() {
        queue.async { [weak self] in
            guard let self = self, !self.polling else { return }
            self.polling = true
            defer { self.polling = false }

            let script = """
            if application "Music" is running then
                tell application "Music"
                    set pState to player state as string
                    if pState is "playing" or pState is "paused" then
                        set tName to name of current track
                        set tArtist to artist of current track
                        set tDur to duration of current track
                        set tPos to player position
                        set fav to "0"
                        try
                            if favorited of current track then set fav to "1"
                        end try
                        set sh to "0"
                        try
                            if shuffle enabled then set sh to "1"
                        end try
                        set rp to "off"
                        try
                            set rp to song repeat as string
                        end try
                        return tName & "|||" & tArtist & "|||" & tDur & "|||" & tPos & "|||" & pState & "|||" & fav & "|||" & sh & "|||" & rp
                    end if
                end tell
            end if
            return "IDLE"
            """

            var error: NSDictionary?
            // Compiled once and reused: compiling it on every poll (twice a second) was a steady CPU cost.
            if self.pollScript == nil, let s = NSAppleScript(source: script), s.compileAndReturnError(&error) { self.pollScript = s }
            guard let appleScript = self.pollScript else { return }
            let descriptor = appleScript.executeAndReturnError(&error)
            let result = descriptor.stringValue ?? "IDLE"

            if result == "IDLE" || result.isEmpty {
                DispatchQueue.main.async {
                    if self.isPlaying {
                        self.isPlaying = false
                        self.currentTrack.isPlaying = false
                    }
                    // A single failed poll must not wipe the state; 3 in a row (~1.5s) means Music stopped or quit.
                    self.idleStreak += 1
                    if self.idleStreak >= 3 && self.hasTrack { self.resetToIdle() }
                }
                return
            }

            let parts = result.components(separatedBy: "|||")
            guard parts.count >= 5 else { return }

            let title = parts[0]
            let artist = parts[1]
            let duration = Double(parts[2]) ?? 0.0
            let reportedPos = Double(parts[3]) ?? 0.0
            let stateStr = parts[4].lowercased()
            let playing = (stateStr == "playing")

            let now = CACurrentMediaTime()

            DispatchQueue.main.async {
                self.idleStreak = 0
                if !self.hasTrack { self.hasTrack = true }
                self.isFavorited = parts.count > 5 && parts[5] == "1"
                // Right after a click Music still reports the old shuffle / repeat for a moment: keep what was clicked.
                if parts.count > 7, CACurrentMediaTime() > self.modeHoldUntil {
                    let sh = parts[6] == "1", rp = Self.repeatMode(parts[7])
                    if sh != self.shuffle { self.shuffle = sh }
                    if rp != self.repeatMode { self.repeatMode = rp }
                }
                let trackChanged = (self.currentTrack.title != title || self.currentTrack.artist != artist)
                let stateChanged = (self.isPlaying != playing)

                self.isPlaying = playing

                // Re-anchor on track/state change, while paused (position must not drift), or when the
                // extrapolated clock disagrees with Music by more than 0.5s (seek).
                let expectedPos = self.anchorPosition + (now - self.anchorTime)
                if trackChanged || stateChanged || !playing || abs(reportedPos - expectedPos) > 0.5 {
                    self.anchorTime = now
                    self.anchorPosition = reportedPos
                }

                self.currentTrack = TrackInfo(
                    title: title,
                    artist: artist,
                    duration: duration,
                    position: self.livePosition(),
                    isPlaying: playing
                )

                if !trackChanged && self.currentArtwork == nil && now - self.lastArtworkTry > 5 {
                    self.lastArtworkTry = now
                    self.fetchArtwork()
                }

                if trackChanged {
                    self.lastArtworkTry = now
                    self.fetchArtwork()
                    LyricService.shared.fetchLyrics(title: title, artist: artist, duration: duration)
                }
            }
        }
    }

    private var lastArtworkTry: Double = 0

    /// Music stopped or quit: forget the track, artwork and lyrics so nothing stale stays on screen.
    private func resetToIdle() {
        isPlaying = false
        hasTrack = false
        currentTrack = TrackInfo()
        currentArtwork = nil
        isFavorited = false
        artworkTint = .white
        anchorPosition = 0
        LyricService.shared.clear()
    }

    /// Saturation-weighted average of a tiny downsample, lifted to a readable brightness.
    private static func dominantTint(of image: NSImage) -> Color {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .white }
        let w = 8, h = 8
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .white }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var r = 0.0, g = 0.0, b = 0.0, total = 0.0
        for i in 0..<(w * h) {
            let pr = Double(px[i * 4]) / 255, pg = Double(px[i * 4 + 1]) / 255, pb = Double(px[i * 4 + 2]) / 255
            let mx = max(pr, pg, pb), mn = min(pr, pg, pb)
            let sat = mx == 0 ? 0 : (mx - mn) / mx
            let weight = 0.05 + sat * sat
            r += pr * weight; g += pg * weight; b += pb * weight; total += weight
        }
        guard total > 0 else { return .white }
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        NSColor(red: r / total, green: g / total, blue: b / total, alpha: 1)
            .usingColorSpace(.deviceRGB)?
            .getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        // Soft, slightly desaturated tint: readable on black without looking neon.
        return Color(hue: Double(hue), saturation: Double(min(max(sat * 0.6, 0.18), 0.5)), brightness: 0.78)
    }

    public func seek(to position: Double) {
        queue.async {
            let script = "tell application \"Music\" to set player position to \(position)"
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            self.poll()
        }
    }

    public func toggleFavorite() {
        let target = !isFavorited
        isFavorited = target
        queue.async {
            let script = "tell application \"Music\" to set favorited of current track to \(target)"
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            self.poll()
        }
    }

    /// Music's own shuffle / repeat (the same as switching them in Music).
    /// Until this time, polls do not overwrite shuffle / repeat (the value just clicked).
    private var modeHoldUntil: CFTimeInterval = 0

    public func toggleShuffle() {
        let target = !shuffle
        shuffle = target
        modeHoldUntil = CACurrentMediaTime() + 1.5
        queue.async {
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"Music\" to set shuffle enabled to \(target)")?.executeAndReturnError(&error)
            self.poll()
        }
    }

    /// Off → all → one → off, like Music's button.
    public func cycleRepeat() {
        let target = Self.nextRepeat(repeatMode)
        repeatMode = target
        modeHoldUntil = CACurrentMediaTime() + 1.5
        queue.async {
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"Music\" to set song repeat to \(target)")?.executeAndReturnError(&error)
            self.poll()
        }
    }

    static func nextRepeat(_ mode: String) -> String { mode == "off" ? "all" : mode == "all" ? "one" : "off" }

    /// Music reports "off" / "one" / "all"; anything else counts as off.
    static func repeatMode(_ s: String) -> String { ["one", "all"].contains(s.lowercased()) ? s.lowercased() : "off" }

    public func togglePlayPause() {
        queue.async {
            let script = "tell application \"Music\" to playpause"
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            self.poll()
        }
    }

    public func nextTrack() {
        queue.async {
            let script = "tell application \"Music\" to next track"
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            self.poll()
        }
    }

    public func previousTrack() {
        queue.async {
            let script = "tell application \"Music\" to previous track"
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            self.poll()
        }
    }

    private func fetchArtwork() {
        queue.async { [weak self] in
            let path = NSTemporaryDirectory() + "grindisland_artwork.bin"
            try? FileManager.default.removeItem(atPath: path)
            // Writing the raw bytes to a file is the only reliable way to move artwork out of Music via AppleScript.
            let script = """
            tell application "Music"
                if player state is stopped then return "none"
                try
                    tell current track
                        set rawData to raw data of artwork 1
                    end tell
                on error
                    return "none"
                end try
            end tell
            set f to open for access POSIX file "\(path)" with write permission
            set eof f to 0
            write rawData to f
            close access f
            return "ok"
            """
            var error: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue
            var img: NSImage? = nil
            if result == "ok", let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty {
                img = NSImage(data: data)
            }
            DispatchQueue.main.async {
                if let img = img {
                    self?.currentArtwork = img
                    let tint = Self.dominantTint(of: img)
                    self?.artworkTint = tint
                }
                else if self?.currentArtwork != nil && result == "none" { self?.currentArtwork = nil }
            }
        }
    }
}
