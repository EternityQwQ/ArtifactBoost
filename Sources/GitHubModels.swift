import Foundation

struct GHUser: Codable {
    let login: String
    let avatarURL: URL?
    enum CodingKeys: String, CodingKey {
        case login
        case avatarURL = "avatar_url"
    }
}

struct GHRepo: Codable, Identifiable, Hashable {
    let id: Int64
    let name: String
    let fullName: String
    let isPrivate: Bool
    let updatedAt: Date?
    let defaultBranch: String?
    let language: String?
    let stargazersCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, language
        case fullName = "full_name"
        case isPrivate = "private"
        case updatedAt = "updated_at"
        case defaultBranch = "default_branch"
        case stargazersCount = "stargazers_count"
    }

    var owner: String { fullName.split(separator: "/").first.map(String.init) ?? "" }
}

struct RepoSearchResponse: Codable {
    let items: [GHRepo]
}

struct GHWorkflowRun: Codable, Identifiable, Hashable {
    let id: Int64
    let name: String?
    let displayTitle: String?
    let runNumber: Int
    let status: String?
    let conclusion: String?
    let headBranch: String?
    let event: String?
    let createdAt: Date?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, event
        case displayTitle = "display_title"
        case runNumber = "run_number"
        case headBranch = "head_branch"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var isRunning: Bool { status != "completed" }
}

struct RunsResponse: Codable {
    let totalCount: Int
    let workflowRuns: [GHWorkflowRun]
    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case workflowRuns = "workflow_runs"
    }
}

struct GHArtifact: Codable, Identifiable, Hashable {
    let id: Int64
    let name: String
    let sizeInBytes: Int64
    let expired: Bool
    let createdAt: Date?
    let expiresAt: Date?
    enum CodingKeys: String, CodingKey {
        case id, name, expired
        case sizeInBytes = "size_in_bytes"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }
}

struct ArtifactsResponse: Codable {
    let totalCount: Int
    let artifacts: [GHArtifact]
    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case artifacts
    }
}

/// 正式版（Release）
struct GHRelease: Codable, Identifiable, Hashable {
    let id: Int64
    let tagName: String
    let name: String?
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let publishedAt: Date?
    let assets: [GHReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case id, name, body, draft, prerelease, assets
        case tagName = "tag_name"
        case publishedAt = "published_at"
    }

    var displayName: String { (name?.isEmpty == false ? name! : tagName) }
}

struct GHReleaseAsset: Codable, Identifiable, Hashable {
    let id: Int64
    let name: String
    let size: Int64
    let downloadCount: Int
    let contentType: String?

    enum CodingKeys: String, CodingKey {
        case id, name, size
        case downloadCount = "download_count"
        case contentType = "content_type"
    }
}

struct GHBranch: Codable, Identifiable, Hashable {
    let name: String
    var id: String { name }
}