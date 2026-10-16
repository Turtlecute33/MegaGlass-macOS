import CoreImage.CIFilterBuiltins
import SwiftUI
@preconcurrency import MEGASdk

struct AccountView: View {
    @Environment(AppModel.self) private var app
    @State private var versionsEnabled: Bool?
    @State private var twoFactorSetup = false
    @State private var twoFactorDisable = false
    @State private var changingPassword = false
    @State private var confirmLogout = false
    @State private var confirmDeleteVersions = false
    @State private var confirmEmptyRubbish = false

    private var session: Session { app.session }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                profile
                if let account = session.account {
                    storage(account)
                }
                security
                files
            }
            .padding(24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Account")
        .task {
            await session.refreshAccount()
            await loadVersionsOption()
            // The check after login can fail (no network): try again here.
            if session.twoFactorEnabled == nil { await session.refreshTwoFactor() }
        }
        .sheet(isPresented: $twoFactorSetup) { TwoFactorSetupSheet() }
        .sheet(isPresented: $twoFactorDisable) {
            CodeSheet(title: "Turn Off Two-Factor Authentication", action: "Turn Off") { code in
                try await session.disableTwoFactor(code: code)
            }
        }
        .sheet(isPresented: $changingPassword) { PasswordSheet() }
        .confirmationDialog("Log out of MEGA?", isPresented: $confirmLogout) {
            Button("Log Out", role: .destructive) { Task { await session.signOut() } }
        } message: {
            Text("Syncs stop, and the account cache and thumbnails on this Mac are deleted. Open links stay until you close them.")
        }
        .confirmationDialog("Delete all previous versions?", isPresented: $confirmDeleteVersions) {
            Button("Delete Versions", role: .destructive) {
                let sdk = app.engine.sdk
                Task {
                    do {
                        _ = try await sdk.request { sdk.removeVersions(with: $0) }
                        app.notify("Previous versions deleted", symbol: "clock.badge.xmark")
                        await session.refreshAccount()
                    } catch {
                        app.show(error)
                    }
                }
            }
        } message: {
            Text("Current files stay. Only their older versions are deleted.")
        }
        .confirmationDialog("Empty the Rubbish Bin?", isPresented: $confirmEmptyRubbish) {
            Button("Empty Rubbish Bin", role: .destructive) { Task { await app.emptyRubbishBin() } }
        } message: {
            Text("All items in the Rubbish Bin will be deleted permanently.")
        }
    }

    private var profile: some View {
        HStack(spacing: 16) {
            Text(String((session.displayName ?? session.email ?? "?").prefix(1)).uppercased())
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(Color.megaRed.gradient, in: .circle)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayName ?? "MEGA Account").font(.title2.weight(.semibold))
                Text(session.email ?? "").foregroundStyle(.secondary)
                if let account = session.account {
                    Text(account.plan + (account.renews.map { " · until " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.megaRed.opacity(0.15), in: .capsule)
                }
            }
            Spacer()
            Button("Log Out…") { confirmLogout = true }
                .buttonStyle(.glass)
        }
        .padding(20)
        .glassPanel(cornerRadius: 22)
    }

    private func storage(_ account: AccountSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Storage").font(.headline)
            UsageBar(fraction: account.storageFraction, height: 10)
            Text("\(Format.bytes(account.storageUsed)) of \(Format.bytes(account.storageMax)) used")
                .font(.callout)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                usage("Cloud Drive", account.cloudUsed, .megaRed)
                usage("Backups", account.backupsUsed, .orange)
                usage("Rubbish Bin", account.rubbishUsed, .gray)
                usage("Versions", account.versionsUsed, .purple)
            }
            .font(.callout)
            if account.transferMax > 0 {
                Divider()
                Text("Transfer quota").font(.headline)
                UsageBar(fraction: account.transferFraction, height: 10)
                Text("\(Format.bytes(account.transferUsed)) of \(Format.bytes(account.transferMax)) used")
                    .font(.callout)
            }
        }
        .padding(20)
        .glassPanel(cornerRadius: 22)
    }

    private func usage(_ title: String, _ value: Int64, _ color: Color) -> some View {
        GridRow {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(title)
            Text(Format.bytes(value)).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var security: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Security").font(.headline)
            HStack {
                Label("Two-factor authentication", systemImage: "lock.shield")
                Spacer()
                switch session.twoFactorEnabled {
                case .some(true):
                    Text("On").foregroundStyle(.green)
                    Button("Turn Off…") { twoFactorDisable = true }
                case .some(false):
                    Text("Off").foregroundStyle(.orange)
                    Button("Turn On…") { twoFactorSetup = true }
                        .buttonStyle(.glassProminent)
                case .none:
                    ProgressView().controlSize(.small)
                }
            }
            HStack {
                Label("Password", systemImage: "key")
                Spacer()
                Button("Change Password…") { changingPassword = true }
            }
        }
        .padding(20)
        .glassPanel(cornerRadius: 22)
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Files").font(.headline)
            if let versionsEnabled {
                Toggle(isOn: Binding(get: { versionsEnabled }, set: { setVersions($0) })) {
                    VStack(alignment: .leading) {
                        Text("Keep file versions")
                        Text("MEGA keeps older versions when you change a file.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Text("Previous versions use \(Format.bytes(session.account?.versionsUsed ?? 0)).")
                Spacer()
                Button("Delete All Versions…") { confirmDeleteVersions = true }
            }
            HStack {
                Text("The Rubbish Bin uses \(Format.bytes(session.account?.rubbishUsed ?? 0)).")
                Spacer()
                Button("Empty Rubbish Bin…") { confirmEmptyRubbish = true }
                    .disabled(session.account?.rubbishUsed == 0)
            }
        }
        .padding(20)
        .glassPanel(cornerRadius: 22)
    }

    private func loadVersionsOption() async {
        let sdk = app.engine.sdk
        // The engine stores "disable versions"; a missing value means versions are on.
        let request = try? await sdk.request(accepting: [.apiENoent]) { sdk.getFileVersionsOption(with: $0) }
        versionsEnabled = !(request?.flag ?? false)
    }

    private func setVersions(_ enabled: Bool) {
        let sdk = app.engine.sdk
        versionsEnabled = enabled
        Task {
            do {
                _ = try await sdk.request { sdk.setFileVersionsOption(!enabled, delegate: $0) }
            } catch {
                app.show(error)
                await loadVersionsOption()
            }
        }
    }
}

private struct TwoFactorSetupSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var secret: String?
    @State private var code = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Turn On Two-Factor Authentication").font(.headline)
            Text("Scan the code with an authenticator app, then enter the 6-digit code it shows.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let secret, let image = qrCode(for: secret) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 180, height: 180)
                    .padding(10)
                    .background(.white, in: .rect(cornerRadius: 12))
                // Not selectable: the Copy button keeps the secret on this Mac and out of
                // clipboard histories.
                HStack(spacing: 8) {
                    Text(secret)
                        .font(.caption.monospaced())
                    Button("Copy") { Pasteboard.copy(secret) }
                        .controlSize(.small)
                }
            } else {
                ProgressView().frame(height: 200)
            }
            TextField("Code", text: $code)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .font(.title3.monospacedDigit())
                .frame(width: 160)
                .onChange(of: code) { _, value in code = String(value.filter(\.isNumber).prefix(6)) }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Turn On") {
                    Task {
                        do {
                            try await app.session.enableTwoFactor(code: code)
                            app.notify("Two-factor authentication is on", symbol: "lock.shield")
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(code.count != 6)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
        .task {
            do {
                secret = try await app.session.twoFactorSecret()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func qrCode(for secret: String) -> CGImage? {
        let account = app.session.email ?? "MEGA"
        let uri = "otpauth://totp/MEGA:\(account)?secret=\(secret)&issuer=MEGA"
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(uri.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

struct CodeSheet: View {
    let title: String
    let action: String
    let perform: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 14) {
            Text(title).font(.headline)
            TextField("6-digit code", text: $code)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(width: 180)
                .onChange(of: code) { _, value in code = String(value.filter(\.isNumber).prefix(6)) }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Button(action) {
                    Task {
                        do {
                            try await perform(code)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(code.count != 6)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }
}

private struct PasswordSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var repeated = ""
    @State private var code = ""
    @State private var error: String?

    /// The code field shows also when the two-factor state is unknown (its check failed).
    private var twoFactor: Bool { app.session.twoFactorEnabled != false }
    private var needsCode: Bool { app.session.twoFactorEnabled == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change Password").font(.headline)
            SecureField("Current password", text: $current)
            SecureField("New password", text: $new)
            SecureField("Repeat new password", text: $repeated)
            if twoFactor {
                TextField(needsCode ? "Two-factor code" : "Two-factor code (if it is on)", text: $code)
            }
            if !new.isEmpty, new.count < 8 {
                Text("Use 8 or more characters.").font(.caption).foregroundStyle(.orange)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Change") {
                    Task {
                        do {
                            try await app.session.changePassword(current: current, new: new, code: twoFactor ? code : nil)
                            app.notify("Password changed", symbol: "key")
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(new.count < 8 || new != repeated || current.isEmpty
                          || ((needsCode || !code.isEmpty) && code.count != 6))
                .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(width: 380)
    }
}
