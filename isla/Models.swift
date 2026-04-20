import Foundation

struct Workspace: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
}

struct Secret: Identifiable, Codable, Hashable {
    let id: UUID
    let workspaceID: UUID
    var key: String
    var keychainAccount: String
    var environments: [String]
    var provider: String?
    var notes: String?
    var notesKeychainAccount: String?
    var providerMetadata: ProviderMetadata?
    var rotationCapability: RotationCapability
    var lastRotatedAt: Date?
    var rotationHistory: [RotationHistoryEntry]
    var createdAt: Date
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case workspaceID
        case key
        case keychainAccount
        case environments
        case environment
        case provider
        case notes
        case notesKeychainAccount
        case providerMetadata
        case rotationCapability
        case lastRotatedAt
        case rotationHistory
        case createdAt
        case updatedAt
    }

    init(
        id: UUID,
        workspaceID: UUID,
        key: String,
        keychainAccount: String,
        environments: [String],
        provider: String?,
        notes: String?,
        notesKeychainAccount: String? = nil,
        providerMetadata: ProviderMetadata? = nil,
        rotationCapability: RotationCapability = .manual,
        lastRotatedAt: Date? = nil,
        rotationHistory: [RotationHistoryEntry] = [],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.key = key
        self.keychainAccount = keychainAccount
        self.environments = environments
        self.provider = provider
        self.notes = notes
        self.notesKeychainAccount = notesKeychainAccount
        self.providerMetadata = providerMetadata
        self.rotationCapability = rotationCapability
        self.lastRotatedAt = lastRotatedAt
        self.rotationHistory = rotationHistory
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        workspaceID = try container.decode(UUID.self, forKey: .workspaceID)
        key = try container.decode(String.self, forKey: .key)
        keychainAccount = try container.decode(String.self, forKey: .keychainAccount)

        if let decodedEnvironments = try container.decodeIfPresent([String].self, forKey: .environments) {
            environments = decodedEnvironments
        } else if let decodedEnvironment = try container.decodeIfPresent(String.self, forKey: .environment) {
            environments = [decodedEnvironment]
        } else {
            environments = ["dev"]
        }

        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        notesKeychainAccount = try container.decodeIfPresent(String.self, forKey: .notesKeychainAccount)
        providerMetadata = try container.decodeIfPresent(ProviderMetadata.self, forKey: .providerMetadata)
        rotationCapability = try container.decodeIfPresent(RotationCapability.self, forKey: .rotationCapability) ?? .manual
        lastRotatedAt = try container.decodeIfPresent(Date.self, forKey: .lastRotatedAt)
        rotationHistory = try container.decodeIfPresent([RotationHistoryEntry].self, forKey: .rotationHistory) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(workspaceID, forKey: .workspaceID)
        try container.encode(key, forKey: .key)
        try container.encode(keychainAccount, forKey: .keychainAccount)
        try container.encode(environments, forKey: .environments)
        try container.encodeIfPresent(provider, forKey: .provider)
        try container.encodeIfPresent(notesKeychainAccount, forKey: .notesKeychainAccount)
        try container.encode(rotationCapability, forKey: .rotationCapability)
        try container.encodeIfPresent(lastRotatedAt, forKey: .lastRotatedAt)
        try container.encode(rotationHistory, forKey: .rotationHistory)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

struct ProviderMetadata: Codable, Hashable {
    var normalizedName: String
    var displayName: String
}

enum RotationCapability: String, Codable, CaseIterable, Identifiable {
    case manual
    case adapterSupported = "adapter-supported"

    var id: String { rawValue }
}

struct RotationHistoryEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let rotatedAt: Date
    let source: String
    let note: String?
}

struct AppMetadata: Codable {
    var workspaces: [Workspace]
    var secrets: [Secret]
}

// Legacy type used only for migration from workspace->project->secret hierarchy.
struct LegacyProject: Identifiable, Codable, Hashable {
    let id: UUID
    let workspaceID: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
}

struct LegacySecret: Identifiable, Codable, Hashable {
    let id: UUID
    let projectID: UUID
    var key: String
    var keychainAccount: String
    var environment: String
    var provider: String?
    var notes: String?
    var createdAt: Date
    var updatedAt: Date
}

struct LegacyAppMetadata: Codable {
    var workspaces: [Workspace]
    var projects: [LegacyProject]
    var secrets: [LegacySecret]
}

enum ImportConflictStrategy: String, CaseIterable, Identifiable, Codable {
    case skip = "Skip"
    case overwrite = "Overwrite"
    case rename = "Rename"

    var id: String { rawValue }
}

struct EnvImportEntry: Identifiable, Hashable {
    let id = UUID()
    let lineNumber: Int
    let key: String
    let value: String
}

struct EnvImportSummary {
    let parsed: Int
    let imported: Int
    let skipped: Int
    let failed: Int
}
