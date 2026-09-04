import Foundation
import Security

let helperMachServiceName = "momo.PlayCover-ExStorage.PrivilegedHelper"

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = PrivilegedHelperService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement = Self.authorizedAppRequirement() else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: PrivilegedHelperXPCProtocol.self)
        connection.exportedObject = service
        connection.invalidationHandler = { DispatchQueue.main.async { exit(EXIT_SUCCESS) } }
        connection.resume()
        return true
    }

    private static func authorizedAppRequirement() -> String? {
        guard let executableURL = Bundle.main.executableURL else { return nil }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executableURL as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let values = information as? [String: Any],
        let teamID = values[kSecCodeInfoTeamIdentifier as String] as? String else { return nil }
        return "anchor apple generic and identifier \"momo.PlayCover-ExStorage\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}
