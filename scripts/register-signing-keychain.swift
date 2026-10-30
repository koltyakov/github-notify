import Foundation
import Security

// codesign needs the identity's Keychain on the search list even with --keychain.
// Preserve every existing entry and never change the default/login Keychain.
func check(_ status: OSStatus) throws {
    guard status == errSecSuccess else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)",
        ])
    }
}

do {
    guard CommandLine.arguments.count == 2 else {
        throw NSError(domain: "GitHubNotify.Signing", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Usage: swift scripts/register-signing-keychain.swift <signing keychain>",
        ])
    }
    var signing: SecKeychain?
    try check(SecKeychainOpen(CommandLine.arguments[1], &signing))
    var searchList: CFArray?
    try check(SecKeychainCopySearchList(&searchList))
    guard let signing, let existing = searchList as? [SecKeychain] else {
        throw NSError(domain: "GitHubNotify.Signing", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Cannot read the existing Keychain search list. No entries were changed.",
        ])
    }
    if !existing.contains(where: { CFEqual($0, signing) }) {
        try check(SecKeychainSetSearchList((existing + [signing]) as CFArray))
    }
} catch {
    FileHandle.standardError.write(Data("Cannot register the signing Keychain: \(error.localizedDescription)\n".utf8))
    exit(1)
}
