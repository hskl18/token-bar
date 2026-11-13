import SwiftUI

/// Token Bar's settings: which detected accounts get a quota row.
struct SettingsView: View {
    @EnvironmentObject private var store: TokenBarStore

    var body: some View {
        Form {
            accountSection("Claude", provider: .claude)
            accountSection("Codex", provider: .codex)
            if !KiroSource.detected.isEmpty {
                Section("Kiro") {
                    ForEach(KiroSource.detected, id: \.self) { source in
                        toggle(source.name, path: source.path)
                    }
                }
            }
            Section {
            } footer: {
                Text("An unchecked account has no quota row and gets no quota requests. Claude and Codex local history still counts in the activity totals.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func accountSection(_ title: String, provider: ProviderScope) -> some View {
        Section {
            ForEach(store.settingsAccounts.filter { $0.provider == provider }, id: \.self) { account in
                toggle(AccountSource.title(for: account.url), path: account.directory)
            }
        } header: {
            Text(title)
        }
    }

    private func toggle(_ name: String, path: String) -> some View {
        Toggle(isOn: Binding(
            get: { !store.snapshot.isHidden(path) },
            set: { store.setAccount(path, shown: $0) }
        )) {
            Text(name)
            Text((path as NSString).abbreviatingWithTildeInPath)
        }
        .toggleStyle(.checkbox)
    }
}
