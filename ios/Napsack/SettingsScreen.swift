import PhotosUI
import SwiftUI

/// Your profile and account, the Profile tab: your name, picture, and birthday, your username,
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
    /// Nil until you set it (Nate, 2026-10-30: one field, unset by default, saved as it's set).
    @State private var birthday: Date?
    @State private var pickingBirthday = false
    @State private var withYear = false
    @State private var birthdaySaves = LatestSave()
    @State private var profileNote: String?
    @State private var serverLabel: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    // Tap it to see it big, as on the web.
                    Avatar(kind: .friend(account.user.id), avatarId: profile?.profile?.avatarId, name: account.user.username, size: 64, enlarges: true)
                    VStack(alignment: .leading, spacing: 6) {
                        PhotosPicker(profile?.profile?.avatarId == nil ? "Choose a picture" : "Change picture", selection: $picked, matching: .images)
                        if profile?.profile?.avatarId != nil {
                            Button("Remove picture", role: .destructive) { change { try await $0.removePicture() } }
                        }
                    }
                    .buttonStyle(.borderless)  // each its own tap, not the whole row's
                }
                HStack {
                    TextField("Your name, for friends", text: $name).textContentType(.name).onSubmit(saveName)
                    Button("Save", action: saveName).disabled(name == (profile?.profile?.displayName ?? ""))
                }
                Button { withAnimation { pickingBirthday.toggle() } } label: {
                    LabeledContent("Birthday", value: birthday.map { Self.words($0, withYear: withYear) } ?? "Not set")
                }
                .foregroundStyle(.primary)
                .accessibilityHint(pickingBirthday ? "Hides the date picker" : "Shows a date picker")
                if pickingBirthday {
                    // Starts somewhere neutral; nothing is saved until it's turned.
                    DatePicker("Birthday", selection: Binding(get: { birthday ?? Self.wheelStart }, set: { birthday = $0; saveBirthday() }),
                               in: Self.earliestBirthday...Date.now, displayedComponents: .date)
                        .datePickerStyle(.wheel).labelsHidden()
                }
                if birthday != nil {
                    Toggle("Show the year", isOn: Binding(get: { withYear }, set: { withYear = $0; saveBirthday() }))
                    Button("Remove birthday", role: .destructive) {
                        withAnimation { birthday = nil; pickingBirthday = false }
                        saveBirthday()
                    }
                }
            } footer: {
                Text(profileNote ?? "Your friends see your name, picture, and birthday. They aren't end-to-end encrypted.")
            }
            Section {
                Toggle("Share when I'm active", isOn: Binding(get: { account.user.shareActivity ?? true }, set: { on in
                    Task {
                        do { try await session.setShareActivity(on) } catch {
                            note = error.localizedDescription
                            session.noticed(error)
                        }
                    }
                }))
            } footer: {
                Text("Friends see when you're active or typing, and you see theirs. It goes both ways: turn it off and you see nobody's.")
            }
            Section("Account") {
                LabeledContent("Username", value: "@\(account.user.username)")
                if let name = account.user.displayName { LabeledContent("Name", value: name) }
                if let serverLabel { LabeledContent("Server", value: serverLabel) }  // not in production
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
                    NavigationLink("Developer") { DeveloperScreen() }
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
        .navigationTitle("Profile")
        .task { await loadSecurity() }
        .task { await loadProfile() }
        .task { serverLabel = AppInfo.serverLabel(environment: (try? await Server(AppInfo.server).config())?.environment) }
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
                withYear = b.year != nil
                birthday = Calendar.current.date(from: DateComponents(year: b.year ?? 2000, month: b.month, day: b.day))
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

    /// Saves the birthday as it is now: a moment after the wheel stops, one
    /// save at a time and in order, so the last one set is the one kept.
    private func saveBirthday() {
        guard let profile else { return }
        let parts = birthday.map { Calendar.current.dateComponents([.year, .month, .day], from: $0) }
        let year = withYear ? parts?.year : nil
        birthdaySaves.save {
            try await profile.setBirthday(month: parts?.month, day: parts?.day, year: year)
        } done: { error in
            profileNote = error?.localizedDescription ?? "Saved."
            if let error { session.noticed(error) }
        }
    }

    static let earliestBirthday = Calendar.current.date(from: DateComponents(year: 1900, month: 1, day: 1))!  // as the server allows
    static let wheelStart = Calendar.current.date(from: DateComponents(year: 2000, month: 1, day: 1))!

    /// "March 4", or "March 4, 1990" with the year.
    static func words(_ date: Date, withYear: Bool) -> String {
        withYear ? date.formatted(.dateTime.month(.wide).day().year()) : date.formatted(.dateTime.month(.wide).day())
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
