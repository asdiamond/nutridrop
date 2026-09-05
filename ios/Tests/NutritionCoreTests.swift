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
            let target: HKUnit = nutrient == "energy" ? .kilocalorie() : .gram()
            let expected = unit == "mg" ? 0.002 : unit == "kJ" ? 2 / 4.184 : 2
            #expect(abs(samples[0].quantity.doubleValue(for: target) - expected) < 0.000001)
        }
    }
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
