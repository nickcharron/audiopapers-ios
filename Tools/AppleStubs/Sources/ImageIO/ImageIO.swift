import Foundation

public typealias CFString = String
public typealias CFURL = URL
public typealias CFDictionary = [AnyHashable: Any]
public typealias OSStatus = Int32
public let noErr: OSStatus = 0

public final class CGImage: @unchecked Sendable {
    public init() {}
    public var width: Int { 0 }
    public var height: Int { 0 }
    public func cropping(to rect: CGRect) -> CGImage? { nil }
}

public let kCGImageAnimationLoopCount: CFString = "loop"

public func CGAnimateImageAtURLWithBlock(_ url: CFURL, _ options: CFDictionary?, _ block: @escaping (Int, CGImage, UnsafeMutablePointer<Bool>) -> Void) -> OSStatus { 0 }
