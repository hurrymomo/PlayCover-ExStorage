import Foundation

// MARK: - Privileged helper process entry point

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: helperMachServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
