import Foundation
import CoreFoundation

/// Parses a capacity query without assuming that diskutil's UUIDs are unique.
nonisolated enum APFSContainerCapacity {
    enum Failure: String, Error {
        case invalidPropertyList
        case missingContainers
        case targetNotFound
        case duplicateTarget
        case identityMismatch
        case invalidCapacity
    }

    static func read(
        from data: Data,
        containerReference: String,
        expectedUUID: UUID
    ) throws -> Int64 {
        guard let dictionary = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else {
            throw Failure.invalidPropertyList
        }
        guard let containers = dictionary["Containers"] as? [[String: Any]] else {
            throw Failure.missingContainers
        }

        // Select by the requested device before checking its identity. Unrelated
        // containers must not participate in the destination's capacity check.
        let matches = containers.filter {
            ($0["ContainerReference"] as? String) == containerReference
        }
        guard let container = matches.first else { throw Failure.targetNotFound }
        guard matches.count == 1 else { throw Failure.duplicateTarget }
        guard let uuidString = container["APFSContainerUUID"] as? String,
              UUID(uuidString: uuidString) == expectedUUID else {
            throw Failure.identityMismatch
        }
        guard let number = container["CapacityFree"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let bytes = Int64(number.stringValue), bytes >= 0 else {
            throw Failure.invalidCapacity
        }
        return bytes
    }
}
