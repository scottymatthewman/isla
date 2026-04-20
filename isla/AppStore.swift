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
        }
        secrets.removeAll { $0.workspaceID == workspaceID }
        workspaces.removeAll { $0.id == workspaceID }
        persist()
    }

    func addSecret(workspaceID: UUID, key: String, value: String, environments: [String], provider: String?) throws {
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

        let normalizedProvider = provider?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedProvider = (normalizedProvider?.isEmpty == true) ? nil : normalizedProvider

        secrets.append(
            Secret(
                id: UUID(),
                workspaceID: workspaceID,
                key: cleanedKey,
                keychainAccount: account,
                environments: cleanedEnvironments,
                provider: cleanedProvider,
                notes: nil,
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
        provider: String?
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

        let normalizedProvider = provider?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedProvider = (normalizedProvider?.isEmpty == true) ? nil : normalizedProvider

        secrets[index].key = cleanedKey
        secrets[index].environments = cleanedEnvironments
        secrets[index].provider = cleanedProvider
        secrets[index].updatedAt = Date()
        persist()
    }

    func deleteSecret(secretID: UUID) {
        guard let secret = secrets.first(where: { $0.id == secretID }) else { return }
        try? keychain.delete(account: secret.keychainAccount)
        secrets.removeAll { $0.id == secretID }
        persist()
    }

    func readSecretValue(secretID: UUID) -> String? {
        guard let secret = secrets.first(where: { $0.id == secretID }) else {
            return nil
        }
        return try? keychain.read(account: secret.keychainAccount)
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
                secrets = metadata.secrets
            } else {
                let legacy = try decoder.decode(LegacyAppMetadata.self, from: data)
                let migratedSecrets: [Secret] = legacy.secrets.compactMap { legacySecret in
                    guard let project = legacy.projects.first(where: { $0.id == legacySecret.projectID }) else {
                        return nil
                    }
                    return Secret(
                        id: legacySecret.id,
                        workspaceID: project.workspaceID,
                        key: legacySecret.key,
                        keychainAccount: legacySecret.keychainAccount,
                        environments: [legacySecret.environment],
                        provider: legacySecret.provider,
                        notes: legacySecret.notes,
                        createdAt: legacySecret.createdAt,
                        updatedAt: legacySecret.updatedAt
                    )
                }
                workspaces = legacy.workspaces
                secrets = migratedSecrets
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
