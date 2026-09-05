import Foundation

nonisolated struct NutritionRecord: Codable, Identifiable, Equatable, Sendable {
    struct Quantity: Codable, Equatable, Sendable {
        let nutrient: String
        let value: Double
        let unit: String
    }
    let id: String
    let consumedAt: String
    let mealLabel: String?
    let quantities: [Quantity]
    let schemaVersion: Int
    let createdAt: String

    var consumptionDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: consumedAt)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: consumedAt)
        }
        return date
    }

    var consumptionDescription: String {
        consumptionDate?.formatted(date: .abbreviated, time: .shortened) ?? consumedAt
    }
}

nonisolated struct HealthRecordState: Codable, Equatable, Sendable {
    enum Stage: String, Codable, Sendable {
        case downloaded, awaitingPermission, writeFailed, written, synced
    }
    let stage: Stage
    var message: String?
    var writtenAt: Date?
    var acknowledgedAt: Date?

    var label: String {
        switch stage {
        case .downloaded: "Downloaded"
        case .awaitingPermission: "Awaiting Health permission"
        case .writeFailed: "Health write failed"
        case .written: "Saved to Health; awaiting server confirmation"
        case .synced: "Synced to Apple Health"
        }
    }
}

nonisolated struct NutritionPage: Decodable, Sendable {
    let records: [NutritionRecord]
    let nextCursor: String?
}

actor NutritionStore {
    private let directory: URL?

    init(directory: URL? = nil) {
        self.directory = directory
    }
    nonisolated struct Snapshot: Codable, Sendable {
        let records: [NutritionRecord]
        let nextCursor: String?
        // Optional because downloaded snapshots already exist on devices.
        var healthStates: [String: HealthRecordState]? = nil
    }
    private func file(for userID: String) throws -> URL {
        let directory = try directory ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appending(path: "Nutrition")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        // Encode the account ID rather than interpreting it as a filesystem path.
        let name = userID.utf8.map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: name + ".json")
    }

    func load(userID: String) throws -> Snapshot {
        let url = try file(for: userID)
        guard FileManager.default.fileExists(atPath: url.path) else { return Snapshot(records: [], nextCursor: nil) }
        return try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
    }

    func merge(_ page: NutritionPage, userID: String) throws -> (records: [NutritionRecord], changed: Bool) {
        let existing = try load(userID: userID)
        var records = Dictionary(uniqueKeysWithValues: existing.records.map { ($0.id, $0) })
        var changed = false
        for record in page.records {
            if records[record.id] != record { changed = true }
            records[record.id] = record
        }
        let sorted = records.values.sorted {
            ($0.createdAt, $0.id) > ($1.createdAt, $1.id)
        }
        if changed || existing.nextCursor != page.nextCursor {
            // Save progress with the records so an interrupted backlog resumes
            // after its last durable batch instead of repeatedly starting over.
            try JSONEncoder().encode(Snapshot(records: sorted, nextCursor: page.nextCursor, healthStates: existing.healthStates)).write(to: file(for: userID),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        return (sorted, changed)
    }

    func setHealthState(_ state: HealthRecordState, recordID: String, userID: String) throws {
        var snapshot = try load(userID: userID)
        guard snapshot.records.contains(where: { $0.id == recordID }) else {
            throw HealthWriteError.invalidRecord
        }
        if snapshot.healthStates?[recordID] == state { return }
        if snapshot.healthStates == nil { snapshot.healthStates = [:] }
        snapshot.healthStates?[recordID] = state
        try JSONEncoder().encode(snapshot).write(to: file(for: userID),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
