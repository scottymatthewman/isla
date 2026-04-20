import Foundation
import Combine

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var secrets: [Secret] = []

    private let keychain = KeychainSecretStore()
    private let metadataURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let islaFolder = appSupport.appendingPathComponent("isla", isDirectory: true)
        metadataURL = islaFolder.appendingPathComponent("metadata.json")

        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601

        load()
    }

    func secrets(in workspaceID: UUID) -> [Secret] {
        secrets
            .filter { $0.workspaceID == workspaceID }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    func workspace(id: UUID) -> Workspace? {
        workspaces.first { $0.id == id }
    }

    func addWorkspace(name: String) {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty else { return }
        guard !workspaces.contains(where: { $0.name.caseInsensitiveCompare(cleanedName) == .orderedSame }) else { return }

        let now = Date()
        workspaces.append(
            Workspace(id: UUID(), name: cleanedName, createdAt: now, updatedAt: now)
        )
        persist()
    }

    func renameWorkspace(workspaceID: UUID, newName: String) {
        let cleanedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty else { return }
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        guard !workspaces.contains(where: { $0.id != workspaceID && $0.name.caseInsensitiveCompare(cleanedName) == .orderedSame }) else { return }

        workspaces[index].name = cleanedName
        workspaces[index].updatedAt = Date()
        persist()
    }

    func deleteWorkspace(workspaceID: UUID) {
        let affectedSecrets = secrets.filter { $0.workspaceID == workspaceID }
        for secret in affectedSecrets {
            try? keychain.delete(account: secret.keychainAccount)
            if let notesKeychainAccount = secret.notesKeychainAccount {
                try? keychain.delete(account: notesKeychainAccount)
            }
        }
        secrets.removeAll { $0.workspaceID == workspaceID }
        workspaces.removeAll { $0.id == workspaceID }
        persist()
    }

    func moveWorkspaces(fromOffsets: IndexSet, toOffset: Int) {
        let sourceIndices = fromOffsets.sorted()
        let movingItems = sourceIndices.map { workspaces[$0] }

        for index in sourceIndices.reversed() {
            workspaces.remove(at: index)
        }

        let numberOfRemovedBeforeDestination = sourceIndices.filter { $0 < toOffset }.count
        let adjustedOffset = toOffset - numberOfRemovedBeforeDestination
        let clampedOffset = max(0, min(adjustedOffset, workspaces.count))
        workspaces.insert(contentsOf: movingItems, at: clampedOffset)
        persist()
    }

    func addSecret(workspaceID: UUID, key: String, value: String, environments: [String], provider: String?, notes: String? = nil) throws {
        let cleanedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedEnvironments = environments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard !cleanedKey.isEmpty, !cleanedEnvironments.isEmpty else {
            throw AppStoreError.invalidInput
        }
        guard !hasDuplicateSecret(workspaceID: workspaceID, key: cleanedKey, environments: cleanedEnvironments, excluding: nil) else {
            throw AppStoreError.duplicateSecret
        }

        let now = Date()
        let account = "secret-\(UUID().uuidString)"
        try keychain.save(value: value, account: account)

        let cleanedProvider = normalizeProvider(provider)
        let (cleanedNotes, notesKeychainAccount) = try persistedNotes(notes)

        secrets.append(
            Secret(
                id: UUID(),
                workspaceID: workspaceID,
                key: cleanedKey,
                keychainAccount: account,
                environments: cleanedEnvironments,
                provider: cleanedProvider,
                notes: cleanedNotes,
                notesKeychainAccount: notesKeychainAccount,
                providerMetadata: providerMetadata(for: cleanedProvider),
                rotationCapability: .manual,
                lastRotatedAt: nil,
                rotationHistory: [],
                createdAt: now,
                updatedAt: now
            )
        )
        persist()
    }

    func updateSecret(
        secretID: UUID,
        key: String,
        value: String?,
        environments: [String],
        provider: String?,
        notes: String?
    ) throws {
        let cleanedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedEnvironments = environments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard !cleanedKey.isEmpty, !cleanedEnvironments.isEmpty else {
            throw AppStoreError.invalidInput
        }
        guard let index = secrets.firstIndex(where: { $0.id == secretID }) else {
            throw AppStoreError.notFound
        }
        let secret = secrets[index]
        guard !hasDuplicateSecret(
            workspaceID: secret.workspaceID,
            key: cleanedKey,
            environments: cleanedEnvironments,
            excluding: secretID
        ) else {
            throw AppStoreError.duplicateSecret
        }

        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try keychain.save(value: value, account: secret.keychainAccount)
        }

        let cleanedProvider = normalizeProvider(provider)
        let (cleanedNotes, notesKeychainAccount) = try persistedNotes(notes, existingAccount: secret.notesKeychainAccount)

        secrets[index].key = cleanedKey
        secrets[index].environments = cleanedEnvironments
        secrets[index].provider = cleanedProvider
        secrets[index].notes = cleanedNotes
        secrets[index].notesKeychainAccount = notesKeychainAccount
        secrets[index].providerMetadata = providerMetadata(for: cleanedProvider)
        secrets[index].updatedAt = Date()
        persist()
    }

    func updateSecretQuickFields(secretID: UUID, environments: [String]? = nil, provider: String? = nil, notes: String? = nil) throws {
        guard let index = secrets.firstIndex(where: { $0.id == secretID }) else {
            throw AppStoreError.notFound
        }
        let secret = secrets[index]

        if let environments {
            let cleanedEnvironments = environments
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            guard !cleanedEnvironments.isEmpty else {
                throw AppStoreError.invalidInput
            }
            guard !hasDuplicateSecret(
                workspaceID: secret.workspaceID,
                key: secret.key,
                environments: cleanedEnvironments,
                excluding: secret.id
            ) else {
                throw AppStoreError.duplicateSecret
            }
            secrets[index].environments = cleanedEnvironments
        }

        if provider != nil {
            let cleanedProvider = normalizeProvider(provider)
            secrets[index].provider = cleanedProvider
            secrets[index].providerMetadata = providerMetadata(for: cleanedProvider)
        }

        if notes != nil {
            let (cleanedNotes, notesKeychainAccount) = try persistedNotes(notes, existingAccount: secret.notesKeychainAccount)
            secrets[index].notes = cleanedNotes
            secrets[index].notesKeychainAccount = notesKeychainAccount
        }

        secrets[index].updatedAt = Date()
        persist()
    }

    func updateSecretInline(secretID: UUID, key: String? = nil, value: String? = nil) throws {
        guard let index = secrets.firstIndex(where: { $0.id == secretID }) else {
            throw AppStoreError.notFound
        }

        if let key {
            let cleanedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedKey.isEmpty else {
                throw AppStoreError.invalidInput
            }
            let secret = secrets[index]
            guard !hasDuplicateSecret(
                workspaceID: secret.workspaceID,
                key: cleanedKey,
                environments: secret.environments,
                excluding: secret.id
            ) else {
                throw AppStoreError.duplicateSecret
            }
            secrets[index].key = cleanedKey
        }

        if let value {
            let cleanedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedValue.isEmpty else {
                throw AppStoreError.invalidInput
            }
            try keychain.save(value: cleanedValue, account: secrets[index].keychainAccount)
        }

        secrets[index].updatedAt = Date()
        persist()
    }

    func deleteSecret(secretID: UUID) {
        guard let secret = secrets.first(where: { $0.id == secretID }) else { return }
        try? keychain.delete(account: secret.keychainAccount)
        if let notesKeychainAccount = secret.notesKeychainAccount {
            try? keychain.delete(account: notesKeychainAccount)
        }
        secrets.removeAll { $0.id == secretID }
        persist()
    }

    func readSecretValue(secretID: UUID) -> String? {
        guard let secret = secrets.first(where: { $0.id == secretID }) else {
            return nil
        }
        return try? keychain.read(account: secret.keychainAccount)
    }

    func importEnvEntries(
        workspaceID: UUID,
        entries: [EnvImportEntry],
        environments: [String],
        provider: String?,
        strategy: ImportConflictStrategy
    ) -> EnvImportSummary {
        let cleanedEnvironments = environments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !cleanedEnvironments.isEmpty else {
            return EnvImportSummary(parsed: entries.count, imported: 0, skipped: 0, failed: entries.count)
        }

        var imported = 0
        var skipped = 0
        var failed = 0
        let cleanedProvider = normalizeProvider(provider)

        for entry in entries {
            let conflict = firstConflictSecret(
                workspaceID: workspaceID,
                key: entry.key,
                environments: cleanedEnvironments
            )

            switch strategy {
            case .skip:
                if conflict != nil {
                    skipped += 1
                    continue
                }
                do {
                    try addSecret(
                        workspaceID: workspaceID,
                        key: entry.key,
                        value: entry.value,
                        environments: cleanedEnvironments,
                        provider: cleanedProvider
                    )
                    imported += 1
                } catch {
                    failed += 1
                }
            case .overwrite:
                if let conflict {
                    do {
                        try keychain.save(value: entry.value, account: conflict.keychainAccount)
                        if let index = secrets.firstIndex(where: { $0.id == conflict.id }) {
                            secrets[index].provider = cleanedProvider ?? secrets[index].provider
                            secrets[index].providerMetadata = providerMetadata(for: secrets[index].provider)
                            let merged = Set(secrets[index].environments).union(cleanedEnvironments)
                            secrets[index].environments = Array(merged).sorted()
                            secrets[index].updatedAt = Date()
                        }
                        persist()
                        imported += 1
                    } catch {
                        failed += 1
                    }
                } else {
                    do {
                        try addSecret(
                            workspaceID: workspaceID,
                            key: entry.key,
                            value: entry.value,
                            environments: cleanedEnvironments,
                            provider: cleanedProvider
                        )
                        imported += 1
                    } catch {
                        failed += 1
                    }
                }
            case .rename:
                let keyToUse = uniqueKeyForImport(
                    workspaceID: workspaceID,
                    originalKey: entry.key,
                    environments: cleanedEnvironments
                )
                do {
                    try addSecret(
                        workspaceID: workspaceID,
                        key: keyToUse,
                        value: entry.value,
                        environments: cleanedEnvironments,
                        provider: cleanedProvider
                    )
                    imported += 1
                } catch {
                    failed += 1
                }
            }
        }

        return EnvImportSummary(
            parsed: entries.count,
            imported: imported,
            skipped: skipped,
            failed: failed
        )
    }

    private func load() {
        do {
            let directory = metadataURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            bootstrapIfNeeded()
            return
        }

        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            bootstrapIfNeeded()
            return
        }

        do {
            let data = try Data(contentsOf: metadataURL)
            if let metadata = try? decoder.decode(AppMetadata.self, from: data) {
                workspaces = metadata.workspaces
                var didMigrateMetadata = false
                secrets = metadata.secrets.map { secret in
                    var normalized = secret
                    if normalized.providerMetadata == nil {
                        normalized.providerMetadata = providerMetadata(for: normalized.provider)
                        didMigrateMetadata = true
                    }
                    if let notesKeychainAccount = normalized.notesKeychainAccount {
                        normalized.notes = try? keychain.read(account: notesKeychainAccount)
                    } else if let legacyNotes = normalizeNotes(normalized.notes) {
                        let notesKeychainAccount = "notes-\(UUID().uuidString)"
                        do {
                            try keychain.save(value: legacyNotes, account: notesKeychainAccount)
                            normalized.notes = legacyNotes
                            normalized.notesKeychainAccount = notesKeychainAccount
                            didMigrateMetadata = true
                        } catch {
                            normalized.notes = legacyNotes
                        }
                    }
                    return normalized
                }
                if didMigrateMetadata {
                    persist()
                }
            } else {
                let legacy = try decoder.decode(LegacyAppMetadata.self, from: data)
                let migratedSecrets: [Secret] = legacy.secrets.compactMap { legacySecret in
                    guard let project = legacy.projects.first(where: { $0.id == legacySecret.projectID }) else {
                        return nil
                    }
                    let notesKeychainAccount: String?
                    if let legacyNotes = normalizeNotes(legacySecret.notes) {
                        let account = "notes-\(UUID().uuidString)"
                        try? keychain.save(value: legacyNotes, account: account)
                        notesKeychainAccount = account
                    } else {
                        notesKeychainAccount = nil
                    }
                    return Secret(
                        id: legacySecret.id,
                        workspaceID: project.workspaceID,
                        key: legacySecret.key,
                        keychainAccount: legacySecret.keychainAccount,
                        environments: [legacySecret.environment],
                        provider: legacySecret.provider,
                        notes: legacySecret.notes,
                        notesKeychainAccount: notesKeychainAccount,
                        createdAt: legacySecret.createdAt,
                        updatedAt: legacySecret.updatedAt
                    )
                }
                workspaces = legacy.workspaces
                secrets = migratedSecrets.map { secret in
                    var normalized = secret
                    if normalized.providerMetadata == nil {
                        normalized.providerMetadata = providerMetadata(for: normalized.provider)
                    }
                    return normalized
                }
                persist()
            }
        } catch {
            bootstrapIfNeeded()
        }
    }

    private func persist() {
        do {
            let metadata = AppMetadata(workspaces: workspaces, secrets: secrets)
            let data = try encoder.encode(metadata)
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            // Intentionally avoid logging secret-bearing payloads.
        }
    }

    private func bootstrapIfNeeded() {
        guard workspaces.isEmpty else { return }

        let now = Date()
        let workspace = Workspace(id: UUID(), name: "Isla", createdAt: now, updatedAt: now)

        workspaces = [workspace]
        secrets = []
        persist()
    }

    private func hasDuplicateSecret(workspaceID: UUID, key: String, environments: [String], excluding secretID: UUID?) -> Bool {
        let normalizedKey = key.lowercased()
        let normalizedEnvironments = Set(environments.map { $0.lowercased() })
        return secrets.contains { secret in
            let existingEnvironments = Set(secret.environments.map { $0.lowercased() })
            return secret.workspaceID == workspaceID &&
                secret.id != secretID &&
                secret.key.lowercased() == normalizedKey &&
                !existingEnvironments.isDisjoint(with: normalizedEnvironments)
        }
    }

    private func firstConflictSecret(workspaceID: UUID, key: String, environments: [String]) -> Secret? {
        let normalizedKey = key.lowercased()
        let normalizedEnvironments = Set(environments.map { $0.lowercased() })
        return secrets.first { secret in
            let existingEnvironments = Set(secret.environments.map { $0.lowercased() })
            return secret.workspaceID == workspaceID &&
                secret.key.lowercased() == normalizedKey &&
                !existingEnvironments.isDisjoint(with: normalizedEnvironments)
        }
    }

    private func uniqueKeyForImport(workspaceID: UUID, originalKey: String, environments: [String]) -> String {
        var counter = 1
        var candidate = originalKey
        while hasDuplicateSecret(workspaceID: workspaceID, key: candidate, environments: environments, excluding: nil) {
            candidate = "\(originalKey)_\(counter)"
            counter += 1
        }
        return candidate
    }

    private func normalizeProvider(_ provider: String?) -> String? {
        let normalizedProvider = provider?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (normalizedProvider?.isEmpty == true) ? nil : normalizedProvider
    }

    private func normalizeNotes(_ notes: String?) -> String? {
        let normalized = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (normalized?.isEmpty == true) ? nil : normalized
    }

    private func persistedNotes(_ notes: String?, existingAccount: String? = nil) throws -> (String?, String?) {
        let normalizedNotes = normalizeNotes(notes)
        guard let normalizedNotes else {
            if let existingAccount {
                try? keychain.delete(account: existingAccount)
            }
            return (nil, nil)
        }

        let account = existingAccount ?? "notes-\(UUID().uuidString)"
        try keychain.save(value: normalizedNotes, account: account)
        return (normalizedNotes, account)
    }

    private func providerMetadata(for provider: String?) -> ProviderMetadata? {
        guard let provider else { return nil }
        let normalized = provider
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        return ProviderMetadata(normalizedName: normalized, displayName: provider)
    }
}

enum AppStoreError: LocalizedError {
    case invalidInput
    case duplicateSecret
    case notFound

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "Please provide all required fields."
        case .duplicateSecret:
            return "A secret with the same key and at least one matching environment already exists in this workspace."
        case .notFound:
            return "The selected item no longer exists."
        }
    }
}
