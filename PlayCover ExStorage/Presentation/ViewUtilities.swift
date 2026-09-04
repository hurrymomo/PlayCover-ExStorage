import Foundation

/// Presentation-only helpers shared by multiple Views.
enum ViewUtilities {
    static func sortedContainers(
        _ containers: [ExternalAPFSContainer]
    ) -> [ExternalAPFSContainer] {
        containers.sorted { lhs, rhs in
            let nameComparison = (lhs.displayName ?? "")
                .localizedStandardCompare(rhs.displayName ?? "")
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }
            return lhs.containerReference.localizedStandardCompare(
                rhs.containerReference
            ) == .orderedAscending
        }
    }
}

nonisolated enum StorageByteFormatter {
    nonisolated static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: max(0, bytes))
    }
}
