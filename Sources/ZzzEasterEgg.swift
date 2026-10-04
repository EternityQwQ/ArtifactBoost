import SwiftUI

/// 绝区零彩蛋（中国大陆官网）。
///
/// 约定：只做"二次确认后用系统浏览器打开官网"，不在后台静默下载任何安装包。
/// 与原神彩蛋（见 GenshinEasterEgg.swift）行为一致。
enum ZzzEasterEgg {
    static let cnURL = URL(string: "https://zzz.mihoyo.com/")!
    static let alertMessage =
        "长按「我的仓库」发现了新艾利都的入口。\n\n点击「前往官网」将用浏览器打开绝区零中国大陆官网，是否前往由你决定，App 不会在后台自动下载任何内容。"
}

extension View {
    /// 彩蛋确认框
    func zzzEasterEggAlert(isPresented: Binding<Bool>) -> some View {
        modifier(ZzzEasterEggAlertModifier(isPresented: isPresented))
    }
}

private struct ZzzEasterEggAlertModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content.alert("发现彩蛋 🎉", isPresented: $isPresented) {
            Button("前往官网") { openURL(ZzzEasterEgg.cnURL) }
            Button("再逛逛", role: .cancel) {}
        } message: {
            Text(ZzzEasterEgg.alertMessage)
        }
    }
}
