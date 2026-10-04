import SwiftUI

/// 登录后的主界面：仓库 / 搜索 / 下载 / 设置
struct RootTabView: View {
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        TabView {
            NavigationStack {
                RepoListView()
            }
            .tabItem { Label("仓库", systemImage: "square.stack.3d.up.fill") }

            SearchView()
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }

            NavigationStack {
                DownloadsView()
            }
            .tabItem { Label("下载", systemImage: "arrow.down.circle.fill") }
            .badge(downloads.activeCount)

            NavigationStack {
                SettingsView()
            }
            // 彩蛋：原生 tabItem 不支持长按，长按导航栏「设置」标题触发
            //（二次确认后跳原神官网 ys.mihoyo.com，见 GenshinEasterEgg.swift）。
            .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
        .tint(Theme.accent)
    }
}