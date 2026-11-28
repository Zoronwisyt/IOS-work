import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

@objc(AMLiveActivityBridge)
public final class AMLiveActivityBridge: NSObject {
    @objc public static let shared = AMLiveActivityBridge()

    private var lastUpdateTime: TimeInterval = 0
    private var currentActivityId: String?

    private override init() {
        super.init()
    }

    @objc public func isSupported() -> Bool {
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            return ActivityAuthorizationInfo().areActivitiesEnabled
        }
        #endif
        return false
    }

    @objc public func start(title: String) {
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let projectName = cleanTitle.isEmpty ? "Alight Motion Project" : cleanTitle

            // End any stale export activities first
            for existing in Activity<AMExportActivityAttributes>.activities {
                let staleState = AMExportActivityAttributes.ContentState(progress: 0.0, etaSeconds: -1, status: "Replaced")
                Task {
                    if #available(iOS 16.2, *) {
                        await existing.end(ActivityContent(state: staleState, staleDate: nil), dismissalPolicy: .immediate)
                    } else {
                        await existing.end(using: staleState, dismissalPolicy: .immediate)
                    }
                }
            }

            let attributes = AMExportActivityAttributes(projectName: projectName)
            let initialState = AMExportActivityAttributes.ContentState(
                progress: 0.0,
                etaSeconds: -1,
                status: "Exporting"
            )
            do {
                let activity: Activity<AMExportActivityAttributes>
                if #available(iOS 16.2, *) {
                    let content = ActivityContent(state: initialState, staleDate: Date().addingTimeInterval(120))
                    activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
                } else {
                    activity = try Activity<AMExportActivityAttributes>.request(
                        attributes: attributes,
                        contentState: initialState,
                        pushType: nil
                    )
                }
                self.currentActivityId = activity.id
                self.lastUpdateTime = Date().timeIntervalSince1970
            } catch {
                NSLog("[AMLiveActivityBridge] start failed: %@", error.localizedDescription)
            }
        }
        #endif
    }

    @objc public func update(progress: Double, etaSeconds: Int, status: String) {
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            let now = Date().timeIntervalSince1970
            let clamped = max(0.0, min(1.0, progress))
            // Throttle updates to <= 1/s unless reaching 100%
            if clamped < 0.999 && (now - self.lastUpdateTime) < 1.0 {
                return
            }
            self.lastUpdateTime = now

            let state = AMExportActivityAttributes.ContentState(
                progress: clamped,
                etaSeconds: etaSeconds,
                status: status.isEmpty ? "Exporting" : status
            )
            let activities = Activity<AMExportActivityAttributes>.activities
            let target = activities.first(where: { $0.id == self.currentActivityId }) ?? activities.first
            guard let activity = target else { return }

            Task {
                if #available(iOS 16.2, *) {
                    let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(120))
                    await activity.update(content)
                } else {
                    await activity.update(using: state)
                }
            }
        }
        #endif
    }

    @objc public func end(progress: Double, status: String, immediate: Bool) {
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            let clamped = max(0.0, min(1.0, progress))
            let finalState = AMExportActivityAttributes.ContentState(
                progress: clamped,
                etaSeconds: 0,
                status: status.isEmpty ? "Done" : status
            )
            let policy: ActivityUIDismissalPolicy = immediate ? .immediate : .after(Date().addingTimeInterval(8.0))
            let activities = Activity<AMExportActivityAttributes>.activities
            self.currentActivityId = nil
            for activity in activities {
                Task {
                    if #available(iOS 16.2, *) {
                        let content = ActivityContent(state: finalState, staleDate: nil)
                        await activity.end(content, dismissalPolicy: policy)
                    } else {
                        await activity.end(using: finalState, dismissalPolicy: policy)
                    }
                }
            }
        }
        #endif
    }
}
