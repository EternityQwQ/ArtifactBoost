import SwiftUI

/// 正式版详情：附件 + 对应 tag 的源码包，都能加速下载
struct ReleaseDetailView: View {
    let repo: GHRepo
    let release: GHRelease

    @State private var showNotes = false

    var body: some View {
        List {
            Section {
                header
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear)

            if let body = release.body, !body.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(body)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(showNotes ? nil : 6)
                        Button(showNotes ? "收起" : "展开全部") {
                            withAnimation { showNotes.toggle() }
                        }
                        .font(.caption)
                    }
                } header: {
                    Text("更新说明")
                }
            }

            Section {
                if release.assets.isEmpty {
                    EmptyStateView(systemName: "shippingbox",
                                   title: "这个版本没有附件",
                                   message: "可以直接下载下面的源码包")
                } else {
                    ForEach(release.assets) { asset in
                        DownloadItemRow(item: DownloadItem.releaseAsset(asset, release: release, repo: repo))
                    }
                }
            } header: {
                Text("附件（\(release.assets.count)）")
            } footer: {
                Text("正式版附件通常托管在 GitHub 的 CDN 上，同样支持多通道并发加速。")
            }

            Section {
                DownloadItemRow(item: DownloadItem.sourceArchive(repo: repo, ref: release.tagName, format: .zip))
                DownloadItemRow(item: DownloadItem.sourceArchive(repo: repo, ref: release.tagName, format: .tarball))
            } header: {
                Text("这个版本的源码")
            } footer: {
                Text("源码包由 GitHub 现场打包，不支持分段，只能单连接下载。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(release.tagName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconBadge(systemName: "shippingbox.fill", color: Theme.purple, size: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text(release.displayName)
                        .font(.headline)
                        .lineLimit(2)
                    Text("\(repo.fullName) · \(release.tagName)")
                        .font(.caption2)
                        .foregroundStyle(Theme.subtle)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if release.prerelease {
                    StatusPill(text: "预发布", color: Theme.orange)
                } else if release.draft {
                    StatusPill(text: "草稿", color: Theme.muted)
                } else {
                    StatusPill(text: "正式版", color: Theme.green)
                }
            }

            HStack(spacing: 8) {
                if let date = release.publishedAt {
                    StatusPill(text: date.formatted(date: .numeric, time: .omitted), color: Theme.muted)
                }
                StatusPill(text: "\(release.assets.count) 个附件", color: Theme.muted)
            }
        }
        .card()
    }
}