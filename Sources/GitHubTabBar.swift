import SwiftUI

/// GitHub 移动端风格的顶部下划线 Tab 栏（替代系统 segmented picker）
struct GitHubTabBar<T: Hashable>: View {
    let tabs: [T]
    let title: (T) -> String
    let badge: (T) -> String?
    @Binding var selection: T
    @Namespace private var underline

    init(tabs: [T],
         selection: Binding<T>,
         title: @escaping (T) -> String,
         badge: @escaping (T) -> String? = { _ in nil }) {
        self.tabs = tabs
        self._selection = selection
        self.title = title
        self.badge = badge
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(tabs, id: \.self) { tab in
                    button(for: tab)
                }
            }
            .padding(.horizontal, 4)
        }
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func button(for tab: T) -> some View {
        let isSelected = tab == selection
        return Button {
            withAnimation(.snappy(duration: 0.22)) { selection = tab }
        } label: {
            VStack(spacing: 7) {
                HStack(spacing: 5) {
                    Text(title(tab))
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Theme.strongText : Theme.muted)
                    if let badge = badge(tab), !badge.isEmpty {
                        Text(badge)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.border.opacity(0.6), in: Capsule())
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)

                Group {
                    if isSelected {
                        Capsule()
                            .fill(Theme.orange)
                            .frame(height: 2.5)
                            .matchedGeometryEffect(id: "gh-tab-underline", in: underline)
                    } else {
                        Color.clear.frame(height: 2.5)
                    }
                }
                .padding(.horizontal, 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 0.5pt 分割线（GitHub 的 border 色）
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(height: 0.5)
    }
}

/// 加载中的骨架条
struct SkeletonBar: View {
    var height: CGFloat = 12
    var width: CGFloat? = nil
    @State private var shimmer = false

    var body: some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Theme.border.opacity(shimmer ? 0.35 : 0.7))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true), value: shimmer)
            .onAppear { shimmer = true }
    }
}

/// 骨架卡片：给 README / 列表加载时占位
struct SkeletonBlock: View {
    var lines: Int = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<lines, id: \.self) { index in
                SkeletonBar(height: index == 0 ? 16 : 11,
                            width: index == lines - 1 ? 160 : nil)
            }
        }
        .padding(.vertical, 4)
    }
}
