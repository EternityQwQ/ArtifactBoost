# ArtifactBoost — GitHub Actions 产物加速下载（iOS）

[![Build ArtifactBoost](https://github.com/yitenchen123/ArtifactBoost/actions/workflows/build.yml/badge.svg)](https://github.com/yitenchen123/ArtifactBoost/actions/workflows/build.yml)

一个原生 SwiftUI iOS 应用：登录 GitHub，浏览仓库的 Actions 运行记录与产物，用**多线程分段并发下载**大幅加速产物拉取。

## 为什么镜像站加速不了 Actions 产物？

GitHub 产物的下载流程是：

1. 带 Token 请求 `api.github.com/.../artifacts/{id}/zip`
2. GitHub 返回 **302 跳转**到一个临时的 Azure Blob 签名地址
3. 真正的文件从 Azure 服务器下载

ghproxy 等公开镜像无法携带你的 Token 去请求这个接口，所以全部失效。
本 App 在**本机**完成鉴权和跳转解析，拿到签名地址后直接对 Azure 地址做 **HTTP Range 分段并发下载**（类似 IDM/aria2 的多线程）。GitHub/Azure 对单连接有限速，多并发通常能提速 **3–10 倍**。

## 功能

- Personal Access Token 登录（Token 只存本机钥匙串，不上传任何服务器）
- 浏览自己/协作/组织的仓库，支持远程搜索
- 查看 Workflow 运行记录（状态、分支、编号、时间）
- 查看每次运行的产物列表（名称、大小、是否过期）
- **1–16 可调并发分段下载**，实时显示进度、百分比和速度
- 自动重试（每段最多 3 次）、可随时取消
- 下载完成后一键导出到「文件」App / 分享

## 安装到 iPhone（三种方式，任选一种）

### 方式 A：直接下载 CI 构建好的安装包（没有 Mac 也能用）

1. 打开本仓库的 **Actions** 页面 → 选最新一次成功的 **Build ArtifactBoost**
2. 在页面底部的 **Artifacts** 区域下载 **ArtifactBoost-unsigned.ipa**
3. 在电脑上用免费工具自签安装到手机（未签名包不能直接双击安装）：
   - **Sideloadly**（Windows / macOS，最省事）：拖入 ipa → 填 Apple ID → Start
   - **AltStore / SideStore**：把 ipa 放进 AltStore 后安装
   - 免费 Apple ID 签名的 App 有效期为 7 天，到期重签一次即可
4. 装好后打开 App，粘贴 Token 登录即可使用

> 同一个 Artifacts 里还有 **ArtifactBoost-simulator.zip**，是给 Mac 上的 iOS 模拟器用的。

### 方式 B：Mac + Xcode 本地运行

1. Mac 上安装 **Xcode 16 或更新版本**（XcodeGen 生成的是新版工程格式，Xcode 15 打不开）
2. 安装 XcodeGen 并生成工程：

   ```bash
   brew install xcodegen
   xcodegen generate
   open ArtifactBoost.xcodeproj
   ```

3. 选中 TARGETS → ArtifactBoost → **Signing & Capabilities**，Team 选择你的 Apple ID（免费 Personal Team 即可）
4. 连上 iPhone，选中设备，按 `⌘R` 运行

### 方式 C：纯手工建工程（不使用 XcodeGen）

1. 打开 Xcode → **Create New Project** → **iOS → App**
   - Product Name：`ArtifactBoost`；Interface：**SwiftUI**；Language：**Swift**
2. 删除 Xcode 自动生成的 `ContentView.swift` 和 `ArtifactBoostApp.swift`
3. 把 `Sources` 里的全部 `.swift` 文件拖进项目导航（勾选 **Copy items if needed**，Target 勾选 ArtifactBoost）
4. General 里把 Minimum Deployments 设为 **iOS 16.0**，Signing 里选好自己的 Team，`⌘R` 运行

## 创建 Token（二选一）

**方式 A：Classic Token（最省事）**
打开 https://github.com/settings/tokens/new
→ Note 随便填 → Expiration 自选 → 勾选 **`repo`** → Generate → 复制 `ghp_` 开头的 Token。

**方式 B：Fine-grained Token（更安全）**
打开 https://github.com/settings/personal-access-tokens/new
→ Repository access 选 **Only select repositories** 并勾选目标仓库
→ Permissions 里把 **Actions** 和 **Contents** 都设为 **Read**
→ Generate → 复制 `github_pat_` 开头的 Token。

在 App 登录页粘贴 Token，点「验证并登录」。

## 使用

仓库 → 选择一次 Workflow 运行 → 产物列表 → 点「加速下载」→ 完成后「导出 / 保存到文件」。
并发数建议保持默认 8；网络差时可调低，网络好时可拉到 16。

## 注意事项

- 下载时尽量保持 App 在前台：已申请系统后台任务，切走后有约 30 秒缓冲，之后 iOS 仍会暂停网络任务
- 大文件建议在 Wi-Fi 下下载
- GitHub 产物默认保留 90 天，过期的产物（列表里标红「已过期」）无法下载
- 加速的原理是绕过单连接限速，无法突破你本地网络的物理带宽上限
- Token 不要泄露给他人；怀疑泄露时到 GitHub Settings 里点 Revoke 即可

## 文件结构

```
Sources/
├── ArtifactBoostApp.swift   App 入口，按登录状态切换界面
├── SessionManager.swift     登录态管理（Token 存取）
├── KeychainHelper.swift     系统钥匙串读写
├── GitHubModels.swift       API 数据模型
├── GitHubClient.swift       GitHub REST API 客户端（含 302 签名地址解析）
├── DownloadEngine.swift     多线程 Range 分段下载引擎（核心加速逻辑）
├── DownloadManager.swift    下载任务状态管理（进度/取消/重试）
├── Formatters.swift         字节数/网速格式化
├── LoginView.swift          登录页
├── RepoListView.swift       仓库列表（筛选 + 远程搜索）
├── RunListView.swift        Workflow 运行记录
└── ArtifactListView.swift   产物列表 + 加速下载 + 导出
```
