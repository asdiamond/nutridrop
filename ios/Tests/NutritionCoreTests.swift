import Foundation
import HealthKit
import Testing
@testable import NutritionCore

private func record(_ quantities: [NutritionRecord.Quantity], id: String = UUID().uuidString,
                    consumedAt: String = "2026-09-04T12:30:00-07:00", schemaVersion: Int = 1) -> NutritionRecord {
    NutritionRecord(id: id, consumedAt: consumedAt, mealLabel: "Lunch", quantities: quantities,
                    schemaVersion: schemaVersion, createdAt: "2026-09-04T19:30:00.000Z")
}

@Test func mapsEverySupportedNutrientAndUnit() throws {
    for (nutrient, (identifier, units)) in HealthKitClient.nutrients {
        for unit in units {
            let input = record([.init(nutrient: nutrient, value: 2, unit: unit)])
            let samples = try HealthKitClient.samples(for: input, userID: "user_one")
            #expect(samples.count == 1)
            #expect(samples[0].quantityType.identifier == identifier.rawValue)
            #expect(samples[0].startDate == input.consumptionDate)
            #expect(samples[0].endDate == input.consumptionDate)
            let target: HKUnit = nutrient == "energy" ? .kilocalorie() : nutrient == "water" ? .liter() : .gram()
            let expected: Double
            switch unit {
            case "mcg": expected = 0.000002
            case "mg", "mL": expected = 0.002
            case "kJ": expected = 2 / 4.184
            default: expected = 2
            }
            #expect(abs(samples[0].quantity.doubleValue(for: target) - expected) < 0.000000001)
        }
    }
}

@Test func healthKitMappingMatchesTheEntireMcpCatalog() throws {
    struct Definition: Decodable {
        let healthKitIdentifier: String
        let units: Set<String>
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../backend")
    let catalog = try JSONDecoder().decode([String: Definition].self,
        from: Data(contentsOf: root.appending(path: "src/nutrients.json")))
    #expect(catalog.count == 39)
    #expect(Set(catalog.keys) == Set(HealthKitClient.nutrients.keys))
    for (name, definition) in catalog {
        let mapping = try #require(HealthKitClient.nutrients[name])
        #expect(mapping.0.rawValue == definition.healthKitIdentifier)
        #expect(mapping.1 == definition.units)
    }
}

@Test func fullWireRecordPersistsAndBuildsAll39HealthSamples() async throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "../../backend/test/fixtures/all-nutrients.json")
    let input = try JSONDecoder().decode(NutritionRecord.self, from: Data(contentsOf: fixture))
    let directory = FileManager.default.temporaryDirectory.appending(path: "nutridrop-catalog-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NutritionStore(directory: directory)
    _ = try await store.merge(.init(records: [input], nextCursor: nil), userID: "user_test")
    let reopened = NutritionStore(directory: directory)
    let saved = try #require(try await reopened.load(userID: "user_test").records.first)
    #expect(saved == input)
    let samples = try HealthKitClient.samples(for: saved, userID: "user_test")
    #expect(samples.count == 39)
    #expect(Set(samples.compactMap { $0.metadata?[HKMetadataKeySyncIdentifier] as? String }).count == 39)
    #expect(Set(samples.map { $0.quantityType.identifier }).count == 39)
}

@Test func retryIdentifiersAreStableAndDistinct() throws {
    let input = record([.init(nutrient: "energy", value: 10, unit: "kcal"),
                        .init(nutrient: "protein", value: 2, unit: "g")])
    let first = try HealthKitClient.samples(for: input, userID: "user_one")
    let retry = try HealthKitClient.samples(for: input, userID: "user_one")
    let otherUser = try HealthKitClient.samples(for: input, userID: "user_two")
    func identifier(_ sample: HKQuantitySample) -> String? { sample.metadata?[HKMetadataKeySyncIdentifier] as? String }
    #expect(identifier(first[0]) == identifier(retry[0]))
    #expect(identifier(first[0]) != identifier(first[1]))
    #expect(identifier(first[0]) != identifier(otherUser[0]))
    #expect(first[0].metadata?[HKMetadataKeySyncVersion] as? Int == 1)
}

@Test func rejectsInvalidSamplesBeforeConstructingWrites() {
    let valid = NutritionRecord.Quantity(nutrient: "protein", value: 2, unit: "g")
    for input in [record([]), record([valid, valid]), record([valid], consumedAt: "invalid"),
                  record([valid], schemaVersion: 2), record([valid], id: "invalid"),
                  record([.init(nutrient: "protein", value: 2, unit: "mg")]),
                  record([.init(nutrient: "unknown", value: 2, unit: "g")]),
                  record([.init(nutrient: "protein", value: .infinity, unit: "g")]),
                  record([.init(nutrient: "protein", value: 0, unit: "g")])] {
        #expect(throws: HealthWriteError.self) { try HealthKitClient.samples(for: input, userID: "user_one") }
    }
}

@Test func timestampOffsetsAndFractionalSeconds() throws {
    let first = record([], consumedAt: "2026-09-04T12:30:00-07:00")
    let utc = record([], consumedAt: "2026-09-04T19:30:00.000Z")
    #expect(first.consumptionDate != nil)
    #expect(first.consumptionDate == utc.consumptionDate)
}

@Test func durableStatesSurvivePageReplayAndRemainAccountScoped() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "nutridrop-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NutritionStore(directory: directory)
    let input = record([.init(nutrient: "energy", value: 10, unit: "kcal")])
    let page = NutritionPage(records: [input], nextCursor: "next")
    _ = try await store.merge(page, userID: "user_one")
    let written = HealthRecordState(stage: .written, message: "Ack failed", writtenAt: Date())
    try await store.setHealthState(written, recordID: input.id, userID: "user_one")
    _ = try await store.merge(page, userID: "user_one")
    let reopened = NutritionStore(directory: directory)
    let saved = try await reopened.load(userID: "user_one")
    #expect(saved.records.count == 1)
    #expect(saved.nextCursor == "next")
    #expect(saved.healthStates?[input.id] == written)
    #expect(try await reopened.load(userID: "user_two").records.isEmpty)
    let synced = HealthRecordState(stage: .synced, writtenAt: written.writtenAt, acknowledgedAt: Date())
    try await reopened.setHealthState(synced, recordID: input.id, userID: "user_one")
    _ = try await reopened.merge(.init(records: [input], nextCursor: nil), userID: "user_one")
    #expect(try await reopened.load(userID: "user_one").healthStates?[input.id] == synced)
}

@Test func readsExistingDownloadSnapshotWithoutHealthState() throws {
    let snapshot = try JSONDecoder().decode(NutritionStore.Snapshot.self,
        from: Data(#"{"records":[],"nextCursor":null}"#.utf8))
    #expect(snapshot.healthStates == nil)
}
