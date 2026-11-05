import Foundation

public class BGTask: @unchecked Sendable {
    public var expirationHandler: (() -> Void)?
    public func setTaskCompleted(success: Bool) {}
}

public final class BGContinuedProcessingTask: BGTask, @unchecked Sendable {
    public let progress = Progress(totalUnitCount: 0)
}

public class BGTaskRequest {}

public final class BGContinuedProcessingTaskRequest: BGTaskRequest {
    public enum SubmissionStrategy { case fail, queue }
    public var strategy = SubmissionStrategy.queue
    public init(identifier: String, title: String, subtitle: String) {}
}

public final class BGTaskScheduler: @unchecked Sendable {
    public static let shared = BGTaskScheduler()
    public func register(forTaskWithIdentifier identifier: String, using queue: DispatchQueue?, launchHandler: @escaping (BGTask) -> Void) -> Bool { true }
    public func submit(_ request: BGTaskRequest) throws {}
}
