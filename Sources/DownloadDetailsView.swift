import SwiftUI

/// 下载详情面板 —— 对应 Neat Download Manager 的「连接」视图。
///
/// 展示三类信息（用户选定的口径）：
///  1. 分段进度与速度：每条连接啃哪个字节区间、跑到百分比、当前多快；
///  2. 分段连接状态：等待/下载中/重试中/完成/失败，第几次重试，服务端回了什么码；
///  3. 下载地址与通道：每段走的是哪条镜像，以及当前实际请求的完整 URL（可一键复制）。
struct DownloadDetailsView: View {
    let title: String
    let diagnostics: DownloadDiagnostics?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let diagnostics {
                    content(diagnostics)
                } else {
                    // 还没跑起来（正在解析地址 / 还没分段）：给个体面的占位，别显示空白
                    EmptyStateView(
                        systemName: "antenna.radiowaves.left.and.right",
                        title: "正在建立连接",
                        message: "稍候即可看到各分段明细"
                    )
                    .frame(maxHeight: .infinity)
                }
            }
            .navigationTitle("下载详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func content(_ diagnostics: DownloadDiagnostics) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                summarySection(diagnostics)

                if !diagnostics.routes.isEmpty {
                    routeSection(diagnostics)
                }

                laneSection(diagnostics)

                if !diagnostics.activeUrl.isEmpty {
                    urlSection(diagnostics.activeUrl)
                }
            }
            .padding(Theme.Spacing.lg)
        }
    }

    // MARK: - 汇总

    private func summarySection(_ diagnostics: DownloadDiagnostics) -> some View {
        let totalSpeed = diagnostics.lanes.reduce(0) { $0 + $1.speedBytesPerSecond }
        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                StatTile(label: "实时总速度", value: formatSpeed(totalSpeed), tint: Theme.green)
                StatTile(label: "活跃 / 目标连接",
                         value: "\(diagnostics.lanes.count) / \(diagnostics.targetLanes)",
                         tint: Theme.accent)
            }
            HStack(spacing: Theme.Spacing.sm) {
                StatTile(label: "切片 完成 / 累计",
                         value: "\(diagnostics.doneSlices) / \(diagnostics.totalSlices)",
                         tint: Theme.purple)
                StatTile(label: "重试 / 限流 / 切分",
                         value: "\(diagnostics.retries) / \(diagnostics.throttles) / \(diagnostics.splits)",
                         tint: diagnostics.throttles > 0 ? Theme.orange : .secondary)
            }
            if diagnostics.throttles > 0 {
                Text("检测到服务端限流（429/503）：引擎已按指数退避自动降速重试，并对该通道临时降低并发。这属于正常的自我节流，不是下载失败。")
                    .font(.caption2)
                    .foregroundStyle(Theme.orange)
            }
        }
    }

    // MARK: - 通道

    private func routeSection(_ diagnostics: DownloadDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("通道")
                .font(.subheadline.weight(.semibold))
            ForEach(diagnostics.routes) { route in
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "speedometer")
                        .font(.caption2)
                        .foregroundStyle(route.isActive ? Theme.green : .secondary)
                    Text(route.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(formatSpeed(route.speedBytesPerSecond))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(route.isActive ? Theme.green : .secondary)
                }
            }
        }
    }

    // MARK: - 分段明细

    private func laneSection(_ diagnostics: DownloadDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("分段明细（\(diagnostics.lanes.count)/\(diagnostics.targetLanes) 条连接）")
                .font(.subheadline.weight(.semibold))

            if diagnostics.lanes.isEmpty {
                Text("当前没有活跃分段")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(diagnostics.lanes) { lane in
                    LaneRow(lane: lane)
                }
            }
        }
    }

    // MARK: - 下载地址

    private func urlSection(_ url: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text("当前下载地址")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    UIPasteboard.general.string = url
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            Text(url)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 单个统计块
private struct StatTile: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.weight(.bold))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 一条车道的明细行
private struct LaneRow: View {
    let lane: LaneSnapshot

    private var tint: Color {
        switch lane.state {
        case .pending: return .secondary
        case .downloading: return Theme.accent
        case .retrying: return Theme.orange
        case .done: return Theme.green
        case .failed: return Theme.red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(spacing: Theme.Spacing.xs) {
                Text("#\(lane.laneId)")
                    .font(.caption.weight(.bold))
                Text(lane.routeName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(lane.state.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
            }

            ProgressView(value: lane.fraction)
                .tint(tint)

            HStack(spacing: Theme.Spacing.xs) {
                Text("\(formatBytes(lane.start)) – \(formatBytes(lane.end))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if lane.attempt > 1 {
                    Text("第 \(lane.attempt) 次")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.orange)
                }
                if let status = lane.lastStatus {
                    Text("HTTP \(status)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Text(formatSpeed(lane.speedBytesPerSecond))
                    .font(.system(size: 10).weight(.semibold))
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }
}
