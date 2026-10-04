import Foundation

/// One Mail-style condition row.
struct MatchClause: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    /// Storage keys: entire|from|to|subject|body|date
    var field: String = "entire"
    var op: String = "contains"
    var value: String = ""
    var date: String = ""

    enum CodingKeys: String, CodingKey {
        case field, op, values, date, value
    }

    init(
        id: UUID = UUID(),
        field: String = "entire",
        op: String = "contains",
        value: String = "",
        date: String = ""
    ) {
        self.id = id
        self.field = field
        self.op = op
        self.value = value
        self.date = date
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        field = try c.decode(String.self, forKey: .field)
        op = try c.decode(String.self, forKey: .op)
        if field.lowercased() == "date" {
            date = try c.decodeIfPresent(String.self, forKey: .date)
                ?? c.decodeIfPresent(String.self, forKey: .value)
                ?? ""
            value = ""
        } else if let values = try c.decodeIfPresent([String].self, forKey: .values),
                  !values.isEmpty
        {
            // Multiple values in one clause = OR; edit as comma-separated for now.
            value = values.joined(separator: ", ")
            date = ""
        } else {
            value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
            date = ""
        }
        id = UUID()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(field, forKey: .field)
        try c.encode(op, forKey: .op)
        if field.lowercased() == "date" {
            try c.encode(date, forKey: .date)
        } else {
            let parts = value
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            try c.encode(parts, forKey: .values)
        }
    }
}

/// One OR/AND group of conditions. Combine groups at the job level.
struct MatchGroup: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    /// any = OR within group; all = AND within group
    var conjunction: String = "any"
    var conditions: [MatchClause] = [MatchClause()]

    enum CodingKeys: String, CodingKey {
        case conjunction, conditions, mode
    }

    init(
        id: UUID = UUID(),
        conjunction: String = "any",
        conditions: [MatchClause] = [MatchClause()]
    ) {
        self.id = id
        self.conjunction = conjunction
        self.conditions = conditions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conjunction =
            try c.decodeIfPresent(String.self, forKey: .conjunction)
            ?? c.decodeIfPresent(String.self, forKey: .mode)
            ?? "any"
        conditions = try c.decodeIfPresent([MatchClause].self, forKey: .conditions)
            ?? [MatchClause()]
        if conditions.isEmpty {
            conditions = [MatchClause()]
        }
        id = UUID()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(conjunction, forKey: .conjunction)
        try c.encode(conditions, forKey: .conditions)
    }
}

struct ExportJob: Identifiable, Equatable, Codable {
    var id: String
    var name: String
    var outputDir: String
    /// Case-file root (parent of Email/). Empty means infer from outputDir.
    var projectDir: String?
    /// How groups combine: typically "all" → (group1) AND (group2)
    var conjunction: String
    var groups: [MatchGroup]
    var includeSent: Bool
    var includeBin: Bool
    var includeThread: Bool
    /// Optional scan root for synthetic / test mailboxes. Empty means ~/Library/Mail.
    var mailRoot: String?
    /// Base64-encoded URL bookmark data to track moved or renamed folders on disk
    var bookmark: String?

    enum CodingKeys: String, CodingKey {
        case id, name, outputDir, projectDir, match, includeSent, includeBin, includeThread, mailRoot, bookmark
    }

    init(
        id: String = UUID().uuidString,
        name: String = "New Project",
        outputDir: String = "",
        projectDir: String? = nil,
        conjunction: String = "all",
        groups: [MatchGroup] = [MatchGroup()],
        includeSent: Bool = true,
        includeBin: Bool = false,
        includeThread: Bool = false,
        mailRoot: String? = nil,
        bookmark: String? = nil
    ) {
        self.id = id
        self.name = name
        self.outputDir = outputDir
        self.projectDir = projectDir
        self.conjunction = conjunction
        self.groups = groups
        self.includeSent = includeSent
        self.includeBin = includeBin
        self.includeThread = includeThread
        self.mailRoot = mailRoot
        self.bookmark = bookmark
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        outputDir = try c.decode(String.self, forKey: .outputDir)
        projectDir = try c.decodeIfPresent(String.self, forKey: .projectDir)
        includeSent = try c.decodeIfPresent(Bool.self, forKey: .includeSent) ?? true
        includeBin = try c.decodeIfPresent(Bool.self, forKey: .includeBin) ?? false
        includeThread = try c.decodeIfPresent(Bool.self, forKey: .includeThread) ?? false
        mailRoot = try c.decodeIfPresent(String.self, forKey: .mailRoot)
        bookmark = try c.decodeIfPresent(String.self, forKey: .bookmark)
        // Ignore legacy lastRunSummary / lastRunDetail — export feedback is session-only.

        if let match = try c.decodeIfPresent(MatchPayload.self, forKey: .match) {
            conjunction = match.conjunction
            groups = match.groups
        } else {
            conjunction = "all"
            groups = [MatchGroup()]
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(outputDir, forKey: .outputDir)
        if let projectDir, !projectDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try c.encode(projectDir, forKey: .projectDir)
        }
        try c.encode(includeSent, forKey: .includeSent)
        try c.encode(includeBin, forKey: .includeBin)
        try c.encode(includeThread, forKey: .includeThread)
        if let mailRoot, !mailRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try c.encode(mailRoot, forKey: .mailRoot)
        }
        try c.encodeIfPresent(bookmark, forKey: .bookmark)
        try c.encode(
            MatchPayload(conjunction: conjunction, groups: groups),
            forKey: .match
        )
    }

    /// Case-file root implied by `outputDir`. Ignores a stale `projectDir`.
    var resolvedProjectDir: String {
        let raw = outputDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return (projectDir ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ProjectLayout.resolvedProjectRoot(outputDir: raw, stored: projectDir)
    }

    mutating func syncProjectDirFromOutput() {
        let raw = outputDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        projectDir = ProjectLayout.inferProjectRoot(from: raw)
    }
}

private struct MatchPayload: Codable {
    var conjunction: String
    var groups: [MatchGroup]

    enum CodingKeys: String, CodingKey {
        case conjunction, groups, conditions, mode, any, all
    }

    init(conjunction: String, groups: [MatchGroup]) {
        self.conjunction = conjunction
        self.groups = groups
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        if let groups = try c.decodeIfPresent([MatchGroup].self, forKey: .groups),
           !groups.isEmpty
        {
            self.groups = groups
            self.conjunction =
                try c.decodeIfPresent(String.self, forKey: .conjunction)
                ?? c.decodeIfPresent(String.self, forKey: .mode)
                ?? "all"
            return
        }

        // Flat legacy → one group
        let flatConjunction: String
        let conditions: [MatchClause]
        if let conds = try c.decodeIfPresent([MatchClause].self, forKey: .conditions) {
            conditions = conds
            flatConjunction =
                try c.decodeIfPresent(String.self, forKey: .conjunction)
                ?? c.decodeIfPresent(String.self, forKey: .mode)
                ?? "all"
        } else if let any = try c.decodeIfPresent([MatchClause].self, forKey: .any) {
            conditions = any
            flatConjunction = "any"
        } else if let all = try c.decodeIfPresent([MatchClause].self, forKey: .all) {
            conditions = all
            flatConjunction = "all"
        } else {
            conditions = [MatchClause()]
            flatConjunction = "any"
        }

        self.conjunction = "all"
        self.groups = [
            MatchGroup(
                conjunction: flatConjunction,
                conditions: conditions.isEmpty ? [MatchClause()] : conditions
            ),
        ]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(conjunction, forKey: .conjunction)
        try c.encode(groups, forKey: .groups)
    }
}

struct JobsDocument: Codable {
    var jobs: [ExportJob]
}

enum FolderStatus: Equatable {
    case unset
    case exists(URL)
    case moved(suggestedURL: URL)
    case inTrash(trashURL: URL)
    case notFound(candidateURL: URL?)

    var isValidForExport: Bool {
        if case .exists = self { return true }
        return false
    }

    var existingURL: URL? {
        if case .exists(let url) = self { return url }
        return nil
    }
}
