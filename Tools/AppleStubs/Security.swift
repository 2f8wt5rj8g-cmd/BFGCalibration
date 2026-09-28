// Type-checking stub for the Security framework. See Tools/typecheck-ios.sh.
import Foundation

public typealias OSStatus = Int32
public typealias CFDictionary = [String: Any]
public typealias CFTypeRef = Any

public let kSecRandomDefault: Int = 0
public func SecRandomCopyBytes(_ rnd: Int, _ count: Int,
                               _ bytes: UnsafeMutableRawPointer) -> Int32 { 0 }

public let kSecClass = "class"
public let kSecClassGenericPassword = "genp"
public let kSecAttrService = "svce"
public let kSecAttrAccount = "acct"
public let kSecValueData = "v_Data"
public let kSecAttrAccessible = "pdmn"
public let kSecAttrAccessibleWhenUnlockedThisDeviceOnly = "cku"
public let kSecReturnData = "r_Data"
public let kSecMatchLimit = "m_Limit"
public let kSecMatchLimitOne = "m_LimitOne"

public let errSecSuccess: OSStatus = 0

public func SecItemAdd(_ attributes: CFDictionary,
                       _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { 0 }
public func SecItemCopyMatching(_ query: CFDictionary,
                                _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { 0 }
public func SecItemDelete(_ query: CFDictionary) -> OSStatus { 0 }
