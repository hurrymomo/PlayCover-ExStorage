import Foundation

// MARK: - External interface exposed by the privileged helper

@objc protocol PrivilegedHelperXPCProtocol {
    func createAPFSVolume(containerReference: String, name: String, operationID: String, logPath: String, reply: @escaping (String?, String?, String?, NSError?) -> Void)
    func deleteAPFSVolume(device: String, operationID: String, logPath: String, reply: @escaping (String?, NSError?) -> Void)
    func mountAPFSVolume(device: String, atPath: String, options: [String], operationID: String, logPath: String, reply: @escaping (String?, NSError?) -> Void)
    func unmountVolume(atPath: String, operationID: String, logPath: String, reply: @escaping (String?, NSError?) -> Void)
    func renameItem(fromPath: String, toPath: String, operationID: String, logPath: String, reply: @escaping (String?, NSError?) -> Void)
    func deleteItem(atPath: String, operationID: String, logPath: String, reply: @escaping (String?, NSError?) -> Void)
    func shutdown(operationID: String, logPath: String, reply: @escaping (String?, NSError?) -> Void)
}
