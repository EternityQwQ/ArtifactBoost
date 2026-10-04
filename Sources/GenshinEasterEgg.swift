import SwiftUI

/// 原神彩蛋（中国大陆官网）。
///
/// 约定：只做"二次确认后用系统浏览器打开官网"，不在后台静默下载任何安装包。
/// 与安卓端 `GenshinEasterEggDialog` 对齐。
enum GenshinEasterEgg {
    static let cnURL = URL(string: "https://ys.mihoyo.com/")!
    static let alertMessage =
        "长按「设置」发现了提瓦特大陆的入口。\n\n点击「前往官网」将用浏览器打开原神中国大陆官网，是否前往由你决定，App 不会在后台自动下载任何内容。"
}

extension View {
    /// 彩蛋确认框
    func genshinEasterEggAlert(isPresented: Binding<Bool>) -> some View {
        modifier(GenshinEasterEggAlertModifier(isPresented: isPresented))
    }
}

private struct GenshinEasterEggAlertModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content.alert("发现彩蛋 🎉", isPresented: $isPresented) {
            Button("前往官网") { openURL(GenshinEasterEgg.cnURL) }
            Button("再逛逛", role: .cancel) {}
        } message: {
            Text(GenshinEasterEgg.alertMessage)
        }
    }
}
