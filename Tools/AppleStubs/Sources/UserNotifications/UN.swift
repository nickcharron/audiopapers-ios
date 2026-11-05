import Foundation

public struct UNAuthorizationOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let alert = UNAuthorizationOptions(rawValue: 1)
    public static let sound = UNAuthorizationOptions(rawValue: 2)
}

public final class UNMutableNotificationContent {
    public init() {}
    public var title = ""
    public var body = ""
}

public final class UNNotificationTrigger {}

public final class UNNotificationRequest {
    public init(identifier: String, content: UNMutableNotificationContent, trigger: UNNotificationTrigger?) {}
}

public final class UNUserNotificationCenter: @unchecked Sendable {
    public static func current() -> UNUserNotificationCenter { UNUserNotificationCenter() }
    public func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }
    public func add(_ request: UNNotificationRequest, withCompletionHandler: ((Error?) -> Void)? = nil) {}
}
