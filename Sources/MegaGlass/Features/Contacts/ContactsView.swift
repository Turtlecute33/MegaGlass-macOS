import SwiftUI
@preconcurrency import MEGASdk

nonisolated struct ContactRow: Identifiable, Sendable {
    let id: UInt64
    let email: String
}

nonisolated struct RequestRow: Identifiable, Sendable {
    let id: UInt64
    let email: String
    let message: String?
    let date: Date?
    let outgoing: Bool
}

struct ContactsView: View {
    @Environment(AppModel.self) private var app
    @State private var contacts: [ContactRow] = []
    @State private var requests: [RequestRow] = []
    @State private var inviting = false

    var body: some View {
        List {
            let incoming = requests.filter { !$0.outgoing }
            let outgoing = requests.filter(\.outgoing)
            if !incoming.isEmpty {
                Section("Requests") {
                    ForEach(incoming) { request in
                        HStack {
                            avatar(request.email)
                            VStack(alignment: .leading) {
                                Text(request.email)
                                if let message = request.message, !message.isEmpty {
                                    Text(message).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Ignore") { reply(request, .ignore) }
                            Button("Decline") { reply(request, .deny) }
                            Button("Accept") { reply(request, .accept) }
                                .buttonStyle(.glassProminent)
                        }
                    }
                }
            }
            Section("Contacts") {
                if contacts.isEmpty {
                    Text("No contacts yet.").foregroundStyle(.secondary)
                }
                ForEach(contacts) { contact in
                    HStack {
                        avatar(contact.email)
                        Text(contact.email)
                        Spacer()
                    }
                    .contextMenu {
                        Button("Copy Email") {
                            Pasteboard.copy(contact.email)
                        }
                        Button("Remove Contact", role: .destructive) { remove(contact) }
                    }
                }
            }
            if !outgoing.isEmpty {
                Section("Sent Invitations") {
                    ForEach(outgoing) { request in
                        HStack {
                            avatar(request.email)
                            Text(request.email)
                            Spacer()
                            Button("Remind") { invite(request.email, action: .remind) }
                            Button("Cancel") { invite(request.email, action: .delete) }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle("Contacts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { inviting = true } label: { Label("Add Contact", systemImage: "person.badge.plus") }
            }
        }
        .task(id: app.engine.contactsRevision) { await load() }
        .sheet(isPresented: $inviting) {
            NameSheet(title: "Invite a Contact", action: "Send Invitation", initial: "") { email in
                invite(email, action: .add)
            }
        }
    }

    private func avatar(_ email: String) -> some View {
        Text(email.prefix(1).uppercased())
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(Color(hue: Double(email.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % 360) / 360, saturation: 0.55, brightness: 0.75), in: .circle)
    }

    private func load() async {
        let sdk = app.engine.sdk
        let result = await EngineQueue.run { () -> ([ContactRow], [RequestRow]) in
            let users = sdk.contacts()
            let contacts = (0..<users.size).compactMap { users.user(at: $0) }
                .filter { $0.visibility == .visible }
                .map { ContactRow(id: $0.handle, email: $0.email ?? "") }
                .sorted { $0.email < $1.email }
            func rows(_ list: MEGAContactRequestList, outgoing: Bool) -> [RequestRow] {
                (0..<list.size).compactMap { list.contactRequest(at: $0) }.map {
                    RequestRow(id: $0.handle, email: (outgoing ? $0.targetEmail : $0.sourceEmail) ?? "",
                               message: $0.sourceMessage, date: $0.creationTime, outgoing: outgoing)
                }
            }
            return (contacts, rows(sdk.incomingContactRequests(), outgoing: false) + rows(sdk.outgoingContactRequests(), outgoing: true))
        }
        guard !Task.isCancelled else { return }
        contacts = result.0
        requests = result.1
    }

    private func reply(_ request: RequestRow, _ action: MEGAReplyAction) {
        let sdk = app.engine.sdk
        let id = request.id
        Task {
            // The request lists take the engine lock: not on the main thread.
            let target = await EngineQueue.run {
                let list = sdk.incomingContactRequests()
                return (0..<list.size).compactMap { list.contactRequest(at: $0) }.first { $0.handle == id }
            }
            guard let target else { return }
            do {
                _ = try await sdk.request { sdk.reply(target, action: action, delegate: $0) }
            } catch {
                app.show(error)
            }
        }
    }

    private func invite(_ email: String, action: MEGAInviteAction) {
        let sdk = app.engine.sdk
        Task {
            do {
                _ = try await sdk.request { sdk.inviteContact(withEmail: email, message: nil, action: action, delegate: $0) }
                if action == .add { app.notify("Invitation sent", symbol: "paperplane") }
            } catch {
                app.show(error)
            }
        }
    }

    private func remove(_ contact: ContactRow) {
        let sdk = app.engine.sdk
        let email = contact.email
        Task {
            guard let user = await EngineQueue.run({ sdk.contact(forEmail: email) }) else { return }
            do {
                _ = try await sdk.request { sdk.removeContactUser(user, delegate: $0) }
            } catch {
                app.show(error)
            }
        }
    }
}
