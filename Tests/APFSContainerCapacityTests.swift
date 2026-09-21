import Foundation

@main
enum APFSContainerCapacityTests {
    static let targetUUID = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
    static let otherUUID = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"

    static func record(
        reference: String = "disk5",
        uuid: String = targetUUID.uuidString,
        capacity: Any = Int64(12_000_000_000)
    ) -> [String: Any] {
        ["ContainerReference": reference, "APFSContainerUUID": uuid, "CapacityFree": capacity]
    }

    static func plist(_ containers: [[String: Any]], format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["Containers": containers], format: format, options: 0)
    }

    static func main() throws {
        var passed = 0
        func check(_ name: String, _ data: Data, _ expected: Result<Int64, APFSContainerCapacity.Failure>) {
            let actual: Result<Int64, APFSContainerCapacity.Failure>
            do {
                actual = .success(try APFSContainerCapacity.read(
                    from: data, containerReference: "disk5", expectedUUID: targetUUID
                ))
            } catch let failure as APFSContainerCapacity.Failure {
                actual = .failure(failure)
            } catch {
                fatalError("\(name): unexpected error \(error)")
            }
            guard actual == expected else {
                fatalError("\(name): expected \(expected), got \(actual)")
            }
            passed += 1
            print("PASS \(name)")
        }

        check("single target", try plist([record()]), .success(12_000_000_000))
        check("binary plist", try plist([record()], format: .binary), .success(12_000_000_000))
        check("zero free bytes", try plist([record(capacity: 0)]), .success(0))
        check("case-insensitive UUID", try plist([record(uuid: targetUUID.uuidString.lowercased())]), .success(12_000_000_000))
        check("large capacity", try plist([record(capacity: Int64.max)]), .success(Int64.max))

        // The old Dictionary(uniqueKeysWithValues:) implementation crashed on
        // these unrelated UUID collisions before it could select the target.
        let unrelated = record(reference: "disk6", uuid: otherUUID)
        check("unrelated duplicate UUIDs", try plist([unrelated, unrelated, record()]), .success(12_000_000_000))
        check("same UUID on another device", try plist([
            record(reference: "disk6", capacity: 1), record()
        ]), .success(12_000_000_000))
        check("unrelated malformed capacity", try plist([
            record(reference: "disk6", capacity: "unknown"), record()
        ]), .success(12_000_000_000))

        check("identical duplicate target", try plist([record(), record()]), .failure(.duplicateTarget))
        check("conflicting duplicate target", try plist([record(), record(capacity: 1)]), .failure(.duplicateTarget))
        check("duplicate target UUID casing", try plist([
            record(), record(uuid: targetUUID.uuidString.lowercased())
        ]), .failure(.duplicateTarget))
        check("reused device identifier", try plist([record(uuid: otherUUID)]), .failure(.identityMismatch))
        check("invalid target UUID", try plist([record(uuid: "invalid")]), .failure(.identityMismatch))
        check("missing target", try plist([unrelated]), .failure(.targetNotFound))
        check("empty response", try plist([]), .failure(.targetNotFound))
        check("invalid plist", Data("not a plist".utf8), .failure(.invalidPropertyList))
        check("missing containers", try PropertyListSerialization.data(
            fromPropertyList: [String: String](), format: .xml, options: 0
        ), .failure(.missingContainers))

        var missingCapacity = record()
        missingCapacity.removeValue(forKey: "CapacityFree")
        check("missing capacity", try plist([missingCapacity]), .failure(.invalidCapacity))
        check("negative capacity", try plist([record(capacity: -1)]), .failure(.invalidCapacity))
        check("boolean capacity", try plist([record(capacity: true)]), .failure(.invalidCapacity))
        check("fractional capacity", try plist([record(capacity: 1.5)]), .failure(.invalidCapacity))
        check("string capacity", try plist([record(capacity: "100")]), .failure(.invalidCapacity))
        check("overflowing capacity", try plist([record(capacity: UInt64.max)]), .failure(.invalidCapacity))
        print("\(passed) capacity regression checks passed")
    }
}
