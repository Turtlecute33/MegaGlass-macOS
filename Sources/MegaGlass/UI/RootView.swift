import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            switch app.session.phase {
            case .starting:
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedOut, .signingIn:
                if app.session.isGuest {
                    MainView()
                } else {
                    LoginView()
                }
            case let .loadingAccount(progress):
                LoadingAccountView(progress: progress)
            case .ready:
                MainView()
            }
        }
        .frame(minWidth: 860, minHeight: 540)
        .tint(.megaRed)
        .overlay(alignment: .top) {
            if let toast = app.toast {
                ToastView(toast: toast)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(.spring(duration: 0.35), value: app.toast)
        .alert(item: $app.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .sheet(isPresented: $app.showOpenLinks) {
            OpenLinksSheet()
        }
    }
}

struct LoadingAccountView: View {
    let progress: Double?

    var body: some View {
        ZStack {
            BrandBackground()
            VStack(spacing: 18) {
                Image(systemName: "icloud.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white)
                Text("Loading your Cloud Drive")
                    .font(.title3.weight(.semibold))
                if let progress {
                    ProgressView(value: progress)
                        .frame(width: 240)
                    Text(progress.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(40)
            .glassPanel(cornerRadius: 28)
        }
    }
}

/// A calm brand gradient behind the glass of the login screens.
struct BrandBackground: View {
    var body: some View {
        MeshGradient(width: 3, height: 3, points: [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.5], [0.55, 0.45], [1, 0.5],
            [0, 1], [0.5, 1], [1, 1],
        ], colors: [
            Color(red: 0.55, green: 0.0, blue: 0.05), .megaRed, Color(red: 0.95, green: 0.35, blue: 0.25),
            Color(red: 0.25, green: 0.02, blue: 0.08), Color(red: 0.7, green: 0.05, blue: 0.12), .megaRed,
            Color(red: 0.08, green: 0.02, blue: 0.06), Color(red: 0.3, green: 0.02, blue: 0.1), Color(red: 0.55, green: 0.0, blue: 0.08),
        ])
        .ignoresSafeArea()
    }
}
