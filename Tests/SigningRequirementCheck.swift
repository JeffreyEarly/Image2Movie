import Foundation
import Security

// Compile with MCPPeerIdentity.swift and -lbsm. Arguments: an Early Innovations-signed
// Image2Movie.app, an installed Mac App Store app, and an ad-hoc-signed executable.
// This reads signatures only; it never launches or changes the supplied code.
@main
struct SigningRequirementCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else {
            throw Failure.failed("Expected signed app, App Store app, and ad-hoc executable paths")
        }
        func code(at path: String) throws -> SecStaticCode {
            var result: SecStaticCode?
            let status = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &result)
            guard status == errSecSuccess, let result else {
                throw Failure.failed("Cannot read signed code at \(path): \(status)")
            }
            return result
        }
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure.failed(message) }
            print("PASS: \(message)")
        }

        let app = try code(at: CommandLine.arguments[1])
        let helperURL = MCPPeerIdentity.bridgeExecutableURL(in:
            URL(fileURLWithPath: CommandLine.arguments[1]))
        let helper = try code(at: helperURL.path)
        let store = try code(at: CommandLine.arguments[2])
        let adHoc = try code(at: CommandLine.arguments[3])
        let appRequirement = try MCPPeerIdentity.requirement(for: MCPPeerIdentity.appIdentifier)
        let helperRequirement = try MCPPeerIdentity.requirement(for: MCPPeerIdentity.bridgeIdentifier)
        try check(SecStaticCodeCheckValidity(app, [], appRequirement) == errSecSuccess,
                  "Early Innovations app accepted")
        try check(SecStaticCodeCheckValidity(helper, [], helperRequirement) == errSecSuccess,
                  "Early Innovations helper accepted")
        try check(SecStaticCodeCheckValidity(app, [], helperRequirement) != errSecSuccess,
                  "App cannot impersonate its helper")
        try check(SecStaticCodeCheckValidity(helper, [], appRequirement) != errSecSuccess,
                  "Helper cannot impersonate its app")
        try check(SecStaticCodeCheckValidity(adHoc, [], appRequirement) != errSecSuccess,
                  "Ad-hoc code with the expected identifier rejected")
        try check(SecStaticCodeCheckValidity(store, [], appRequirement) != errSecSuccess,
                  "Unrelated App Store app cannot impersonate Image2Movie")

        // Establish this is genuinely Apple-re-signed Store code, so the positive
        // check below cannot pass solely through the development-certificate arm.
        var storeCertificate: SecRequirement?
        let status = SecRequirementCreateWithString(
            "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists" as CFString,
            [], &storeCertificate)
        guard status == errSecSuccess, let storeCertificate,
              SecStaticCodeCheckValidity(store, [], storeCertificate) == errSecSuccess,
              let identifier = Bundle(path: CommandLine.arguments[2])?.bundleIdentifier else {
            throw Failure.failed("The supplied App Store app must have Apple's Store signature")
        }
        try check(SecStaticCodeCheckValidity(store, [],
            MCPPeerIdentity.requirement(for: identifier)) == errSecSuccess,
                  "Apple-re-signed Store code accepted for its exact identifier")
    }

    enum Failure: Error {
        case failed(String)
    }
}
