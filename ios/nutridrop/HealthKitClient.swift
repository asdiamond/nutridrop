import HealthKit

@MainActor
final class HealthKitClient {
    private let store = HKHealthStore()

    nonisolated static let nutrients: [String: (HKQuantityTypeIdentifier, Set<String>)] = [
        "energy": (.dietaryEnergyConsumed, ["kcal", "kJ"]),
        "protein": (.dietaryProtein, ["g"]),
        "carbohydrates": (.dietaryCarbohydrates, ["g"]),
        "total_fat": (.dietaryFatTotal, ["g"]),
        "saturated_fat": (.dietaryFatSaturated, ["g"]),
        "monounsaturated_fat": (.dietaryFatMonounsaturated, ["g"]),
        "polyunsaturated_fat": (.dietaryFatPolyunsaturated, ["g"]),
        "fiber": (.dietaryFiber, ["g"]),
        "sugar": (.dietarySugar, ["g"]),
        "sodium": (.dietarySodium, ["mg", "g"]),
        "cholesterol": (.dietaryCholesterol, ["mg", "g"]),
        "potassium": (.dietaryPotassium, ["mg", "g"]),
        "caffeine": (.dietaryCaffeine, ["mg", "g"]),
        "vitamin_a": (.dietaryVitaminA, ["mcg", "mg", "g"]),
        "thiamin": (.dietaryThiamin, ["mcg", "mg", "g"]),
        "riboflavin": (.dietaryRiboflavin, ["mcg", "mg", "g"]),
        "niacin": (.dietaryNiacin, ["mcg", "mg", "g"]),
        "pantothenic_acid": (.dietaryPantothenicAcid, ["mcg", "mg", "g"]),
        "vitamin_b6": (.dietaryVitaminB6, ["mcg", "mg", "g"]),
        "biotin": (.dietaryBiotin, ["mcg", "mg", "g"]),
        "folate": (.dietaryFolate, ["mcg", "mg", "g"]),
        "vitamin_b12": (.dietaryVitaminB12, ["mcg", "mg", "g"]),
        "vitamin_c": (.dietaryVitaminC, ["mcg", "mg", "g"]),
        "vitamin_d": (.dietaryVitaminD, ["mcg", "mg", "g"]),
        "vitamin_e": (.dietaryVitaminE, ["mcg", "mg", "g"]),
        "vitamin_k": (.dietaryVitaminK, ["mcg", "mg", "g"]),
        "calcium": (.dietaryCalcium, ["mcg", "mg", "g"]),
        "chloride": (.dietaryChloride, ["mcg", "mg", "g"]),
        "iron": (.dietaryIron, ["mcg", "mg", "g"]),
        "magnesium": (.dietaryMagnesium, ["mcg", "mg", "g"]),
        "phosphorus": (.dietaryPhosphorus, ["mcg", "mg", "g"]),
        "zinc": (.dietaryZinc, ["mcg", "mg", "g"]),
        "chromium": (.dietaryChromium, ["mcg", "mg", "g"]),
        "copper": (.dietaryCopper, ["mcg", "mg", "g"]),
        "iodine": (.dietaryIodine, ["mcg", "mg", "g"]),
        "manganese": (.dietaryManganese, ["mcg", "mg", "g"]),
        "molybdenum": (.dietaryMolybdenum, ["mcg", "mg", "g"]),
        "selenium": (.dietarySelenium, ["mcg", "mg", "g"]),
        "water": (.dietaryWater, ["mL", "L"]),
    ]

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async throws {
        guard isAvailable else { throw HealthWriteError.unavailable }
        let types = Set(Self.nutrients.values.map { HKQuantityType($0.0) })
        // We only write. No HealthKit read permission is requested or inferred.
        try await store.requestAuthorization(toShare: types, read: [])
    }

    func save(_ record: NutritionRecord, userID: String) async throws {
        guard isAvailable else { throw HealthWriteError.unavailable }
        let samples = try Self.samples(for: record, userID: userID)
        let missing = samples.filter { store.authorizationStatus(for: $0.quantityType) != .sharingAuthorized }
        guard missing.isEmpty else { throw HealthWriteError.permissionRequired }
        // HealthKit saves an array atomically: if any sample fails, none save.
        try await store.save(samples)
    }

    nonisolated static func samples(for record: NutritionRecord, userID: String) throws -> [HKQuantitySample] {
        guard record.schemaVersion == 1, UUID(uuidString: record.id) != nil,
              !record.quantities.isEmpty, record.quantities.count <= nutrients.count,
              Set(record.quantities.map(\.nutrient)).count == record.quantities.count,
              let consumedAt = record.consumptionDate else { throw HealthWriteError.invalidRecord }
        return try record.quantities.map { quantity in
            guard let (identifier, units) = nutrients[quantity.nutrient], units.contains(quantity.unit),
                  quantity.value.isFinite, quantity.value > 0, quantity.value <= 1_000_000 else {
                throw HealthWriteError.invalidRecord
            }
            let unit: HKUnit
            switch quantity.unit {
            case "kcal": unit = .kilocalorie()
            case "kJ": unit = .jouleUnit(with: .kilo)
            case "mg": unit = .gramUnit(with: .milli)
            case "mcg": unit = .gramUnit(with: .micro)
            case "g": unit = .gram()
            case "mL": unit = .literUnit(with: .milli)
            case "L": unit = .liter()
            default: throw HealthWriteError.invalidRecord
            }
            return HKQuantitySample(type: HKQuantityType(identifier),
                quantity: HKQuantity(unit: unit, doubleValue: quantity.value), start: consumedAt, end: consumedAt,
                metadata: [
                    HKMetadataKeySyncIdentifier: "app.nutridrop.\(userID).\(record.id).\(quantity.nutrient)",
                    HKMetadataKeySyncVersion: 1,
                ])
        }
    }
}

nonisolated enum HealthWriteError: LocalizedError {
    case unavailable
    case permissionRequired
    case invalidRecord

    var errorDescription: String? {
        switch self {
        case .unavailable: "Apple Health is unavailable on this device."
        case .permissionRequired: "Allow writing all nutrients in this entry in Apple Health, then retry."
        case .invalidRecord: "This entry contains unsupported or invalid nutrition data."
        }
    }
}
