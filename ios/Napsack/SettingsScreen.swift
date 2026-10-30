import PhotosUI
import SwiftUI

/// Your account, from the person button on the chat list: your username,
/// the account's safety (recovery key, password, other devices), the
/// debugging tools for Admins, and signing out. The words are the web app's
/// Security panel's.
struct SettingsScreen: View {
    @Environment(Session.self) private var session
    let account: Account
    @State private var security: Session.Security?
    @State private var note: String?
    @State private var asking: PasswordSheet.Purpose?
    @State private var confirmingEndOthers = false
    @State private var signingOut = false
    @State private var profile: ProfileModel?
    @State private var name = ""
    @State private var picked: PhotosPickerItem?
    @State private var hasBirthday = false
    @State private var birthday = Date()
    @State private var withYear = false
    @State private var profileNote: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Avatar(kind: .friend(account.user.id), avatarId: profile?.profile?.avatarId, name: account.user.username, size: 64)
                    VStack(alignment: .leading, spacing: 6) {
                        PhotosPicker(profile?.profile?.avatarId == nil ? "Choose a picture" : "Change picture", selection: $picked, matching: .images)
                        if profile?.profile?.avatarId != nil {
                            Button("Remove picture", role: .destructive) { change { try await $0.removePicture() } }
                        }
                    }
                }
                HStack {
                    TextField("Your name, for friends", text: $name).textContentType(.name).onSubmit(saveName)
                    Button("Save", action: saveName).disabled(name == (profile?.profile?.displayName ?? ""))
                }
                Toggle("Birthday", isOn: $hasBirthday.animation())
                if hasBirthday {
                    DatePicker("Date", selection: $birthday, in: ...Date.now, displayedComponents: .date)
                    Toggle("Show the year", isOn: $withYear)
                    Button("Save birthday") { saveBirthday() }
                }
            } header: {
                Text("Profile")
            } footer: {
                Text(profileNote ?? "Your friends see your name, picture, and birthday. They aren't end-to-end encrypted.")
            }
            Section("Account") {
                LabeledContent("Username", value: "@\(account.user.username)")
                if let name = account.user.displayName { LabeledContent("Name", value: name) }
                LabeledContent("Server", value: URL(string: account.server)?.host() ?? account.server)
                Button("Change username") { asking = .username }
            }
            Section {
                Text(status).foregroundStyle(.secondary)
                Button(account.user.hasRecoveryKey ? "Make a new recovery key" : "Make a recovery key") { asking = .recovery }
                Button("Change password") { asking = .password }
                Button("Sign out other devices") { confirmingEndOthers = true }
                    .disabled((security?.activeSessions ?? 2) <= 1)
            } header: {
                Text("Security")
            } footer: {
                if let note { Text(note) }
            }
            if account.user.isAdmin {  // debugging tools: Admins only, for now
                Section {
                    NavigationLink("Developer") { DeveloperScreen(signedInTo: account.server) }
                }
            }
            Section {
                Button("Sign out", role: .destructive) {
                    signingOut = true
                    Task { await session.signOut() }
                }
                .disabled(signingOut)
            }
        }
        .navigationTitle("Settings")
        .task { await loadSecurity() }
        .task { await loadProfile() }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task {
                defer { picked = nil }
                guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                    profileNote = "Couldn't open that picture."
                    return
                }
                change { try await $0.setPicture(image) }
            }
        }
        .onChange(of: hasBirthday) { _, on in
            if !on, profile?.profile?.birthday != nil { change { try await $0.setBirthday(month: nil, day: nil, year: nil) } }
        }
        .sheet(item: $asking) { purpose in
            PasswordSheet(purpose: purpose, hasRecoveryKey: account.user.hasRecoveryKey) { note = $0; Task { await loadSecurity() } }
        }
        .confirmationDialog("Sign out every other device?", isPresented: $confirmingEndOthers, titleVisibility: .visible) {
            Button("Sign out other devices", role: .destructive) { Task { await endOthers() } }
        } message: {
            Text("They'll need your password to sign in again. This phone stays signed in.")
        }
    }

    /// "Recovery key saved October 29, 2026. Signed in on 1 other device."
    private var status: String {
        guard let security else { return account.user.hasRecoveryKey ? "Recovery key saved." : "No recovery key yet." }
        let saved = security.recoverySetAt.map {
            "Recovery key saved \(Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .long, time: .omitted))."
        } ?? "No recovery key yet."
        let others = security.activeSessions - 1
        return saved + " " + (others > 0 ? "Signed in on \(others) other \(others == 1 ? "device" : "devices")." : "Not signed in anywhere else.")
    }

    private func loadProfile() async {
        let model = profile ?? ProfileModel(account: account)
        profile = model
        do {
            try await model.load(account.user.id)
            name = model.profile?.displayName ?? ""
            if let b = model.profile?.birthday {
                hasBirthday = true
                withYear = b.year != nil
                birthday = Calendar.current.date(from: DateComponents(year: b.year ?? 2000, month: b.month, day: b.day)) ?? .now
            }
        } catch {
            session.noticed(error)
        }
    }

    /// A change to your profile, then what it says now.
    private func change(_ work: @escaping (ProfileModel) async throws -> Void) {
        guard let profile else { return }
        Task {
            do {
                try await work(profile)
                profileNote = "Saved."
            } catch {
                profileNote = error.localizedDescription
                session.noticed(error)
            }
        }
    }

    private func saveName() { change { [name] in try await $0.setName(name) } }

    private func saveBirthday() {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: birthday)
        change { [withYear] in try await $0.setBirthday(month: parts.month, day: parts.day, year: withYear ? parts.year : nil) }
    }

    private func loadSecurity() async {
        do {
            security = try await session.security()
        } catch {
            Reporter.shared.report(.warn, "loading security failed", Reporter.fields(error))
            session.noticed(error)
        }
    }

    private func endOthers() async {
        do {
            let ended = try await session.endOtherSessions()
            note = ended > 0 ? "Signed out \(ended) other \(ended == 1 ? "device" : "devices")." : "No other devices were signed in."
            await loadSecurity()
        } catch {
            note = error.localizedDescription
            session.noticed(error)
        }
    }
}

/// Asks for the password (and what's new) for the changes that need it: the
/// key is unlocked with it and locked again, all on the phone.
struct PasswordSheet: View {
    enum Purpose: String, Identifiable {
        case password, recovery, username
        var id: String { rawValue }
    }

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let purpose: Purpose
    let hasRecoveryKey: Bool
    let done: (String) -> Void
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var username = ""
    @State private var working = false
    @State private var problem: String?
    /// A new recovery key, shown here once (the app's own sheet can't open over this one).
    @State private var newKey: String?

    var body: some View {
        if let newKey {
            RecoveryKeyScreen(key: newKey) { dismiss() }
        } else {
            form
        }
    }

    private var form: some View {
        NavigationStack {
            Form {
                Section {
                    if purpose == .username {
                        TextField("New username", text: $username)
                            .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    SecureField(purpose == .password ? "Current password" : "Password", text: $current)
                        .textContentType(.password)
                    if purpose == .password {
                        SecureField("New password", text: $new).textContentType(.newPassword)
                        SecureField("New password again", text: $confirm).textContentType(.newPassword)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(explanation)
                        if let problem { Text(problem).foregroundStyle(.red) }
                    }
                }
                Section {
                    Button(working ? working(purpose) : action, action: submit)
                        .disabled(working || current.isEmpty || (purpose == .password && new.isEmpty) || (purpose == .username && username.isEmpty))
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private var title: String {
        switch purpose {
        case .password: "Change password"
        case .recovery: "Recovery key"
        case .username: "Change username"
        }
    }

    private var action: String {
        switch purpose {
        case .password: "Change password"
        case .recovery: "Make a recovery key"
        case .username: "Change username"
        }
    }

    private func working(_ purpose: Purpose) -> String {
        purpose == .recovery ? "Unlocking…" : "Locking your keys…"
    }

    private var explanation: String {
        switch purpose {
        case .password:
            "Your messages stay readable: your key is locked again under the new password. Other devices will be signed out."
        case .recovery:
            hasRecoveryKey
                ? "Making a new recovery key replaces your old one, which stops working. Enter your password to continue."
                : "Enter your password to make a recovery key."
        case .username:
            "Your key is locked again under the new name, and you sign in with it from now on. Your old username stays yours."
        }
    }

    private func submit() {
        if purpose == .password {
            guard new.count >= 8 else { problem = "Passwords need at least 8 characters."; return }
            guard new == confirm else { problem = "The new passwords don't match."; return }
        }
        working = true
        problem = nil
        Task {
            defer { working = false }
            do {
                switch purpose {
                case .password:
                    let ended = try await session.changePassword(current: current, new: new)
                    done("Password changed." + (ended > 0 ? " Signed out \(ended) other \(ended == 1 ? "device" : "devices")." : ""))
                case .recovery:
                    try await session.makeRecoveryKey(password: current)
                    done("Recovery key saved.")
                    newKey = session.recoveryKeyToShow
                    session.recoveryKeyToShow = nil
                    return  // the key shows here; "I've saved it" closes the sheet
                case .username:
                    try await session.changeUsername(to: username, password: current)
                    done("Your username is now @\(session.account?.user.username ?? username). Sign in with it from now on.")
                }
                dismiss()
            } catch {
                problem = error.localizedDescription
                session.noticed(error)
            }
        }
    }
}
