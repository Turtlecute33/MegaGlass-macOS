import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var app
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var needsCode = false
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focus: Field?

    private enum Field { case email, password, code }

    var body: some View {
        ZStack {
            BrandBackground()
            VStack(spacing: 22) {
                VStack(spacing: 8) {
                    Image(systemName: "icloud.fill")
                        .font(.system(size: 46, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(radius: 8)
                    Text("MegaGlass")
                        .font(.largeTitle.weight(.bold))
                    Text("End-to-end encrypted MEGA storage")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    if needsCode {
                        Text("Enter the 6-digit code from your authenticator app.")
                            .font(.callout)
                            .multilineTextAlignment(.center)
                        TextField("Code", text: $code)
                            .textContentType(.oneTimeCode)
                            .font(.title2.monospacedDigit())
                            .multilineTextAlignment(.center)
                            .focused($focus, equals: .code)
                            .onChange(of: code) { _, value in
                                code = String(value.filter(\.isNumber).prefix(6))
                                if code.count == 6 { submit() }
                            }
                    } else {
                        TextField("Email", text: $email)
                            .textContentType(.username)
                            .focused($focus, equals: .email)
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .focused($focus, equals: .password)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .frame(width: 300)
                .onSubmit(submit)

                if let message = error ?? app.session.startupMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(width: 300)
                }

                VStack(spacing: 10) {
                    Button(action: submit) {
                        HStack {
                            if busy { ProgressView().controlSize(.small) }
                            Text(needsCode ? "Verify" : "Log In")
                        }
                        .frame(width: 270)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || !canSubmit)

                    if needsCode {
                        Button("Back") {
                            needsCode = false
                            code = ""
                            error = nil
                        }
                        .buttonStyle(.glass)
                    } else {
                        Button {
                            app.session.isGuest = true
                            app.showOpenLinks = true
                        } label: {
                            Label("Open MEGA Links Without Logging In", systemImage: "link")
                                .frame(width: 270)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                    }
                }

                if !needsCode {
                    Link("Create a free account on mega.io", destination: URL(string: "https://mega.io/register")!)
                        .font(.callout)
                }
            }
            .padding(36)
            .glassPanel(cornerRadius: 32)
        }
        .onAppear { focus = .email }
    }

    private var canSubmit: Bool {
        needsCode ? code.count == 6 : (email.contains("@") && !password.isEmpty)
    }

    private func submit() {
        guard canSubmit, !busy else { return }
        busy = true
        error = nil
        app.session.startupMessage = nil
        Task {
            defer { busy = false }
            do {
                try await app.session.signIn(email: email.trimmingCharacters(in: .whitespaces),
                                             password: password,
                                             code: needsCode ? code : nil)
                password = ""
            } catch let failure as MegaFailure where failure.needsTwoFactorCode {
                needsCode = true
                focus = .code
            } catch {
                self.error = error.localizedDescription
                code = ""
            }
        }
    }
}
