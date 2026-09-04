import Foundation

// MARK: - External interface exposed by the privileged helper

@objc protocol PrivilegedHelperXPCProtocol {
    func beginOperationLog(atPath: String, reply: @escaping (String?, NSError?) -> Void)
    func createAPFSVolume(containerReference: String, name: String, reply: @escaping (String?, String?, String?, NSError?) -> Void)
    func deleteAPFSVolume(device: String, reply: @escaping (String?, NSError?) -> Void)
    func mountAPFSVolume(device: String, atPath: String, options: [String], reply: @escaping (String?, NSError?) -> Void)
    func unmountVolume(atPath: String, reply: @escaping (String?, NSError?) -> Void)
    func renameItem(fromPath: String, toPath: String, reply: @escaping (String?, NSError?) -> Void)
    func deleteItem(atPath: String, reply: @escaping (String?, NSError?) -> Void)
    func shutdown(reply: @escaping (String?, NSError?) -> Void)
}
