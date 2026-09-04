import SwiftUI

struct OtherVolumeRow: View {
    @EnvironmentObject private var model: AppModel
    let actions: ManagedAppActions
    let container: ExternalAPFSContainer
    let volume: ExternalVolume
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 64)
            Text(volume.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : .clear)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .contextMenu {
            Button("Connect & Open") {
                select()
                actions.openOtherVolume(volume)
            }

            Divider()

            Button("Delete…", role: .destructive) {
                select()
                actions.requestDelete(volume, in: container)
            }
        }
        .help("Unrecognized APFS Volume — read only")
    }
}
