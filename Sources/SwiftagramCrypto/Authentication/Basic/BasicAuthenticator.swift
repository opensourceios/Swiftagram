//
//  BasicAuthenticator.swift
//  SwiftagramCrypto
//
//  Created by Stefano Bertagno on 07/03/2020.
//

import Foundation

import ComposableRequest
import SwCrypt
import Swiftagram

/**
    A `class` describing an `Authenticator` using `username` and `password`.
 
    ## Usage
    ```swift
    /// A strong reference to a 2FA object.
    var twoFactor: TwoFactor? {
      didSet {
        guard let twoFactor = twoFactor else { return }
        // ask for the code and then pass it to `twoFactor.send`.
      }
    }
 
    /// Login.
    BasicAuthenticator(storage: KeychainStorage(),  // any `Storage`.
                       username: /* the username */,
                       password: /* the password */)
      .authenticate {
        switch $0 {
        case .failure(let error):
          switch error {
            case BasicAuthenticatorError.twoFactor(let response): twoFactor = response
            default: print(error)
          }
        case .success: print("Logged in")
      }
    ```
 */
public final class BasicAuthenticator<Storage: Swiftagram.Storage>: Authenticator {
    public typealias Error = Swift.Error

    /// A `Storage` instance used to store `Secret`s.
    public internal(set) var storage: Storage
    /// A `String` holding a valid username.
    public internal(set) var username: String
    /// A `String` holding a valid password.
    public internal(set) var password: String

    /// A `String` holding a custom user agent to be passed to every request.
    /// Defaults to Safari on an iPhone with iOS 13.1.3.
    internal var userAgent: String = ["Mozilla/5.0 (iPhone; CPU iPhone OS 13_1_3 like Mac OS X)",
                                      "AppleWebKit/605.1.15 (KHTML, like Gecko)",
                                      "Version/13.0.1 Mobile/15E148 Safari/604.1"].joined(separator: " ")

    // MARK: Lifecycle
    /// Init.
    /// - parameters:
    ///     - storage: A concrete `Storage` value.
    ///     - username: A `String` representing a valid username.
    ///     - password: A `String` representing a valid password.
    public init(storage: Storage, username: String, password: String) {
        self.storage = storage
        self.username = username
        self.password = password
    }

    // MARK: Static
    /// Encrypt `password`.
    private static func encrypt(password: String, with header: [String: String]) -> Result<String, Error> {
        guard CC.RSA.available(), CC.GCM.available() else {
            return .failure(SigningError.cryptographyUnavailable)
        }
        guard let passwordKeyId = header["ig-set-password-encryption-key-id"].flatMap(UInt8.init),
            let passwordPublicKey = header["ig-set-password-encryption-pub-key"]
                .flatMap({ Data(base64Encoded: $0) })
                .flatMap({ String(data: $0, encoding: .utf8) }) else { return .failure(SigningError.invalidRepresentation) }
        // Encrypt.
        let randomKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let iv = Data((0..<12).map { _ in UInt8.random(in: 0...255) })
        let time = "\(Int(Date().timeIntervalSince1970))"
        do {
            // AES-GCM-256.
            let (aesEncrypted, authenticationTag) = try CC.GCM.crypt(.encrypt,
                                                                     algorithm: .aes,
                                                                     data: password.data(using: .utf8)!,
                                                                     key: randomKey,
                                                                     iv: iv,
                                                                     aData: time.data(using: .utf8)!,
                                                                     tagLength: 16)
            // RSA.
            let publicKey = try SwKeyConvert.PublicKey.pemToPKCS1DER(passwordPublicKey)
            let rsaEncrypted = try CC.RSA.encrypt(randomKey,
                                                  derKey: publicKey,
                                                  tag: .init(),
                                                  padding: .pkcs1,
                                                  digest: .none)
            var rsaEncryptedLELength = UInt16(littleEndian: UInt16(rsaEncrypted.count))
            let rsaEncryptedLength = Data(bytes: &rsaEncryptedLELength, count: MemoryLayout<UInt16>.size)
            // Compute `enc_password`.
            var data = Data()
            data.append(1)
            data.append(passwordKeyId)
            data.append(iv)
            data.append(rsaEncryptedLength)
            data.append(rsaEncrypted)
            data.append(authenticationTag)
            data.append(aesEncrypted)
            return .success("#PWD_INSTAGRAM:4:\(time):\(data.base64EncodedString())")
        } catch {
            return .failure(error)
        }
    }

    // MARK: Authenticator
    /// Return a `Secret` and store it in `storage`.
    /// - parameter onChange: A block providing a `Secret`.
    public func authenticate(_ onChange: @escaping (Result<Secret, Error>) -> Void) {
        // Update cookies.
        header { [self] in
            switch $0 {
            case .failure(let error): onChange(.failure(error))
            case .success(let cookies):
                self.encryptedPassword(with: cookies) {
                    switch $0 {
                    case .failure(let error): onChange(.failure(error))
                    case .success(let password):
                        self.authenticate(with: password,
                                          cookies: cookies,
                                          onChange: onChange)
                    }
                }
            }
        }
    }

    // MARK: Shared flow
    /// Pre-login flow.
    private func header(onComplete: @escaping (Result<[HTTPCookie], Error>) -> Void) {
        // Obtain cookies.
        Endpoint.version1.accounts.read_msisdn_header.appending(path: "/")
            .appendingDefaultHeader()
            .appending(header: "X-DEVICE-ID", with: Device.default.deviceGUID.uuidString)
            .signing(body: ["mobile_subno_usage": "default",
                            "device_id": Device.default.deviceGUID.uuidString])
            .prepare()
            .debugTask(by: .authentication) {
                guard let header = $0.response?.allHeaderFields as? [String: String] else {
                    return onComplete(.failure(BasicAuthenticatorError.invalidResponse))
                }
                // Get cookies.
                let cookies = HTTPCookie.cookies(withResponseHeaderFields: header,
                                                 for: URL(string: ".instagram.com")!)
                onComplete(.success(cookies))
            }
            .resume()
    }

    /// Fetch password public key and encrypt password.
    private func encryptedPassword(with cookies: [HTTPCookie], onComplete: @escaping (Result<String, Error>) -> Void) {
        // Obtain password key.
        Endpoint.version1.qe.sync.appending(path: "/")
            .appendingDefaultHeader()
            .appending(header: "X-DEVICE-ID", with: Device.default.deviceGUID.uuidString)
            .appending(header: HTTPCookie.requestHeaderFields(with: cookies))
            .signing(body: ["id": Device.default.deviceGUID.uuidString,
                            "experiments": Constants.loginExperiments])
            .prepare()
            .debugTask(by: .authentication) { [self] in
                guard let response = $0.response else {
                    return onComplete(.failure(BasicAuthenticatorError.invalidResponse))
                }
                switch $0.value {
                case .failure(let error): onComplete(.failure(error))
                case .success(let value) where value.status.string() == "ok":
                    // Process headers and handle encryption.
                    guard let header = response.allHeaderFields as? [String: String] else {
                        return onComplete(.failure(BasicAuthenticatorError.invalidCookies))
                    }
                    onComplete(BasicAuthenticator<Storage>.encrypt(password: self.password, with: header))
                default: onComplete(.failure(BasicAuthenticatorError.invalidResponse))
                }
            }
            .resume()
    }

    /// Request authentication.
    private func authenticate(with encryptedPassword: String,
                              cookies: [HTTPCookie],
                              onChange: @escaping (Result<Secret, Error>) -> Void) {
        // Check for cross site request forgery token.
        guard let crossSiteRequestForgery = cookies.first(where: { $0.name == "csrftoken" }) else {
            return onChange(.failure(BasicAuthenticatorError.invalidCookies))
        }
        // Obtain the `ds_user_id` and the `sessionid`.
        Endpoint.version1.accounts.login.appending(path: "/")
            .appendingDefaultHeader()
            .appending(header: HTTPCookie.requestHeaderFields(with: cookies))
            .appending(header: "X-Csrf-Token", with: crossSiteRequestForgery.value)
            .signing(body: [
                "username": self.username,
                "enc_password": encryptedPassword,
                "guid": Device.default.deviceGUID.uuidString,
                "phone_id": Device.default.phoneGUID.uuidString,
                "device_id": Device.default.deviceIdentifier,
                "adid": "",
                "google_tokens": "[]",
                "country_codes": #"[{"country_code":"1","source": "default"}]"#,
                "login_attempt_count": "0",
                "jazoest": "2\(Device.default.phoneGUID.uuidString.data(using: .ascii)!.reduce(0) { $0+Int($1) })"
            ])
            .prepare()
            .debugTask(by: .authentication) { [self] in
                self.process(result: $0,
                             crossSiteRequestForgery: crossSiteRequestForgery,
                             onChange: onChange)
            }
            .resume()
    }

    /// Handle `ds_user_id` and `sessionid` response.
    private func process(result: Requester.Task.Response<Response>,
                         crossSiteRequestForgery: HTTPCookie,
                         onChange: @escaping (Result<Secret, Error>) -> Void) {
        switch result.value {
        case .failure(let error): onChange(.failure(error))
        case .success(let value):
            // Wait for two factor authentication.
            if let twoFactorIdentifier = value.twoFactorInfo.twoFactorIdentifier.string() {
                onChange(.failure(BasicAuthenticatorError.twoFactor(.init(storage: storage,
                                                                          username: username,
                                                                          identifier: twoFactorIdentifier,
                                                                          crossSiteRequestForgery: crossSiteRequestForgery,
                                                                          onChange: onChange))))
            }
            // Check for errors.
            else if let error = value.errorType.string() {
                switch error {
                case "bad_password": onChange(.failure(BasicAuthenticatorError.invalidPassword))
                case "invalid_user": onChange(.failure(BasicAuthenticatorError.invalidUsername))
                default: onChange(.failure(BasicAuthenticatorError.custom(error)))
                }
            }
            // Check for `loggedInUser`.
            else if value.loggedInUser.pk.int() != nil,
                let url = URL(string: "https://instagram.com"),
                let secret = Secret(cookies: HTTPCookie.cookies(
                    withResponseHeaderFields: result.response?.allHeaderFields as? [String: String] ?? [:],
                    for: url
                ), device: .default) {
                onChange(.success(secret))
            }
            // Return a generic error.
            else { onChange(.failure(BasicAuthenticatorError.invalidResponse)) }
        }
    }

    /*private func process(result: Result<Response, Error>,
                         crossSiteRequestForgery: HTTPCookie,
                         onChange: @escaping (Result<Secret, Error>) -> Void) {
        switch result {
        case .failure(let error): onChange(.failure(error))
        case .success(let value):
            // Check for authentication.
            if let checkpoint = value.checkpointUrl.string() {
                // Handle the checkpoint.
                handleCheckpoint(checkpoint: checkpoint,
                                 crossSiteRequestForgery: crossSiteRequestForgery,
                                 onChange: onChange)
            } else if let twoFactorIdentifier = value.twoFactorInfo.twoFactorIdentifier.string() {
                // Handle 2FA.
                onChange(.failure(BasicAuthenticatorError.twoFactor(.init(storage: storage,
                                                                     username: username,
                                                                     identifier: twoFactorIdentifier,
                                                                     userAgent: Device.default.browserUserAgent,
                                                                     crossSiteRequestForgery: crossSiteRequestForgery,
                                                                     onChange: onChange))))
            } else if value.user.bool().flatMap({ !$0 }) ?? false {
                // User not found.
                onChange(.failure(BasicAuthenticatorError.invalidUsername))
            } else if value.authenticated.bool() ?? false {
                // User authenticated successfuly.
                let instagramCookies = HTTPCookieStorage.shared.cookies?
                    .filter { $0.domain.contains(".instagram.com") }
                    .sorted { $0.name < $1.name } ?? []
                guard instagramCookies.count >= 2 else {
                    return onChange(.failure(BasicAuthenticatorError.invalidCookies))
                }
                // Complete.
                let cookies = Secret.hasValidCookies(instagramCookies)
                    ? instagramCookies
                    : instagramCookies+[crossSiteRequestForgery]
                onChange(Secret(cookies: cookies).flatMap { .success($0.store(in: self.storage)) }
                    ?? .failure(Secret.Error.invalidCookie))
            } else if value.authenticated.bool().flatMap({ !$0 }) ?? false {
                // User not authenticated.
                onChange(.failure(BasicAuthenticatorError.invalidPassword))
            } else {
                onChange(.failure(BasicAuthenticatorError.invalidResponse))
            }
        }
    }

    // MARK: Checkpoint flow
    /// Handle checkpoint.
    internal func handleCheckpoint(checkpoint: String,
                                   crossSiteRequestForgery: HTTPCookie,
                                   onChange: @escaping (Result<Secret, Error>) -> Void) {
        // Get checkpoint info.
        Endpoint.generic.appending(path: checkpoint)
            .replacing(header: ["User-Agent": userAgent])
            .prepare { $0.map { String(data: $0, encoding: .utf8) ?? "" }}
            .debugTask(by: .authentication) { [self] in
                // Check for errors.
                switch $0.value {
                case .failure(let error): onChange(.failure(error))
                case .success(let value):
                    // Notify checkpoint was reached.
                    guard let url = $0.response?.url,
                        value.contains("window._sharedData = ") else {
                            return onChange(.failure(BasicAuthenticatorError.checkpoint(nil)))
                    }
                    guard let data = value
                        .components(separatedBy: "window._sharedData = ")[1]
                        .components(separatedBy: ";</script>")[0]
                        .data(using: .utf8),
                        let response = try? JSONDecoder().decode(Response.self, from: data) else {
                            return onChange(.failure(BasicAuthenticatorError.checkpoint(nil)))
                    }
                    // Obtain available verification.
                    guard let verification = response
                        .entryData.challenge.array()?.first?
                        .extraData.content.array()?.last?
                        .fields.array()?.first?
                        .values.array()?
                        .compactMap(Verification.init) else {
                            return onChange(.failure(BasicAuthenticatorError.checkpoint(nil)))
                    }
                    onChange(.failure(BasicAuthenticatorError.checkpoint(Checkpoint(storage: self.storage,
                                                                               url: url,
                                                                               userAgent: Device.default.browserUserAgent,
                                                                               crossSiteRequestForgery: crossSiteRequestForgery,
                                                                               availableVerification: Set(verification),
                                                                               onChange: onChange))))
                }
            }
            .resume()
    }*/
}

/// Extend for `TransientStorage`.
public extension BasicAuthenticator where Storage == TransientStorage {
    // MARK: Lifecycle
    /// Init.
    /// - parameters:
    ///     - username: A `String` representing a valid username.
    ///     - password: A `String` representing a valid password.
    convenience init(username: String, password: String) {
        self.init(storage: .init(), username: username, password: password)
    }
}
