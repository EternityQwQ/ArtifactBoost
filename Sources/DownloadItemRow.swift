import SwiftUI

/// 通用「可下载项」行：产物 / 构建日志 / 正式版附件 / 源码包 共用
struct DownloadItemRow: View {
    let item: DownloadItem
    var disabled: Bool = false
    var disabledNote: String?

    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            actionArea
        }
        .padding(.vertical, 4)
        .opacity(disabled ? 0.55 : 1)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(systemName: item.iconName, color: Theme.color(for: item.source))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(item.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.kindName)
                    if let size = item.size {
                        Text("·")
                        Text(formatBytes(size))
                    }
                    if !item.source.supportsChunkedDownload {
                        Text("·")
                        Text("不支持分段")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            if disabled, let note = disabledNote {
                StatusPill(text: note, color: .gray)
            }
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        switch downloads.state(for: item) {
        case .idle:
            Button {
                downloads.start(item, settings: AccelerationSettings.load())
            } label: {
                Label("加速下载", systemImage: "bolt.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(disabled)

        case .resolving:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(downloads.routeSummary[item.id] ?? "正在解析下载地址…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                if progress.totalBytes > 0 {
                    ProgressView(value: progress.fraction)
                        .tint(Theme.accent)
                    HStack {
                        Text("\(formatBytes(progress.downloadedBytes)) / \(formatBytes(progress.totalBytes))")
                        Spacer()
                        Text("\(Int(progress.fraction * 100))%")
                        Text(formatSpeed(progress.speedBytesPerSecond))
                            .foregroundStyle(Theme.green)
                            .fontWeight(.semibold)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                    Text("该资源不支持分段，正在单连接下载…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let summary = downloads.routeSummary[item.id] {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 12) {
                    Button(role: .destructive) {
                        downloads.cancel(item)
                    } label: {
                        Label("取消", systemImage: "xmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
            }

        case .finished(let url):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                    Text("下载完成").font(.subheadline.weight(.semibold))
                    Spacer()
                }
                if let summary = downloads.routeSummary[item.id] {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    ShareLink(item: url) {
                        Label("导出 / 保存到文件", systemImage: "square.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        downloads.start(item, settings: AccelerationSettings.load())
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.red)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    downloads.start(item, settings: AccelerationSettings.load())
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}