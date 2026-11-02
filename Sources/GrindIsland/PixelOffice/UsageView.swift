import SwiftUI

/// Claude Code token use, from its local transcripts: today, the last 14 days, busiest projects and models.
struct UsageView: View {
    @ObservedObject private var stats = UsageStats.shared
    private let tint = Color(red: 0.85, green: 0.62, blue: 0.45)

    var body: some View {
        let s = stats.summary
        HStack(alignment: .top, spacing: 14) {
            // Today
            VStack(alignment: .leading, spacing: 3) {
                Text("今天").font(.system(size: 9.5, weight: .semibold)).foregroundColor(tint)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(UsageStats.short(s.todayTokens)).font(.system(size: 24, weight: .semibold, design: .rounded))
                        .monospacedDigit().foregroundColor(.white).contentTransition(.numericText())
                        .animation(.snappy, value: s.todayTokens)
                    Text("tokens").font(.system(size: 9.5)).foregroundColor(.white.opacity(0.5))
                }
                .lineLimit(1).minimumScaleFactor(0.6)
                Text("輸出 \(UsageStats.short(s.todayOutput))・\(s.todayReplies) 次回覆")
                    .font(.system(size: 9.5)).monospacedDigit().foregroundColor(.white.opacity(0.55)).lineLimit(1)
                Text(s.streak > 0 ? "連續 \(s.streak) 天" : "今天還沒用")
                    .font(.system(size: 9.5)).foregroundColor(.white.opacity(0.55))
                bars(s.hoursToday, highlight: Calendar.current.component(.hour, from: Date()), height: 22)
                    .padding(.top, 2)
                Text("今天各時段").font(.system(size: 8.5)).foregroundColor(.white.opacity(0.35))
            }
            .frame(width: 150, alignment: .leading)

            // Last 14 days
            VStack(alignment: .leading, spacing: 3) {
                Text("近 14 天").font(.system(size: 9.5, weight: .semibold)).foregroundColor(tint)
                bars(s.perDay, highlight: s.perDay.count - 1, height: 70)
                HStack {
                    Text("14 天前"); Spacer(); Text("今天")
                }
                .font(.system(size: 8.5)).foregroundColor(.white.opacity(0.35))
            }
            .frame(maxWidth: .infinity)

            // Top projects / models, last 7 days
            VStack(alignment: .leading, spacing: 3) {
                Text("近 7 天最多").font(.system(size: 9.5, weight: .semibold)).foregroundColor(tint)
                let top = max(1, s.topProjects.first?.tokens ?? 1)
                ForEach(s.topProjects, id: \.name) { p in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(p.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(UsageStats.short(p.tokens)).monospacedDigit().foregroundColor(.white.opacity(0.5))
                        }
                        .font(.system(size: 9.5)).foregroundColor(.white.opacity(0.85))
                        GeometryReader { g in
                            Capsule().fill(tint.opacity(0.75)).frame(width: max(3, g.size.width * CGFloat(p.tokens) / CGFloat(top)))
                        }
                        .frame(height: 3)
                    }
                }
                if let m = s.topModels.first {
                    Text("主要模型 \(m.name)").font(.system(size: 8.5)).foregroundColor(.white.opacity(0.4)).lineLimit(1)
                        .padding(.top, 2)
                }
                if s.topProjects.isEmpty {
                    Text(stats.loading ? "讀取中…" : "沒有紀錄").font(.system(size: 9.5)).foregroundColor(.white.opacity(0.45))
                }
            }
            .frame(width: 150, alignment: .leading)
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { stats.watch() }
        .onDisappear { stats.unwatch() }
    }

    private func bars(_ values: [Int], highlight: Int, height: CGFloat) -> some View {
        let top = CGFloat(max(1, values.max() ?? 1))
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i == highlight ? tint : tint.opacity(0.35))
                    .frame(height: max(2, height * CGFloat(v) / top))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height, alignment: .bottom)
        .animation(.easeInOut(duration: 0.4), value: values)
    }
}
