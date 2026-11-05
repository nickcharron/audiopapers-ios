import Foundation
@_exported import ImageIO

public let kSecClass: CFString = ""
public let kSecClassGenericPassword: CFString = ""
public let kSecAttrService: CFString = ""
public let kSecAttrAccount: CFString = ""
public let kSecReturnData: CFString = ""
public let kSecMatchLimit: CFString = ""
public let kSecMatchLimitOne: CFString = ""
public let kSecValueData: CFString = ""
public let kSecAttrAccessible: CFString = ""
public let kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly: CFString = ""
public let errSecSuccess: OSStatus = 0

public func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus { 0 }
public func SecItemDelete(_ query: CFDictionary) -> OSStatus { 0 }
public func SecItemAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus { 0 }
