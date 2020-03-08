//
//  KeychainStorage.swift
//  Swiftagram
//
//  Created by Stefano Bertagno on 07/03/2020.
//

import Foundation
import KeychainSwift

@frozen
/// A `struct` holding reference to all `Authentication.Response`s stored in the keychain.
/// - note: `
///     KeychainStorage` is the encoded and ready-to-use alternative to `UserDefaultsStorage`.
///     Add https://github.com/evgenyneu/keychain-swift to your dependencies and import it to start using it.
public struct KeychainStorage: Storage {
    /// A `String` identifying the `KeychainSwift` prefix. Defaults to `swiftagram`. Defaults to `swiftagram`.
    public let prefix: String
    /// A `Bool` identifying whether the `Authentication.Response`s should be synchronized through iCloud. Defaults to `false`.
    public let synchronizable: Bool
    /// A `KeychainSwift` used as storage. Defaults to `.init(keyPrefix: prefix)`.
    private let keychain: KeychainSwift

    // MARK: Lifecycle
    /// Init.
    /// - parameter prefix: A `KeychainSwift` prefix.
    public init(prefix: String = "swiftagram",
                synchronizable: Bool = false) {
        self.prefix = prefix
        self.synchronizable = synchronizable
        self.keychain = .init(keyPrefix: prefix)
        self.keychain.synchronizable = synchronizable
    }

    // MARK: Lookup
    /// Find an `Authentication.Response` stored in the keychain.
    /// - returns: A `Response` or `nil` if no response could be found.
    /// - note: Use `Authentication.Response.stored` to access it.
    public func find(matching identifier: String) -> Authentication.Response? {
        return keychain
            .getData(identifier)
            .flatMap { try? JSONDecoder().decode(Authentication.Response.self, from: $0) }
    }

    /// Return all `Authentication.Response`s stored in the `keychain`.
    /// - returns: An `Array` of `Authentication.Response`s stored in the `keychain`.
    public func all() -> [Authentication.Response] {
        return keychain.allKeys
            .compactMap { $0.starts(with: prefix) ? String($0[prefix.endIndex...]) : nil }
            .compactMap(find)
    }

    // MARK: Locker
    /// Store an `Authentication.Response` in the keychain.
    /// - note: Prefer `Authentication.Response.store` to access it.
    public func store(_ response: Authentication.Response) {
        // Store.
        guard let data = try? JSONEncoder().encode(response) else { return }
        keychain.set(data, forKey: response.id)
    }

    @discardableResult
    /// Delete an `Authentication.Response` in the keychain.
    /// - returns: The removed `Authentication.Response` or `nil` if none was found.
    public func remove(matching identifier: String) -> Authentication.Response? {
        guard let response = find(matching: identifier) else { return nil }
        keychain.delete(identifier)
        return response
    }
}
