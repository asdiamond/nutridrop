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

    var consumptionDescription: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: consumedAt)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: consumedAt)
        }
        return date?.formatted(date: .abbreviated, time: .shortened) ?? consumedAt
    }
}

nonisolated struct NutritionPage: Decodable, Sendable {
    let records: [NutritionRecord]
    let nextCursor: String?
}

actor NutritionStore {
    nonisolated struct Snapshot: Codable, Sendable {
        let records: [NutritionRecord]
        let nextCursor: String?
    }
    private func file(for userID: String) throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
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
            try JSONEncoder().encode(Snapshot(records: sorted, nextCursor: page.nextCursor)).write(to: file(for: userID),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        return (sorted, changed)
    }
}
