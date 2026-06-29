import SwiftUI

struct StatusPanelView: View {
    @EnvironmentObject private var store: CodexStatusStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow(
                title: "5小时剩余用量",
                value: StatusFormatters.percentText(store.quota?.shortWindow?.remainingPercent),
                detailTitle: "刷新时间",
                detail: StatusFormatters.resetText(store.quota?.shortWindow?.resetsAt)
            )

            statusRow(
                title: "周剩余用量",
                value: StatusFormatters.percentText(store.quota?.longWindow?.remainingPercent),
                detailTitle: "刷新时间",
                detail: StatusFormatters.resetText(store.quota?.longWindow?.resetsAt)
            )

            statusRow(
                title: "剩余可用重置次数",
                value: store.resetCreditsCountText(store.quota?.resetCreditsAvailable),
                detailTitle: "过期时间",
                detail: StatusFormatters.resetText(store.quota?.resetCreditsExpiresAt)
            )

            statusRow(
                title: "当前任务状态",
                value: store.phase.title,
                detailTitle: "详情",
                detail: store.activity
            )
        }
        .padding(14)
    }

    private func statusRow(title: String, value: String, detailTitle: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.headline.monospacedDigit())
            }
            HStack {
                Text(detailTitle)
                .foregroundStyle(.secondary)
                Text(detail)
                    .lineLimit(1)
                Spacer()
            }
            .font(.caption2)
        }
    }
}
