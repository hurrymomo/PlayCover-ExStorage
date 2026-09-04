import SwiftUI

struct MigrationAppPlaceholder: View {
    @ObservedObject private var status: MigrationStatus
    let actions: ManagedAppActions
    let app: AppSnapshot
    let queued: Bool

    init(
        status: MigrationStatus,
        actions: ManagedAppActions,
        app: AppSnapshot,
        queued: Bool
    ) {
        self.status = status
        self.actions = actions
        self.app = app
        self.queued = queued
    }

    private var isActive: Bool {
        status.snapshot.active?.bundleIdentifier == app.bundleIdentifier
    }

    private var failed: Bool {
        isActive && status.snapshot.error != nil
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                appIcon
                    .opacity(0.48)
                RoundedRectangle(cornerRadius: 14)
                    .fill(.black.opacity(0.28))
                    .frame(width: 64, height: 64)
                if queued {
                    VStack(spacing: 2) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 17, weight: .semibold))
                        Text("Queued").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.white)
                } else if failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                        .symbolRenderingMode(.hierarchical)
                } else if isActive, let progress = status.snapshot.progress {
                    ZStack {
                        ProgressView(value: progress)
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .frame(width: 34, height: 34)
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                } else {
                    VStack(spacing: 2) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        if !isActive {
                            Text("Preparing")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
            Text(app.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help(status.snapshot.message)
        .accessibilityLabel("\(app.name), \(queued ? "queued" : (failed ? "migration failed" : progressLabel))")
    }

    @ViewBuilder
    private var appIcon: some View {
        if actions.isInstalledApp(app) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.applicationPath))
                .resizable()
                .frame(width: 64, height: 64)
                .cornerRadius(14)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 38))
                .frame(width: 64, height: 64)
        }
    }

    private var progressLabel: String {
        guard let progress = status.snapshot.progress else { return "Preparing…" }
        return "\(Int((progress * 100).rounded()))%"
    }
}
