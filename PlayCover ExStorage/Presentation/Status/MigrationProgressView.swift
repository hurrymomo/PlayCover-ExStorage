import SwiftUI

struct MigrationProgressView: View {
    @ObservedObject private var status: MigrationStatus

    init(status: MigrationStatus) {
        self.status = status
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: operation.symbol)
                .font(.title)
                .foregroundStyle(statusColor)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(operation.title)
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                }
                Text(status.snapshot.message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(status.snapshot.message)

                if let progress = status.snapshot.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                } else if operation.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 82, alignment: .center)
    }

    private var statusColor: Color {
        switch operation {
        case .succeeded: .green
        case .failed: .red
        case .idle: .secondary
        default: .accentColor
        }
    }

    private var operation: AppOperation {
        switch status.snapshot.phase {
        case .idle: .idle
        case .completed: .succeeded
        case .failed, .needsAttention: .failed
        default: .migrating
        }
    }
}
