@_exported import Foundation
@_exported import FoundationNetworking
@_exported import ImageIO

public final class UIImage: @unchecked Sendable {
    public init(cgImage: CGImage) {}
    public init?(contentsOfFile: String) {}
    public var cgImage: CGImage? { nil }
    public func pngData() -> Data? { nil }
}

public struct UILayoutPriority: Sendable { public static let defaultLow = UILayoutPriority() }
public enum NSLayoutConstraintAxis { case horizontal, vertical }

open class UIView {
    public init() {}
    public enum ContentMode { case scaleAspectFit }
    public var contentMode = ContentMode.scaleAspectFit
    public func setContentHuggingPriority(_ priority: UILayoutPriority, for axis: NSLayoutConstraintAxis) {}
    public func setContentCompressionResistancePriority(_ priority: UILayoutPriority, for axis: NSLayoutConstraintAxis) {}
}

public final class UIImageView: UIView {
    public var image: UIImage?
}

public final class UIColor: @unchecked Sendable {
    public static var tintColor: UIColor { UIColor() }
    public func withAlphaComponent(_ alpha: CGFloat) -> UIColor { self }
}

public final class UIFont: @unchecked Sendable {
    public enum TextStyle { case body }
    public static func preferredFont(forTextStyle: TextStyle) -> UIFont { UIFont() }
}

public final class UIPasteboard: @unchecked Sendable {
    public static let general = UIPasteboard()
    public var string: String?
}

public struct UIBackgroundTaskIdentifier: Equatable, Sendable { public static let invalid = UIBackgroundTaskIdentifier() }

@MainActor
public final class UIApplication {
    public static let shared = UIApplication()
    public func beginBackgroundTask(withName: String?, expirationHandler: (@MainActor @Sendable () -> Void)? = nil) -> UIBackgroundTaskIdentifier { .invalid }
    public func endBackgroundTask(_ task: UIBackgroundTaskIdentifier) {}
}

public protocol UIApplicationDelegate: AnyObject {}

public final class NSTextStorage {
    public init(string: String, attributes: [NSAttributedStringKey: Any]) {}
    public func addLayoutManager(_ layout: NSLayoutManager) {}
}

public struct NSAttributedStringKey: Hashable, Sendable { public static let font = NSAttributedStringKey() }

public final class NSTextContainer {
    public init(size: CGSize) {}
    public var lineFragmentPadding: CGFloat = 0
}

public final class NSLayoutManager {
    public init() {}
    public func addTextContainer(_ container: NSTextContainer) {}
    public var numberOfGlyphs: Int { 0 }
    public func glyphIndexForCharacter(at: Int) -> Int { 0 }
    public func lineFragmentRect(forGlyphAt: Int, effectiveRange: UnsafeMutablePointer<NSRange>?) -> CGRect { .zero }
}

public extension URL {
    func startAccessingSecurityScopedResource() -> Bool { true }
    func stopAccessingSecurityScopedResource() {}
}
