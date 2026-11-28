import SwiftUI
import WidgetKit
import ActivityKit

@available(iOS 16.1, *)
private func formatETA(_ seconds: Int) -> String {
    if seconds < 0 { return "Calculating..." }
    if seconds == 0 { return "Done" }
    let mins = seconds / 60
    let secs = seconds % 60
    if mins > 0 {
        return String(format: "%dm %02ds left", mins, secs)
    }
    return String(format: "%ds left", secs)
}

@available(iOS 16.1, *)
private struct AMProgressRingView: View {
    let progress: Double
    let lineWidth: CGFloat

    private let accentColor = Color(red: 0.255, green: 0.855, blue: 0.620)
    private let trackColor = Color.white.opacity(0.18)

    var body: some View {
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(max(0.0, min(1.0, progress))))
                .stroke(accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

@available(iOS 16.1, *)
struct AMExportLiveActivityWidget: Widget {
    private let bgColor = Color(red: 0.141, green: 0.149, blue: 0.212)
    private let accentColor = Color(red: 0.255, green: 0.855, blue: 0.620)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AMExportActivityAttributes.self) { context in
            let pct = Int(round(max(0.0, min(1.0, context.state.progress)) * 100.0))
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ZStack {
                        AMProgressRingView(progress: context.state.progress, lineWidth: 4)
                            .frame(width: 34, height: 34)
                        Text("\(pct)%")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.projectName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(context.state.status)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.75))
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(formatETA(context.state.etaSeconds))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(accentColor)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.16))
                            .frame(height: 6)
                        Capsule()
                            .fill(accentColor)
                            .frame(width: geo.size.width * CGFloat(max(0.0, min(1.0, context.state.progress))), height: 6)
                    }
                }
                .frame(height: 6)
            }
            .padding(14)
            .activityBackgroundTint(bgColor)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let pct = Int(round(max(0.0, min(1.0, context.state.progress)) * 100.0))
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        AMProgressRingView(progress: context.state.progress, lineWidth: 3)
                            .frame(width: 22, height: 22)
                        Text("\(pct)%")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(formatETA(context.state.etaSeconds))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(accentColor)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.projectName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.status)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.78))
                            .lineLimit(1)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.18))
                                    .frame(height: 5)
                                Capsule()
                                    .fill(accentColor)
                                    .frame(width: geo.size.width * CGFloat(max(0.0, min(1.0, context.state.progress))), height: 5)
                            }
                        }
                        .frame(height: 5)
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                AMProgressRingView(progress: context.state.progress, lineWidth: 2.5)
                    .frame(width: 16, height: 16)
            } compactTrailing: {
                Text("\(pct)%")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(accentColor)
            } minimal: {
                AMProgressRingView(progress: context.state.progress, lineWidth: 2.5)
                    .frame(width: 16, height: 16)
            }
        }
    }
}

@main
@available(iOS 16.1, *)
struct AMExportWidgetBundle: WidgetBundle {
    var body: some Widget {
        AMExportLiveActivityWidget()
    }
}
