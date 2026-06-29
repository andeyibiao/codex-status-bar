import SwiftUI

struct StatusPanelView: View {
    @EnvironmentObject private var store: CodexStatusStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            taskHeader
            metricsGroup
        }
        .padding(14)
    }

    private var taskHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: store.phase.panelSymbolName)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(
                    store.phase.panelColor,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("当前任务状态")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(taskDetailText)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 10)

            Text(store.phase.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    store.phase.panelColor,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        }
        .padding(10)
        .background(
            store.phase.panelColor.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(store.phase.panelColor.opacity(0.28), lineWidth: 0.5)
        )
    }

    private var metricsGroup: some View {
        VStack(spacing: 0) {
            MetricRow(
                title: "5小时剩余用量",
                value: StatusFormatters.percentText(store.quota?.shortWindow?.remainingPercent),
                detailLabel: "刷新",
                detail: StatusFormatters.panelDateTimeText(store.quota?.shortWindow?.resetsAt),
                progress: store.quota?.shortWindow?.remainingPercent,
                tint: quotaTint(store.quota?.shortWindow?.remainingPercent)
            )

            rowDivider

            MetricRow(
                title: "周剩余用量",
                value: StatusFormatters.percentText(store.quota?.longWindow?.remainingPercent),
                detailLabel: "刷新",
                detail: StatusFormatters.panelDateTimeText(store.quota?.longWindow?.resetsAt),
                progress: store.quota?.longWindow?.remainingPercent,
                tint: quotaTint(store.quota?.longWindow?.remainingPercent)
            )

            rowDivider

            ResetCreditsRow(
                title: "剩余可用重置次数",
                value: store.resetCreditsCountText(store.quota?.resetCreditsAvailable),
                detailLabel: "过期",
                detail: StatusFormatters.panelDateTimeText(store.quota?.resetCreditsExpiresAt),
                credits: store.quota?.resetCredits ?? []
            )
        }
        .background(
            Color.secondary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
        )
    }

    private var rowDivider: some View {
        Divider()
            .padding(.horizontal, 12)
    }

    private var taskDetailText: String {
        guard !store.activity.isEmpty, store.activity != store.phase.title else {
            return store.phase.title
        }
        return store.activity
    }

    private func quotaTint(_ remaining: Double?) -> Color {
        guard let remaining else { return .secondary }
        switch remaining {
        case ..<25:
            return .red
        case ..<60:
            return .orange
        default:
            return .green
        }
    }
}

private struct MetricRow: View {
    var title: String
    var value: String
    var detailLabel: String
    var detail: String
    var progress: Double?
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))

                    HStack(spacing: 4) {
                        Text(detailLabel)
                        Text(detail)
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Text(value)
                    .font(.system(size: 21, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            if let progress {
                ProgressView(value: clamped(progress), total: 100)
                    .tint(tint)
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: progress == nil ? 56 : 68)
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}

private struct ResetCreditsRow: View {
    var title: String
    var value: String
    var detailLabel: String
    var detail: String
    var credits: [ResetCreditSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))

                    HStack(spacing: 4) {
                        Text(detailLabel)
                        Text(detail)
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Text(value)
                    .font(.system(size: 21, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            resetCreditDetails
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var resetCreditDetails: some View {
        if credits.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 4) {
                ForEach(credits) { credit in
                    HStack(spacing: 8) {
                        Text("第 \(credit.id) 次")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text(StatusFormatters.panelDateTimeText(credit.expiresAt))
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
            }
            .padding(.top, 2)
        }
    }
}

private extension ExecutionPhase {
    var panelSymbolName: String {
        switch self {
        case .disconnected:
            return "wifi.slash"
        case .connecting:
            return "arrow.triangle.2.circlepath"
        case .idle:
            return "pause.circle.fill"
        case .running:
            return "play.circle.fill"
        case .waiting:
            return "exclamationmark.circle.fill"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        }
    }

    var panelColor: Color {
        switch self {
        case .disconnected:
            return .secondary
        case .connecting:
            return .blue
        case .idle:
            return .secondary
        case .running:
            return .blue
        case .waiting:
            return .orange
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }
}
