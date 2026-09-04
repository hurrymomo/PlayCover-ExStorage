import SwiftUI

struct OtherVolumeStatusView: View {
    let volume: ExternalVolume

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.title).foregroundStyle(.secondary).frame(width: 48)
            VStack(alignment: .leading, spacing: 5) {
                Text(volume.name).font(.system(size: 15, weight: .semibold))
                HStack(spacing: 18) {
                    detail("Type", "Other Volume")
                    detail("Used", volume.usedBytes.map(StorageByteFormatter.string) ?? "Unknown")
                    detail("Device", volume.bsdDevice ?? "Unknown")
                    if let uuid = volume.volumeUUID {
                        detail("UUID", String(uuid.prefix(8)).uppercased())
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .frame(height: 82)
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
