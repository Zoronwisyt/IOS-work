import Foundation
#if canImport(ActivityKit)
import ActivityKit

@available(iOS 16.1, *)
public struct AMExportActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var progress: Double
        public var etaSeconds: Int
        public var status: String

        public init(progress: Double, etaSeconds: Int, status: String) {
            self.progress = progress
            self.etaSeconds = etaSeconds
            self.status = status
        }
    }

    public var projectName: String

    public init(projectName: String) {
        self.projectName = projectName
    }
}
#endif
