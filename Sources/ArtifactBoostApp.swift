import SwiftUI

@main
struct ArtifactBoostApp: App {
    @StateObject private var session: SessionManager
    @StateObject private var downloads: DownloadManager

    init() {
        let session = SessionManager()
        _session = StateObject(wrappedValue: session)
        _downloads = StateObject(wrappedValue: DownloadManager(session: session))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if session.isLoggedIn {
                    RootTabView()
                } else {
                    LoginView()
                }
            }
            .environmentObject(session)
            .environmentObject(downloads)
        }
    }
}