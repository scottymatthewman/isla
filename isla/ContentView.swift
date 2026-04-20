import SwiftUI
import AppKit

private enum SecretSortOption: String, CaseIterable, Identifiable {
    case updatedNewest = "Updated (Newest)"
    case updatedOldest = "Updated (Oldest)"
    case keyAToZ = "Key (A-Z)"
    case keyZToA = "Key (Z-A)"

    var id: String { rawValue }
}

private enum ProviderFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case withProvider = "Has Provider"
    case withoutProvider = "No Provider"

    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject private var store: AppStore

    @State private var selectedWorkspaceID: UUID?
    @State private var showNewWorkspace = false
    @State private var showNewSecret = false
    @State private var showRenameWorkspace = false
    @State private var showDeleteWorkspaceConfirmation = false
    @State private var searchText = ""
    @State private var createSecretError: String?
    @State private var hoveredSecretID: UUID?
    @State private var editingSecret: Secret?
    @State private var deletingSecret: Secret?
    @State private var copiedIndicator: CopiedIndicator?
    @State private var selectedEnvironmentFilters: Set<String> = []
    @State private var providerFilter: ProviderFilter = .all
    @State private var sortOption: SecretSortOption = .updatedNewest

    private var filteredSecrets: [Secret] {
        guard let selectedWorkspaceID else { return [] }
        let base = store.secrets(in: selectedWorkspaceID)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.filter { secret in
            let provider = secret.provider ?? ""
            let environmentText = secret.environments.map(displayName(forEnvironment:)).joined(separator: " ")
            let matchesSearch = query.isEmpty ||
                secret.key.localizedCaseInsensitiveContains(query) ||
                environmentText.localizedCaseInsensitiveContains(query) ||
                provider.localizedCaseInsensitiveContains(query)
            let matchesEnvironment = selectedEnvironmentFilters.isEmpty ||
                !Set(secret.environments).isDisjoint(with: selectedEnvironmentFilters)
            let hasProvider = !(secret.provider?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let matchesProvider: Bool
            switch providerFilter {
            case .all:
                matchesProvider = true
            case .withProvider:
                matchesProvider = hasProvider
            case .withoutProvider:
                matchesProvider = !hasProvider
            }
            return matchesSearch && matchesEnvironment && matchesProvider
        }
    }

    private var visibleSecrets: [Secret] {
        switch sortOption {
        case .updatedNewest:
            return filteredSecrets.sorted { $0.updatedAt > $1.updatedAt }
        case .updatedOldest:
            return filteredSecrets.sorted { $0.updatedAt < $1.updatedAt }
        case .keyAToZ:
            return filteredSecrets.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        case .keyZToA:
            return filteredSecrets.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedDescending }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            secretTableView
        }
        .navigationTitle("Isla")
        .sheet(isPresented: $showNewWorkspace) {
            WorkspaceSheet(title: "New Workspace", confirmTitle: "Create", initialName: "") { name in
                store.addWorkspace(name: name)
            }
        }
        .sheet(isPresented: $showNewSecret) {
            NewSecretSheet(
                workspaceID: selectedWorkspaceID,
                workspaces: store.workspaces
            ) { workspaceID, key, value, environments, provider in
                do {
                    try store.addSecret(
                        workspaceID: workspaceID,
                        key: key,
                        value: value,
                        environments: environments,
                        provider: provider
                    )
                    createSecretError = nil
                } catch {
                    createSecretError = (error as? LocalizedError)?.errorDescription ?? "Could not save secret value to Keychain."
                }
            }
        }
        .sheet(item: $editingSecret) { secret in
            EditSecretSheet(secret: secret) { key, value, environments, provider in
                do {
                    try store.updateSecret(
                        secretID: secret.id,
                        key: key,
                        value: value,
                        environments: environments,
                        provider: provider
                    )
                    createSecretError = nil
                } catch {
                    createSecretError = (error as? LocalizedError)?.errorDescription ?? "Could not update secret."
                }
            }
        }
        .sheet(isPresented: $showRenameWorkspace) {
            if let selectedWorkspaceID, let workspace = store.workspace(id: selectedWorkspaceID) {
                WorkspaceSheet(
                    title: "Rename Workspace",
                    confirmTitle: "Save",
                    initialName: workspace.name
                ) { name in
                    store.renameWorkspace(workspaceID: workspace.id, newName: name)
                }
            }
        }
        .alert("Delete workspace?", isPresented: $showDeleteWorkspaceConfirmation) {
            Button("Delete", role: .destructive) {
                if let selectedWorkspaceID {
                    store.deleteWorkspace(workspaceID: selectedWorkspaceID)
                    self.selectedWorkspaceID = store.workspaces.first?.id
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This deletes all secrets in the workspace.")
        }
        .alert("Delete secret?", isPresented: Binding(
            get: { deletingSecret != nil },
            set: { if !$0 { deletingSecret = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let deletingSecret {
                    store.deleteSecret(secretID: deletingSecret.id)
                    self.deletingSecret = nil
                }
            }
            Button("Cancel", role: .cancel) {
                deletingSecret = nil
            }
        } message: {
            Text("Delete \(deletingSecret?.key ?? "this secret")? This cannot be undone.")
        }
        .onAppear {
            if selectedWorkspaceID == nil {
                selectedWorkspaceID = store.workspaces.first?.id
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedWorkspaceID) {
            ForEach(store.workspaces.sorted(by: { $0.name < $1.name })) { workspace in
                Label(workspace.name, systemImage: "folder")
                    .tag(workspace.id)
                    .contextMenu {
                        Button("Rename Workspace") {
                            selectedWorkspaceID = workspace.id
                            showRenameWorkspace = true
                        }
                        Button("Delete Workspace", role: .destructive) {
                            selectedWorkspaceID = workspace.id
                            showDeleteWorkspaceConfirmation = true
                        }
                    }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showNewWorkspace = true
                } label: {
                    Label("New Workspace", systemImage: "folder.badge.plus")
                }

                if selectedWorkspaceID != nil {
                    Button {
                        showRenameWorkspace = true
                    } label: {
                        Label("Rename Workspace", systemImage: "pencil")
                    }
                }
            }
        }
    }

    private var secretTableView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Secrets")
                    .font(.title2)
                    .bold()
                Spacer()
                Button {
                    showNewSecret = true
                } label: {
                    Label("New Secret", systemImage: "plus")
                }
                .disabled(selectedWorkspaceID == nil)
            }

            HStack(spacing: 12) {
                TextField("Search secrets", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Picker("Provider", selection: $providerFilter) {
                    ForEach(ProviderFilter.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                Picker("Sort", selection: $sortOption) {
                    ForEach(SecretSortOption.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .frame(width: 180)
            }

            HStack(spacing: 8) {
                EnvironmentFilterPill(title: "Dev", isSelected: selectedEnvironmentFilters.contains("dev")) {
                    toggleEnvironmentFilter("dev")
                }
                EnvironmentFilterPill(title: "Stagin", isSelected: selectedEnvironmentFilters.contains("staging")) {
                    toggleEnvironmentFilter("staging")
                }
                EnvironmentFilterPill(title: "Prod", isSelected: selectedEnvironmentFilters.contains("prod")) {
                    toggleEnvironmentFilter("prod")
                }
                if !selectedEnvironmentFilters.isEmpty {
                    Button("Clear") {
                        selectedEnvironmentFilters.removeAll()
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
            }

            if let createSecretError {
                Text(createSecretError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if selectedWorkspaceID == nil {
                ContentUnavailableView("Select a workspace", systemImage: "sidebar.left")
            } else if visibleSecrets.isEmpty {
                ContentUnavailableView(
                    filteredSecrets.isEmpty && !searchText.isEmpty ? "No matching secrets" : "No secrets yet",
                    systemImage: "key"
                )
            } else {
                VStack(spacing: 0) {
                    SecretTableHeaderRow()
                    ForEach(visibleSecrets) { secret in
                        SecretTableRow(
                            secret: secret,
                            environmentText: secret.environments.map(displayName(forEnvironment:)).joined(separator: ", "),
                            isHovered: hoveredSecretID == secret.id,
                            isKeyCopied: copiedIndicator == .key(secret.id),
                            isValueCopied: copiedIndicator == .value(secret.id),
                            onCopyKey: {
                                copySecretKey(secret)
                            },
                            onCopyValue: {
                                copySecretValue(secret)
                            },
                            onEdit: {
                                editingSecret = secret
                            },
                            onDelete: {
                                deletingSecret = secret
                            }
                        )
                        .onHover { isHovering in
                            if isHovering {
                                hoveredSecretID = secret.id
                            } else if hoveredSecretID == secret.id {
                                hoveredSecretID = nil
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func copySecretValue(_ secret: Secret) {
        if let value = store.readSecretValue(secretID: secret.id) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copiedIndicator = .value(secret.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if copiedIndicator == .value(secret.id) {
                    copiedIndicator = nil
                }
            }
        }
    }

    private func copySecretKey(_ secret: Secret) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(secret.key, forType: .string)
        copiedIndicator = .key(secret.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if copiedIndicator == .key(secret.id) {
                copiedIndicator = nil
            }
        }
    }

    private func toggleEnvironmentFilter(_ environment: String) {
        if selectedEnvironmentFilters.contains(environment) {
            selectedEnvironmentFilters.remove(environment)
        } else {
            selectedEnvironmentFilters.insert(environment)
        }
    }

    private func displayName(forEnvironment environment: String) -> String {
        switch environment.lowercased() {
        case "dev":
            return "Dev"
        case "staging":
            return "Staging"
        case "prod":
            return "Prod"
        default:
            return environment
        }
    }
}

private enum CopiedIndicator: Equatable {
    case key(UUID)
    case value(UUID)
}

private struct SecretTableHeaderRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Key")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Value")
                .frame(width: 130, alignment: .leading)
            Text("Environment")
                .frame(width: 170, alignment: .leading)
            Text("Provider")
                .frame(width: 150, alignment: .leading)
            Text("Updated")
                .frame(width: 170, alignment: .leading)
            Text("Actions")
                .frame(width: 80, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.12))
    }
}

private struct SecretTableRow: View {
    let secret: Secret
    let environmentText: String
    let isHovered: Bool
    let isKeyCopied: Bool
    let isValueCopied: Bool
    let onCopyKey: () -> Void
    let onCopyValue: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(secret.key)
                    .lineLimit(1)
                Button {
                    onCopyKey()
                } label: {
                    Image(systemName: isKeyCopied ? "checkmark.circle.fill" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy key")
                .opacity(isHovered ? 1 : 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Text("••••••••")
                    .font(.body.monospaced())
                Button {
                    onCopyValue()
                } label: {
                    Image(systemName: isValueCopied ? "checkmark.circle.fill" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy value")
                .opacity(isHovered ? 1 : 0)
            }
            .frame(width: 130, alignment: .leading)

            Text(environmentText)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .frame(width: 170, alignment: .leading)

            Text(secret.provider?.isEmpty == false ? secret.provider! : "—")
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)

            Text(secret.updatedAt, style: .date)
                .foregroundStyle(.secondary)
                .frame(width: 170, alignment: .leading)

            HStack(spacing: 6) {
                Button {
                    onEdit()
                } label: {
                    Image(systemName: "pencil")
                }
                .help("Edit secret")

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete secret")
            }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .opacity(isHovered ? 1 : 0)
            .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovered ? Color.accentColor.opacity(0.08) : Color.clear)
    }
}

private struct EnvironmentFilterPill: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15))
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
            )
    }
}

private struct WorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    let title: String
    let confirmTitle: String
    let onSave: (String) -> Void

    init(title: String, confirmTitle: String, initialName: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.confirmTitle = confirmTitle
        self._name = State(initialValue: initialName)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3)
                .bold()
            TextField("Workspace name", text: $name)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(confirmTitle) {
                    onSave(name.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 360)
    }
}

private struct NewSecretSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var chosenWorkspaceID: UUID?
    @State private var key = ""
    @State private var value = ""
    @State private var selectedEnvironments: Set<String> = ["dev"]
    @State private var provider = ""

    let workspaceID: UUID?
    let workspaces: [Workspace]
    let onSave: (UUID, String, String, [String], String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Secret")
                .font(.title3)
                .bold()

            Picker("Workspace", selection: $chosenWorkspaceID) {
                Text("Select workspace").tag(UUID?.none)
                ForEach(workspaces.sorted(by: { $0.name < $1.name })) { workspace in
                    Text(workspace.name).tag(Optional(workspace.id))
                }
            }

            TextField("Key (e.g. OPENAI_API_KEY)", text: $key)
            SecureField("Secret value", text: $value)
            EnvironmentSelectorRow(selectedEnvironments: $selectedEnvironments)
            TextField("Provider (optional)", text: $provider)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    guard let chosenWorkspaceID else { return }
                    let environments = selectedEnvironments.sorted()
                    onSave(chosenWorkspaceID, key, value, environments, provider.isEmpty ? nil : provider)
                    dismiss()
                }
                .disabled(
                    chosenWorkspaceID == nil ||
                    key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    selectedEnvironments.isEmpty
                )
            }
        }
        .padding()
        .frame(width: 520)
        .onAppear {
            chosenWorkspaceID = workspaceID ?? workspaces.first?.id
        }
    }
}

private struct EditSecretSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key: String
    @State private var value = ""
    @State private var selectedEnvironments: Set<String>
    @State private var provider: String

    let secret: Secret
    let onSave: (String, String?, [String], String?) -> Void

    init(secret: Secret, onSave: @escaping (String, String?, [String], String?) -> Void) {
        self.secret = secret
        self._key = State(initialValue: secret.key)
        self._selectedEnvironments = State(initialValue: Set(secret.environments))
        self._provider = State(initialValue: secret.provider ?? "")
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Secret")
                .font(.title3)
                .bold()

            TextField("Key", text: $key)
            SecureField("New value (optional)", text: $value)
            EnvironmentSelectorRow(selectedEnvironments: $selectedEnvironments)
            TextField("Provider (optional)", text: $provider)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(
                        key,
                        value.isEmpty ? nil : value,
                        selectedEnvironments.sorted(),
                        provider.isEmpty ? nil : provider
                    )
                    dismiss()
                }
                .disabled(
                    key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    selectedEnvironments.isEmpty
                )
            }
        }
        .padding()
        .frame(width: 520)
    }
}

private struct EnvironmentSelectorRow: View {
    @Binding var selectedEnvironments: Set<String>
    private let options: [(key: String, title: String)] = [
        ("dev", "Dev"),
        ("staging", "Staging"),
        ("prod", "Prod")
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.key) { option in
                Button(option.title) {
                    if selectedEnvironments.contains(option.key) {
                        selectedEnvironments.remove(option.key)
                    } else {
                        selectedEnvironments.insert(option.key)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(selectedEnvironments.contains(option.key) ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15))
                )
                .overlay(
                    Capsule()
                        .stroke(selectedEnvironments.contains(option.key) ? Color.accentColor : Color.clear, lineWidth: 1)
                )
            }
            Spacer()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppStore())
}
