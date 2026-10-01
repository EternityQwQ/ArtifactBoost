import SwiftUI

/// 下载中心：所有正在下载 / 已完成的任务
struct DownloadsView: View {
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        List {
            if downloads.orderedItems.isEmpty {
                EmptyStateView(systemName: "arrow.down.circle",
                               title: "还没有下载任务",
                               message: "去「仓库」里挑一个构建产物、正式版附件或源码包试试")
            } else {
                Section {
                    ForEach(downloads.orderedItems) { item in
                        DownloadItemRow(item: item)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    downloads.remove(item)
                                } label: {
                                    Label("移除", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    if downloads.activeCount > 0 {
                        Text("正在下载 \(downloads.activeCount) 个")
                    } else {
                        Text("全部下载")
                    }
                } footer: {
                    Text("文件保存在「文件」App → 我的 iPhone → ArtifactBoost → Artifacts，也可以直接导出或分享。")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("下载")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button("清空已完成") { downloads.clearFinished() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }
}