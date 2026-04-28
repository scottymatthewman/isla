import SwiftUI
import AppKit
import UniformTypeIdentifiers

private enum SecretSortOption: String, CaseIterable, Identifiable {
    case updatedNewest = "Updated (Newest)"
    case updatedOldest = "Updated (Oldest)"
    case keyAToZ = "Key (A-Z)"
    case keyZToA = "Key (Z-A)"

    var id: String { rawValue }
}

private enum SecretSortColumn {
    case key
    case environment
    case provider
    case updatedAt
}

private enum ProviderFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case withProvider = "Has Provider"
    case withoutProvider = "No Provider"

    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var security: AppSecurityController

    @State private var selectedWorkspaceID: UUID?
    @State private var showNewWorkspace = false
    @State private var showNewSecret = false
    @State private var showRenameWorkspace = false
    @State private var showDeleteWorkspaceConfirmation = false
    @State private var showEnvImport = false
    @State private var searchText = ""
    @State private var createSecretError: String?
    @State private var importSummary: EnvImportSummary?
    @State private var hoveredSecretID: UUID?
    @State private var selectedSecretIDs: Set<UUID> = []
    @State private var showBulkEnvironmentSheet = false
    @State private var editingSecret: Secret?
    @State private var deletingSecret: Secret?
    @State private var copiedIndicator: CopiedIndicator?
    @State private var focusedSecretID: UUID?
    @State private var selectedEnvironmentFilters: Set<String> = []
    @State private var providerFilter: ProviderFilter = .all
    @State private var sortOption: SecretSortOption = .updatedNewest

    private var filteredSecrets: [Secret] {
        guard let selectedWorkspaceID else { return [] }
        let base = store.secrets(in: selectedWorkspaceID)
        return base.filter(matchesBaseFilters)
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
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 360)
        } detail: {
            secretTableView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            ) { workspaceID, key, value, environments, provider, notes in
                do {
                    try store.addSecret(
                        workspaceID: workspaceID,
                        key: key,
                        value: value,
                        environments: environments,
                        provider: provider,
                        notes: notes
                    )
                    createSecretError = nil
                } catch {
                    createSecretError = (error as? LocalizedError)?.errorDescription ?? "Could not save secret value to Keychain."
                }
            }
        }
        .sheet(isPresented: $showBulkEnvironmentSheet) {
            BulkEditSecretEnvironmentsSheet(selectedCount: selectedSecretIDs.count) { environments in
                do {
                    try store.bulkUpdateSecretEnvironments(secretIDs: selectedSecretIDs, environments: environments)
                    createSecretError = nil
                    selectedSecretIDs.removeAll()
                    return nil
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? "Could not update environments."
                    createSecretError = message
                    return message
                }
            }
        }
        .sheet(isPresented: $showEnvImport) {
            EnvImportSheet(
                selectedWorkspaceID: selectedWorkspaceID,
                workspaces: store.workspaces
            ) { workspaceID, entries, environments, provider, strategy in
                let summary = store.importEnvEntries(
                    workspaceID: workspaceID,
                    entries: entries,
                    environments: environments,
                    provider: provider,
                    strategy: strategy
                )
                importSummary = summary
            }
        }
        .sheet(item: $editingSecret) { secret in
            EditSecretSheet(secret: secret) { key, value, environments, provider, notes in
                do {
                    try store.updateSecret(
                        secretID: secret.id,
                        key: key,
                        value: value,
                        environments: environments,
                        provider: provider,
                        notes: notes
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
                    selectedSecretIDs.remove(deletingSecret.id)
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
        .onChange(of: selectedWorkspaceID) { _, _ in
            selectedSecretIDs.removeAll()
        }
    }

    private var sidebar: some View {
        List(selection: $selectedWorkspaceID) {
            ForEach(store.workspaces) { workspace in
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
            .onMove { indices, newOffset in
                store.moveWorkspaces(fromOffsets: indices, toOffset: newOffset)
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
                Button {
                    showBulkEnvironmentSheet = true
                } label: {
                    Label("Set environments for selection", systemImage: "square.stack.3d.up")
                }
                .disabled(selectedWorkspaceID == nil || selectedSecretIDs.isEmpty)
                Button {
                    showEnvImport = true
                } label: {
                    Label("Import .env", systemImage: "square.and.arrow.down")
                }
                .disabled(store.workspaces.isEmpty)
            }

            if !selectedSecretIDs.isEmpty {
                HStack(spacing: 8) {
                    Text("\(selectedSecretIDs.count) secret\(selectedSecretIDs.count == 1 ? "" : "s") selected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Clear selection") {
                        selectedSecretIDs.removeAll()
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
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
                EnvironmentFilterPill(title: "Staging", isSelected: selectedEnvironmentFilters.contains("staging")) {
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
            if let importSummary {
                Text("Import finished: parsed \(importSummary.parsed), imported \(importSummary.imported), skipped \(importSummary.skipped), failed \(importSummary.failed).")
                    .font(.caption)
                    .foregroundStyle(importSummary.failed > 0 ? .orange : .secondary)
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
                    SecretTableHeaderRow(
                        allVisibleSelected: allVisibleSecretsSelected,
                        onToggleSelectAllVisible: toggleSelectAllVisibleSecrets
                    ) { column in
                        sortByColumn(column)
                    }
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(visibleSecrets) { secret in
                                SecretTableRow(
                                    secret: secret,
                                    isRowSelected: selectedSecretIDs.contains(secret.id),
                                    onToggleRowSelection: {
                                        var next = selectedSecretIDs
                                        if next.contains(secret.id) {
                                            next.remove(secret.id)
                                        } else {
                                            next.insert(secret.id)
                                        }
                                        selectedSecretIDs = next
                                    },
                                    environmentText: secret.environments.map(displayName(forEnvironment:)).joined(separator: ", "),
                                    isHovered: hoveredSecretID == secret.id,
                                    isFocused: focusedSecretID == secret.id,
                                    isKeyCopied: copiedIndicator == .key(secret.id),
                                    isValueCopied: copiedIndicator == .value(secret.id),
                                    onCopyKey: {
                                        copySecretKey(secret)
                                    },
                                    onCopyValue: {
                                        copySecretValue(secret)
                                    },
                                    onReadValue: {
                                        store.readSecretValue(secretID: secret.id)
                                    },
                                    onInlineRename: { updatedKey in
                                        do {
                                            try store.updateSecretInline(secretID: secret.id, key: updatedKey)
                                            createSecretError = nil
                                        } catch {
                                            createSecretError = (error as? LocalizedError)?.errorDescription ?? "Could not update secret key."
                                        }
                                    },
                                    onInlineValueUpdate: { updatedValue in
                                        do {
                                            try store.updateSecretInline(secretID: secret.id, value: updatedValue)
                                            createSecretError = nil
                                        } catch {
                                            createSecretError = (error as? LocalizedError)?.errorDescription ?? "Could not update secret value."
                                        }
                                    },
                                    onEdit: {
                                        editingSecret = secret
                                    },
                                    onDelete: {
                                        deletingSecret = secret
                                    },
                                    onQuickUpdateProvider: { provider in
                                        try? store.updateSecretQuickFields(secretID: secret.id, provider: provider)
                                    },
                                    onQuickUpdateEnvironments: { environments in
                                        do {
                                            try store.updateSecretQuickFields(secretID: secret.id, environments: environments)
                                            createSecretError = nil
                                        } catch {
                                            createSecretError = (error as? LocalizedError)?.errorDescription ?? "Could not update environments."
                                        }
                                    }
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    focusedSecretID = secret.id
                                }
                                .contextMenu {
                                    Button("Copy Key") {
                                        copySecretKey(secret)
                                    }
                                    Button("Copy Value") {
                                        copySecretValue(secret)
                                    }
                                    Button("Edit") {
                                        editingSecret = secret
                                    }
                                    Divider()
                                    Button("Delete", role: .destructive) {
                                        deletingSecret = secret
                                    }
                                }
                                .onHover { isHovering in
                                    if isHovering {
                                        hoveredSecretID = secret.id
                                    } else if hoveredSecretID == secret.id {
                                        hoveredSecretID = nil
                                    }
                                }
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .onMoveCommand { direction in
                    moveFocus(direction: direction)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            Group {
                Button("", action: copyFocusedSecretValue)
                    .keyboardShortcut("c", modifiers: [.command])
                Button("", action: editFocusedSecret)
                    .keyboardShortcut(.return, modifiers: [])
                Button("", action: promptDeleteFocusedSecret)
                    .keyboardShortcut(.delete, modifiers: [])
            }
            .hidden()
        }
    }

    private func copySecretValue(_ secret: Secret) {
        if let value = store.readSecretValue(secretID: secret.id) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            scheduleClipboardClear(for: value)
            copiedIndicator = .value(secret.id)
            focusedSecretID = secret.id
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
        focusedSecretID = secret.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if copiedIndicator == .key(secret.id) {
                copiedIndicator = nil
            }
        }
    }

    private func sortByColumn(_ column: SecretSortColumn) {
        switch column {
        case .key:
            sortOption = sortOption == .keyAToZ ? .keyZToA : .keyAToZ
        case .updatedAt:
            sortOption = sortOption == .updatedNewest ? .updatedOldest : .updatedNewest
        case .environment, .provider:
            break
        }
    }

    private func moveFocus(direction: MoveCommandDirection) {
        guard !visibleSecrets.isEmpty else { return }
        guard let focusedSecretID,
              let currentIndex = visibleSecrets.firstIndex(where: { $0.id == focusedSecretID }) else {
            self.focusedSecretID = visibleSecrets.first?.id
            return
        }

        switch direction {
        case .up:
            self.focusedSecretID = visibleSecrets[max(0, currentIndex - 1)].id
        case .down:
            self.focusedSecretID = visibleSecrets[min(visibleSecrets.count - 1, currentIndex + 1)].id
        default:
            break
        }
    }

    private func copyFocusedSecretValue() {
        guard let focusedSecretID,
              let secret = visibleSecrets.first(where: { $0.id == focusedSecretID }) else { return }
        copySecretValue(secret)
    }

    private func editFocusedSecret() {
        guard let focusedSecretID,
              let secret = visibleSecrets.first(where: { $0.id == focusedSecretID }) else { return }
        editingSecret = secret
    }

    private func promptDeleteFocusedSecret() {
        guard let focusedSecretID,
              let secret = visibleSecrets.first(where: { $0.id == focusedSecretID }) else { return }
        deletingSecret = secret
    }

    private var allVisibleSecretsSelected: Bool {
        !visibleSecrets.isEmpty && visibleSecrets.allSatisfy { selectedSecretIDs.contains($0.id) }
    }

    private func toggleSelectAllVisibleSecrets() {
        let visibleIDs = Set(visibleSecrets.map(\.id))
        if allVisibleSecretsSelected {
            selectedSecretIDs = selectedSecretIDs.subtracting(visibleIDs)
        } else {
            selectedSecretIDs = selectedSecretIDs.union(visibleIDs)
        }
    }

    private func toggleEnvironmentFilter(_ environment: String) {
        if selectedEnvironmentFilters.contains(environment) {
            selectedEnvironmentFilters.remove(environment)
        } else {
            selectedEnvironmentFilters.insert(environment)
        }
    }

    private func scheduleClipboardClear(for value: String) {
        let pasteboard = NSPasteboard.general
        let capturedChangeCount = pasteboard.changeCount

        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            let currentValue = pasteboard.string(forType: .string)
            guard pasteboard.changeCount == capturedChangeCount, currentValue == value else {
                return
            }
            pasteboard.clearContents()
        }
    }

    private func matchesBaseFilters(_ secret: Secret) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
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
    var allVisibleSelected: Bool = false
    let onToggleSelectAllVisible: () -> Void
    let onSort: (SecretSortColumn) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { allVisibleSelected },
                set: { _ in onToggleSelectAllVisible() }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .frame(width: 28, alignment: .center)
            .help("Select all visible secrets")
            Button("Key") { onSort(.key) }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Value")
                .frame(width: 170, alignment: .leading)
            Text("Environment")
                .frame(width: 170, alignment: .leading)
            Text("Provider")
                .frame(width: 150, alignment: .leading)
            Button("Updated") { onSort(.updatedAt) }
                .buttonStyle(.plain)
                .frame(width: 130, alignment: .leading)
            Text("Actions / Notes")
                .frame(width: 200, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.12))
    }
}

private struct SecretTableRow: View {
    @EnvironmentObject private var security: AppSecurityController

    private enum InlineField {
        case key
        case value
        case provider
    }

    let secret: Secret
    var isRowSelected: Bool = false
    var onToggleRowSelection: (() -> Void)?
    let environmentText: String
    let isHovered: Bool
    let isFocused: Bool
    let isKeyCopied: Bool
    let isValueCopied: Bool
    let onCopyKey: () -> Void
    let onCopyValue: () -> Void
    let onReadValue: () -> String?
    let onInlineRename: (String) -> Void
    let onInlineValueUpdate: (String) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onQuickUpdateProvider: (String?) -> Void
    let onQuickUpdateEnvironments: ([String]) -> Void

    @State private var providerDraft = ""
    @State private var showNotesPopover = false
    @State private var isHoveringKeyCell = false
    @State private var isHoveringValueCell = false
    @State private var revealedValue: String?
    @State private var revealHideTask: DispatchWorkItem?
    @State private var isEditingKeyInline = false
    @State private var isEditingValueInline = false
    @State private var isEditingProviderInline = false
    @State private var keyDraft = ""
    @State private var valueDraft = ""
    @State private var showKeyBlurPrompt = false
    @State private var showValueBlurPrompt = false
    @State private var showProviderBlurPrompt = false
    @FocusState private var focusedInlineField: InlineField?

    private var isValueRevealed: Bool {
        revealedValue != nil
    }

    private var keyHasUnsavedChanges: Bool {
        keyDraft.trimmingCharacters(in: .whitespacesAndNewlines) != secret.key
    }

    private var valueHasUnsavedChanges: Bool {
        let trimmed = valueDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != (onReadValue() ?? "")
    }

    private var providerHasUnsavedChanges: Bool {
        providerDraft.trimmingCharacters(in: .whitespacesAndNewlines) != (secret.provider ?? "")
    }

    var body: some View {
        HStack(spacing: 12) {
            if let onToggleRowSelection {
                Toggle("", isOn: Binding(
                    get: { isRowSelected },
                    set: { _ in onToggleRowSelection() }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 28, alignment: .center)
            }
            HStack(spacing: 6) {
                if isEditingKeyInline {
                    TextField("Secret key", text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedInlineField, equals: .key)
                        .onSubmit {
                            commitInlineKeyEdit()
                        }
                        .onExitCommand {
                            cancelInlineKeyEdit()
                        }
                    if keyHasUnsavedChanges {
                        Text("Unsaved")
                            .font(.caption2)
                            .foregroundStyle(showKeyBlurPrompt ? .orange : .secondary)
                    }
                    Button {
                        commitInlineKeyEdit()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(.plain)
                    .help("Save key")
                    Button {
                        cancelInlineKeyEdit()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help("Discard key changes")
                } else {
                    Text(secret.key)
                        .lineLimit(1)
                        .onTapGesture(count: 2) {
                            beginInlineKeyEdit()
                        }
                }
                Spacer(minLength: 0)
                Button {
                    onCopyKey()
                } label: {
                    Image(systemName: isKeyCopied ? "checkmark.circle.fill" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy key")
                .opacity((isHoveringKeyCell && !isEditingKeyInline) ? 1 : 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onHover { isHovering in
                isHoveringKeyCell = isHovering
            }

            HStack(spacing: 6) {
                if isEditingValueInline {
                    TextField("Secret value", text: $valueDraft)
                        .font(.body.monospaced())
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                        .focused($focusedInlineField, equals: .value)
                        .onSubmit {
                            commitInlineValueEdit()
                        }
                        .onExitCommand {
                            cancelInlineValueEdit()
                        }
                    if valueHasUnsavedChanges {
                        Text("Unsaved")
                            .font(.caption2)
                            .foregroundStyle(showValueBlurPrompt ? .orange : .secondary)
                    }
                    Button {
                        commitInlineValueEdit()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(.plain)
                    .help("Save value")
                    Button {
                        cancelInlineValueEdit()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help("Discard value changes")
                } else {
                    Text(revealedValue ?? "••••••••")
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .onTapGesture(count: 2) {
                            beginInlineValueEdit()
                        }
                    Spacer(minLength: 0)
                    Button {
                        onCopyValue()
                    } label: {
                        Image(systemName: isValueCopied ? "checkmark.circle.fill" : "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help("Copy value")
                    .opacity((isHoveringValueCell || isValueRevealed) ? 1 : 0)
                    Button {
                        if isValueRevealed {
                            hideRevealedValue()
                        } else {
                            revealValueForTwentySeconds()
                        }
                    } label: {
                        Image(systemName: isValueRevealed ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                    .help(isValueRevealed ? "Hide value" : "Show value for 20 seconds")
                    .opacity((isHoveringValueCell || isValueRevealed) ? 1 : 0)
                }
            }
            .frame(width: 170, alignment: .leading)
            .onHover { isHovering in
                isHoveringValueCell = isHovering
            }

            QuickEnvironmentEditor(
                selectedEnvironments: Set(secret.environments),
                onSave: { onQuickUpdateEnvironments(Array($0).sorted()) }
            )
            .frame(width: 170, alignment: .leading)

            HStack(spacing: 6) {
                if isEditingProviderInline {
                    TextField("Provider", text: $providerDraft)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedInlineField, equals: .provider)
                        .onSubmit {
                            commitInlineProviderEdit()
                        }
                        .onExitCommand {
                            cancelInlineProviderEdit()
                        }
                    if providerHasUnsavedChanges {
                        Text("Unsaved")
                            .font(.caption2)
                            .foregroundStyle(showProviderBlurPrompt ? .orange : .secondary)
                    }
                    Button {
                        commitInlineProviderEdit()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(.plain)
                    .help("Save provider")
                    Button {
                        cancelInlineProviderEdit()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help("Discard provider changes")
                } else {
                    Text(secret.provider?.isEmpty == false ? secret.provider! : "—")
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .onTapGesture(count: 2) {
                            beginInlineProviderEdit()
                        }
                }
            }
            .frame(width: 150, alignment: .leading)

            Text(secret.updatedAt, style: .date)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)

            HStack(spacing: 8) {
                Button {
                    onEdit()
                } label: {
                    Image(systemName: "pencil")
                }
                .help("Edit secret")

                Button {
                    showNotesPopover = true
                } label: {
                    Image(systemName: secret.notes == nil ? "note.text.badge.plus" : "note.text")
                }
                .help("View notes")
                .popover(isPresented: $showNotesPopover) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(secret.key)
                            .font(.headline)
                        Text(secret.notes ?? "No notes yet.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 300, alignment: .leading)
                    }
                    .padding()
                    .frame(width: 320)
                }

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
            .frame(width: 200, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background((isHovered || isFocused) ? Color.accentColor.opacity(0.08) : Color.clear)
        .onDisappear {
            revealHideTask?.cancel()
        }
        .onAppear {
            keyDraft = secret.key
        }
        .onChange(of: security.isUnlocked) { _, isUnlocked in
            if !isUnlocked {
                hideRevealedValue()
            }
        }
        .onChange(of: focusedInlineField) { _, newFocusedField in
            if isEditingKeyInline && newFocusedField != .key && keyHasUnsavedChanges {
                showKeyBlurPrompt = true
            } else if isEditingKeyInline && newFocusedField != .key && !keyHasUnsavedChanges {
                isEditingKeyInline = false
            }

            if isEditingValueInline && newFocusedField != .value && valueHasUnsavedChanges {
                showValueBlurPrompt = true
            } else if isEditingValueInline && newFocusedField != .value && !valueHasUnsavedChanges {
                isEditingValueInline = false
            }

            if isEditingProviderInline && newFocusedField != .provider && providerHasUnsavedChanges {
                showProviderBlurPrompt = true
            } else if isEditingProviderInline && newFocusedField != .provider && !providerHasUnsavedChanges {
                isEditingProviderInline = false
            }
        }
    }

    private func revealValueForTwentySeconds() {
        guard let value = onReadValue() else { return }
        revealHideTask?.cancel()
        revealedValue = value

        let task = DispatchWorkItem {
            hideRevealedValue()
        }
        revealHideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: task)
    }

    private func hideRevealedValue() {
        revealHideTask?.cancel()
        revealHideTask = nil
        revealedValue = nil
    }

    private func beginInlineKeyEdit() {
        keyDraft = secret.key
        isEditingKeyInline = true
        showKeyBlurPrompt = false
        focusedInlineField = .key
    }

    private func commitInlineKeyEdit() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            keyDraft = secret.key
            isEditingKeyInline = false
            showKeyBlurPrompt = false
            return
        }
        if trimmed != secret.key {
            onInlineRename(trimmed)
        }
        isEditingKeyInline = false
        showKeyBlurPrompt = false
        focusedInlineField = nil
    }

    private func cancelInlineKeyEdit() {
        keyDraft = secret.key
        isEditingKeyInline = false
        showKeyBlurPrompt = false
        focusedInlineField = nil
    }

    private func beginInlineValueEdit() {
        valueDraft = revealedValue ?? onReadValue() ?? ""
        isEditingValueInline = true
        showValueBlurPrompt = false
        focusedInlineField = .value
        hideRevealedValue()
    }

    private func commitInlineValueEdit() {
        let trimmed = valueDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isEditingValueInline = false
            showValueBlurPrompt = false
            return
        }
        let currentValue = onReadValue() ?? ""
        if trimmed != currentValue {
            onInlineValueUpdate(trimmed)
        }
        isEditingValueInline = false
        showValueBlurPrompt = false
        focusedInlineField = nil
    }

    private func cancelInlineValueEdit() {
        valueDraft = onReadValue() ?? ""
        isEditingValueInline = false
        showValueBlurPrompt = false
        focusedInlineField = nil
    }

    private func beginInlineProviderEdit() {
        providerDraft = secret.provider ?? ""
        isEditingProviderInline = true
        showProviderBlurPrompt = false
        focusedInlineField = .provider
    }

    private func commitInlineProviderEdit() {
        let trimmed = providerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = secret.provider ?? ""
        if trimmed != current {
            onQuickUpdateProvider(trimmed.isEmpty ? nil : trimmed)
        }
        isEditingProviderInline = false
        showProviderBlurPrompt = false
        focusedInlineField = nil
    }

    private func cancelInlineProviderEdit() {
        providerDraft = secret.provider ?? ""
        isEditingProviderInline = false
        showProviderBlurPrompt = false
        focusedInlineField = nil
    }
}

private struct QuickEnvironmentEditor: View {
    @State var selectedEnvironments: Set<String>
    let onSave: (Set<String>) -> Void
    private let options = ["dev", "staging", "prod"]

    var body: some View {
        Menu(selectedEnvironments.map { $0.capitalized }.sorted().joined(separator: ", ").ifEmpty("Set env")) {
            ForEach(options, id: \.self) { option in
                Button {
                    if selectedEnvironments.contains(option) {
                        selectedEnvironments.remove(option)
                    } else {
                        selectedEnvironments.insert(option)
                    }
                    if !selectedEnvironments.isEmpty {
                        onSave(selectedEnvironments)
                    }
                } label: {
                    Label(option.capitalized, systemImage: selectedEnvironments.contains(option) ? "checkmark.circle.fill" : "circle")
                }
            }
        }
        .menuStyle(.button)
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
    @State private var notes = ""

    let workspaceID: UUID?
    let workspaces: [Workspace]
    let onSave: (UUID, String, String, [String], String?, String?) -> Void

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
            TextField("Notes (optional)", text: $notes)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    guard let chosenWorkspaceID else { return }
                    let environments = selectedEnvironments.sorted()
                    onSave(
                        chosenWorkspaceID,
                        key,
                        value,
                        environments,
                        provider.isEmpty ? nil : provider,
                        notes.isEmpty ? nil : notes
                    )
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
    @State private var notes: String

    let secret: Secret
    let onSave: (String, String?, [String], String?, String?) -> Void

    init(secret: Secret, onSave: @escaping (String, String?, [String], String?, String?) -> Void) {
        self.secret = secret
        self._key = State(initialValue: secret.key)
        self._selectedEnvironments = State(initialValue: Set(secret.environments))
        self._provider = State(initialValue: secret.provider ?? "")
        self._notes = State(initialValue: secret.notes ?? "")
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
            TextField("Notes (optional)", text: $notes)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(
                        key,
                        value.isEmpty ? nil : value,
                        selectedEnvironments.sorted(),
                        provider.isEmpty ? nil : provider,
                        notes.isEmpty ? nil : notes
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

private struct BulkEditSecretEnvironmentsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedEnvironments: Set<String> = ["dev"]
    @State private var applyError: String?

    let selectedCount: Int
    /// Return `nil` on success, or an error message to show in the sheet.
    let onApply: ([String]) -> String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set environments for \(selectedCount) secret\(selectedCount == 1 ? "" : "s")")
                .font(.title3)
                .bold()

            Text("Every selected row gets this exact environment list (replacing what it had before).")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            EnvironmentSelectorRow(selectedEnvironments: $selectedEnvironments)

            if let applyError {
                Text(applyError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply") {
                    applyError = nil
                    if let message = onApply(selectedEnvironments.sorted()) {
                        applyError = message
                    } else {
                        dismiss()
                    }
                }
                .disabled(selectedEnvironments.isEmpty)
            }
        }
        .padding()
        .frame(width: 480)
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

private struct EnvImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    @State private var pastedText = ""
    @State private var importedFileName: String?
    @State private var showFileImporter = false
    @State private var fileImportError: String?
    @State private var chosenWorkspaceID: UUID?
    @State private var selectedEnvironments: Set<String> = ["dev"]
    @State private var provider = ""
    @State private var strategy: ImportConflictStrategy = .skip

    /// Types allowed in the open panel — `.env` is not always exported as its own UTType on disk.
    private static let fileImporterContentTypes: [UTType] = {
        var types: [UTType] = [.plainText]
        if let env = UTType(filenameExtension: "env") {
            types.append(env)
        }
        return types
    }()

    let selectedWorkspaceID: UUID?
    let workspaces: [Workspace]
    let onImport: (UUID, [EnvImportEntry], [String], String?, ImportConflictStrategy) -> Void

    private var parsedPreview: EnvImportParseResult {
        EnvImportParser.parse(pastedText)
    }

    private var validEntries: [EnvImportEntry] {
        parsedPreview.entries
    }

    private var canImport: Bool {
        chosenWorkspaceID != nil && !selectedEnvironments.isEmpty && !validEntries.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import .env")
                .font(.title3)
                .bold()

            HStack(spacing: 12) {
                Picker("Workspace", selection: $chosenWorkspaceID) {
                    Text("Select workspace").tag(UUID?.none)
                    ForEach(workspaces.sorted(by: { $0.name < $1.name })) { workspace in
                        Text(workspace.name).tag(Optional(workspace.id))
                    }
                }
                .frame(maxWidth: 260)

                Picker("Conflict", selection: $strategy) {
                    ForEach(ImportConflictStrategy.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .frame(width: 160)

                Spacer()
            }

            EnvironmentSelectorRow(selectedEnvironments: $selectedEnvironments)
            TextField("Provider (optional, applied to imported rows)", text: $provider)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Button("Choose .env file…") {
                        fileImportError = nil
                        showFileImporter = true
                    }

                    if let importedFileName {
                        Text(importedFileName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()
                }

                Text("Paste your `.env` below, or load a file. You can still edit text after loading.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $pastedText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 170)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )

            HStack {
                Text("Preview")
                    .font(.headline)
                Spacer()
                Text("Parsed \(parsedPreview.entries.count) • Errors \(parsedPreview.errors.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Table(parsedPreview.rows) {
                TableColumn("Line") { row in
                    Text("\(row.lineNumber)")
                        .foregroundStyle(.secondary)
                }
                .width(50)

                TableColumn("Key") { row in
                    Text(row.key ?? "—")
                        .lineLimit(1)
                        .foregroundStyle(row.key == nil ? .secondary : .primary)
                }
                .width(min: 180, ideal: 220)

                TableColumn("Value") { row in
                    if let value = row.value {
                        Text(value)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("—")
                            .foregroundStyle(.secondary)
                    }
                }
                .width(min: 220, ideal: 320)

                TableColumn("Status") { row in
                    if let error = row.error {
                        Text(error)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    } else if row.key != nil {
                        if let key = row.key, let conflict = conflictDescription(for: key) {
                            Text(conflict)
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        } else {
                            Text("Ready")
                                .foregroundStyle(.green)
                        }
                    } else {
                        Text("Ignored")
                            .foregroundStyle(.secondary)
                    }
                }
                .width(min: 220, ideal: 280)
            }
            .frame(minHeight: 220)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import") {
                    guard let chosenWorkspaceID else { return }
                    onImport(
                        chosenWorkspaceID,
                        validEntries,
                        selectedEnvironments.sorted(),
                        provider.isEmpty ? nil : provider,
                        strategy
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canImport)
            }
        }
        .padding()
        .frame(width: 920, height: 760)
        .onAppear {
            chosenWorkspaceID = selectedWorkspaceID ?? workspaces.first?.id
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: Self.fileImporterContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .failure(let error):
                fileImportError = error.localizedDescription
            case .success(let urls):
                guard let url = urls.first else { return }
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    pastedText = text
                    importedFileName = url.lastPathComponent
                } catch {
                    fileImportError = error.localizedDescription
                }
            }
        }
        .alert("Could not read file", isPresented: Binding(
            get: { fileImportError != nil },
            set: { if !$0 { fileImportError = nil } }
        )) {
            Button("OK") { fileImportError = nil }
        } message: {
            if let fileImportError {
                Text(fileImportError)
            }
        }
    }

    private func conflictDescription(for key: String) -> String? {
        guard let chosenWorkspaceID else { return nil }
        let environments = Set(selectedEnvironments.map { $0.lowercased() })
        guard !environments.isEmpty else { return nil }
        guard let conflict = store.secrets(in: chosenWorkspaceID).first(where: { secret in
            let keyMatches = secret.key.caseInsensitiveCompare(key) == .orderedSame
            let existingEnvironments = Set(secret.environments.map { $0.lowercased() })
            return keyMatches && !existingEnvironments.isDisjoint(with: environments)
        }) else {
            return nil
        }
        let envText = conflict.environments.map { $0.capitalized }.joined(separator: ", ")
        return "Conflicts with existing \(conflict.key) (\(envText))"
    }
}

private struct EnvImportParseResult {
    var rows: [EnvImportPreviewRow]
    var entries: [EnvImportEntry]
    var errors: [EnvImportPreviewRow]
}

private struct EnvImportPreviewRow: Identifiable {
    let id = UUID()
    let lineNumber: Int
    let key: String?
    let value: String?
    let error: String?
}

private enum EnvImportParser {
    static func parse(_ text: String) -> EnvImportParseResult {
        var rows: [EnvImportPreviewRow] = []
        var entries: [EnvImportEntry] = []
        var errors: [EnvImportPreviewRow] = []

        let lines = text.components(separatedBy: .newlines)
        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                rows.append(EnvImportPreviewRow(lineNumber: lineNumber, key: nil, value: nil, error: nil))
                continue
            }

            let workingLine = trimmed.hasPrefix("export ") ? String(trimmed.dropFirst(7)) : trimmed
            guard let equalsIndex = workingLine.firstIndex(of: "=") else {
                let row = EnvImportPreviewRow(
                    lineNumber: lineNumber,
                    key: nil,
                    value: nil,
                    error: "Missing '=' delimiter."
                )
                rows.append(row)
                errors.append(row)
                continue
            }

            let rawKey = String(workingLine[..<equalsIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            var rawValue = String(workingLine[workingLine.index(after: equalsIndex)...])
            rawValue = rawValue.trimmingCharacters(in: .whitespaces)

            guard !rawKey.isEmpty else {
                let row = EnvImportPreviewRow(
                    lineNumber: lineNumber,
                    key: nil,
                    value: nil,
                    error: "Missing key name."
                )
                rows.append(row)
                errors.append(row)
                continue
            }

            guard isValidEnvKey(rawKey) else {
                let row = EnvImportPreviewRow(
                    lineNumber: lineNumber,
                    key: rawKey,
                    value: nil,
                    error: "Invalid key format."
                )
                rows.append(row)
                errors.append(row)
                continue
            }

            do {
                let parsedValue = try parseValue(rawValue)
                let row = EnvImportPreviewRow(
                    lineNumber: lineNumber,
                    key: rawKey,
                    value: parsedValue,
                    error: nil
                )
                rows.append(row)
                entries.append(
                    EnvImportEntry(lineNumber: lineNumber, key: rawKey, value: parsedValue)
                )
            } catch {
                let row = EnvImportPreviewRow(
                    lineNumber: lineNumber,
                    key: rawKey,
                    value: nil,
                    error: error.localizedDescription
                )
                rows.append(row)
                errors.append(row)
            }
        }

        return EnvImportParseResult(rows: rows, entries: entries, errors: errors)
    }

    private static func isValidEnvKey(_ key: String) -> Bool {
        key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    private static func parseValue(_ rawValue: String) throws -> String {
        guard let first = rawValue.first else { return "" }
        if first == "\"" || first == "'" {
            return try parseQuotedValue(rawValue, quote: first)
        }
        return parseUnquotedValue(rawValue)
    }

    private static func parseQuotedValue(_ raw: String, quote: Character) throws -> String {
        var isEscaping = false
        var output = ""
        var foundClosingQuote = false
        var endIndex = raw.startIndex
        var index = raw.index(after: raw.startIndex)

        while index < raw.endIndex {
            let char = raw[index]
            if isEscaping {
                output.append(escapedCharacter(for: char))
                isEscaping = false
                index = raw.index(after: index)
                continue
            }
            if char == "\\" {
                isEscaping = true
                index = raw.index(after: index)
                continue
            }
            if char == quote {
                foundClosingQuote = true
                endIndex = raw.index(after: index)
                break
            }
            output.append(char)
            index = raw.index(after: index)
        }

        guard foundClosingQuote else {
            throw EnvImportParseError.unterminatedQuote
        }

        let trailing = raw[endIndex...].trimmingCharacters(in: .whitespaces)
        if !trailing.isEmpty && !trailing.hasPrefix("#") {
            throw EnvImportParseError.invalidTrailingCharacters
        }
        return output
    }

    private static func parseUnquotedValue(_ raw: String) -> String {
        var value = raw
        if let commentIndex = value.firstIndex(of: "#") {
            let prefix = value[..<commentIndex]
            if prefix.last?.isWhitespace == true {
                value = String(prefix)
            }
        }
        return decodeEscapes(value.trimmingCharacters(in: .whitespaces))
    }

    private static func decodeEscapes(_ text: String) -> String {
        var output = ""
        var isEscaping = false
        for char in text {
            if isEscaping {
                output.append(escapedCharacter(for: char))
                isEscaping = false
            } else if char == "\\" {
                isEscaping = true
            } else {
                output.append(char)
            }
        }
        if isEscaping {
            output.append("\\")
        }
        return output
    }

    private static func escapedCharacter(for char: Character) -> Character {
        switch char {
        case "n":
            return "\n"
        case "r":
            return "\r"
        case "t":
            return "\t"
        case "\\":
            return "\\"
        case "\"":
            return "\""
        case "'":
            return "'"
        default:
            return char
        }
    }
}

private enum EnvImportParseError: LocalizedError {
    case unterminatedQuote
    case invalidTrailingCharacters

    var errorDescription: String? {
        switch self {
        case .unterminatedQuote:
            return "Quoted value is not closed."
        case .invalidTrailingCharacters:
            return "Invalid characters after closing quote."
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}

#Preview {
    ContentView()
        .environmentObject(AppStore())
        .environmentObject(AppSecurityController())
}
