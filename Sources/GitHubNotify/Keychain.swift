import Foundation
import Security
import CryptoKit
import Darwin

struct TokenStore {
    private let legacyService: String

    init(legacyService: String = "com.koltyakov.github-notify") {
        self.legacyService = legacyService
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: legacyService,
         kSecAttrAccount as String: "github-token"]
    }

    func load() throws -> String {
        if let certificate = try signingCertificate() {
            let response = try helperRequest(operation: "load", certificate: certificate)
            if response.status == errSecItemNotFound { return "" }
            guard response.status == errSecSuccess else { throw KeychainError(status: response.status) }
            guard let token = response.token else { throw CredentialHelperError.invalidResponse }
            return token
        }
        // Preserve bare/ad-hoc executable support. These builds cannot securely
        // authenticate the helper and do not have stable Keychain access across updates.
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode)
        }
        return token
    }

    func save(_ token: String) throws {
        if let certificate = try signingCertificate() {
            let response = try helperRequest(operation: "save", token: token, certificate: certificate)
            guard response.status == errSecSuccess else { throw KeychainError(status: response.status) }
            return
        }
        if token.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status)
            }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private struct HelperRequest: Encodable {
        let operation: String
        let token: String?
    }

    private struct HelperResponse: Decodable {
        let status: OSStatus
        let token: String?
    }

    private func signingCertificate() throws -> Data? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        var status = SecCodeCopySelf([], &code)
        guard status == errSecSuccess, let code else { throw CredentialHelperError.invalidSignature }
        status = SecCodeCopyStaticCode(code, [], &staticCode)
        guard status == errSecSuccess, let staticCode else { throw CredentialHelperError.invalidSignature }
        status = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard status == errSecSuccess, let information = information as? [String: Any] else {
            throw CredentialHelperError.invalidSignature
        }
        guard let certificate = (information[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first else { return nil }
        return SecCertificateCopyData(certificate) as Data
    }

    private func helperRequest(operation: String, token: String? = nil, certificate: Data) throws -> HelperResponse {
        guard (token?.utf8.count ?? 0) <= 4096 else { throw CredentialHelperError.invalidRequest }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/github-notify-credentials")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw CredentialHelperError.missing }

        // Verify the helper before sending it any credential, just as it verifies
        // its parent before reading Keychain. Never trust a path or bundle ID alone.
        let fingerprint = Insecure.SHA1.hash(data: certificate).map { String(format: "%02x", $0) }.joined()
        let rule = "identifier \"com.koltyakov.github-notify.credentials\" and certificate leaf = H\"\(fingerprint)\""
        var requirement: SecRequirement?
        var helperCode: SecStaticCode?
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCreateWithPath(helper as CFURL, [], &helperCode) == errSecSuccess,
              let helperCode,
              SecStaticCodeCheckValidity(helperCode, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw CredentialHelperError.invalidSignature
        }

        let input = try JSONEncoder().encode(HelperRequest(operation: operation, token: token))
        guard input.count <= 8192 else { throw CredentialHelperError.invalidRequest }
        let process = Process()
        let request = Pipe()
        let response = Pipe()
        process.executableURL = helper
        process.standardInput = request
        process.standardOutput = response
        process.standardError = FileHandle.nullDevice
        // A rejected caller may make the helper exit before its stdin is written.
        guard fcntl(request.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw CredentialHelperError.unavailable
        }
        try process.run()
        // Verify the running child as well, closing the path-replacement race
        // between checking the on-disk helper and starting it.
        var child: SecCode?
        let attributes = [kSecGuestAttributePid as String: process.processIdentifier] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &child) == errSecSuccess,
              let child,
              SecCodeCheckValidity(child, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            try? request.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw CredentialHelperError.invalidSignature
        }
        do {
            try request.fileHandleForWriting.write(contentsOf: input)
            try request.fileHandleForWriting.close()
        } catch {
            try? request.fileHandleForWriting.close()
            process.waitUntilExit()
            throw CredentialHelperError.unavailable
        }
        let output = try response.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        guard let decoded = try? JSONDecoder().decode(HelperResponse.self, from: output) else {
            throw CredentialHelperError.invalidResponse
        }
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 || decoded.status != errSecSuccess else {
            throw CredentialHelperError.unavailable
        }
        return decoded
    }
}

private enum CredentialHelperError: LocalizedError {
    case missing, invalidSignature, invalidRequest, invalidResponse, unavailable

    var errorDescription: String? {
        switch self {
        case .missing: return "The credential helper is missing. Rebuild and install the app with make install."
        case .invalidSignature: return "The credential helper could not be authenticated. Rebuild using the configured signing identity."
        case .invalidRequest: return "The GitHub token is too long."
        case .invalidResponse, .unavailable: return "The credential helper could not complete the Keychain request."
        }
    }
}

private struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            return "Keychain access needs authorization. Unlock the login Keychain in Keychain Access, then save the token again in Settings."
        }
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Error \(status)"
        return "Cannot access the GitHub token in Keychain. \(message)"
    }
}
