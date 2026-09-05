# Supported HealthKit Nutrition

All **39 public dietary quantity types** listed in Apple's Nutrition Type
Identifiers documentation and the installed iOS SDK are supported end to end.
Verified September 5, 2026. These are dietary intake quantities, not blood test
results, body measurements, or counts of alcoholic beverages.

`backend/src/nutrients.json` is the MCP catalog. Swift tests compare every entry,
unit set and HealthKit identifier against `HealthKitClient.nutrients`. A shared
39-quantity fixture tests MCP ingestion, persistence, pending retrieval,
acknowledgement, iOS decoding/local storage, and HealthKit sample construction.

## Energy, Macronutrients And Fats

| Quantity | MCP `nutrient` | Accepted units | HealthKit identifier |
| --- | --- | --- | --- |
| Dietary energy | `energy` | `kcal`, `kJ` | `.dietaryEnergyConsumed` |
| Protein | `protein` | `g` | `.dietaryProtein` |
| Carbohydrates | `carbohydrates` | `g` | `.dietaryCarbohydrates` |
| Total fat | `total_fat` | `g` | `.dietaryFatTotal` |
| Saturated fat | `saturated_fat` | `g` | `.dietaryFatSaturated` |
| Monounsaturated fat | `monounsaturated_fat` | `g` | `.dietaryFatMonounsaturated` |
| Polyunsaturated fat | `polyunsaturated_fat` | `g` | `.dietaryFatPolyunsaturated` |
| Dietary fiber | `fiber` | `g` | `.dietaryFiber` |
| Sugar | `sugar` | `g` | `.dietarySugar` |
| Cholesterol | `cholesterol` | `mg`, `g` | `.dietaryCholesterol` |

## Vitamins

All vitamins accept `mcg`, `mg`, or `g`. `mcg` is the ASCII wire spelling for
micrograms; it maps to HealthKit's microgram mass unit.

| Quantity | MCP `nutrient` | HealthKit identifier |
| --- | --- | --- |
| Vitamin A | `vitamin_a` | `.dietaryVitaminA` |
| Thiamin (B1) | `thiamin` | `.dietaryThiamin` |
| Riboflavin (B2) | `riboflavin` | `.dietaryRiboflavin` |
| Niacin (B3) | `niacin` | `.dietaryNiacin` |
| Pantothenic acid (B5) | `pantothenic_acid` | `.dietaryPantothenicAcid` |
| Vitamin B6 | `vitamin_b6` | `.dietaryVitaminB6` |
| Biotin (B7) | `biotin` | `.dietaryBiotin` |
| Folate (B9) | `folate` | `.dietaryFolate` |
| Vitamin B12 | `vitamin_b12` | `.dietaryVitaminB12` |
| Vitamin C | `vitamin_c` | `.dietaryVitaminC` |
| Vitamin D | `vitamin_d` | `.dietaryVitaminD` |
| Vitamin E | `vitamin_e` | `.dietaryVitaminE` |
| Vitamin K | `vitamin_k` | `.dietaryVitaminK` |

## Minerals And Trace Minerals

| Quantity | MCP `nutrient` | Accepted units | HealthKit identifier |
| --- | --- | --- | --- |
| Calcium | `calcium` | `mcg`, `mg`, `g` | `.dietaryCalcium` |
| Chloride | `chloride` | `mcg`, `mg`, `g` | `.dietaryChloride` |
| Iron | `iron` | `mcg`, `mg`, `g` | `.dietaryIron` |
| Magnesium | `magnesium` | `mcg`, `mg`, `g` | `.dietaryMagnesium` |
| Phosphorus | `phosphorus` | `mcg`, `mg`, `g` | `.dietaryPhosphorus` |
| Potassium | `potassium` | `mg`, `g` | `.dietaryPotassium` |
| Sodium | `sodium` | `mg`, `g` | `.dietarySodium` |
| Zinc | `zinc` | `mcg`, `mg`, `g` | `.dietaryZinc` |
| Chromium | `chromium` | `mcg`, `mg`, `g` | `.dietaryChromium` |
| Copper | `copper` | `mcg`, `mg`, `g` | `.dietaryCopper` |
| Iodine | `iodine` | `mcg`, `mg`, `g` | `.dietaryIodine` |
| Manganese | `manganese` | `mcg`, `mg`, `g` | `.dietaryManganese` |
| Molybdenum | `molybdenum` | `mcg`, `mg`, `g` | `.dietaryMolybdenum` |
| Selenium | `selenium` | `mcg`, `mg`, `g` | `.dietarySelenium` |

## Water And Caffeine

| Quantity | MCP `nutrient` | Accepted units | HealthKit identifier |
| --- | --- | --- | --- |
| Water | `water` | `mL`, `L` | `.dietaryWater` |
| Caffeine | `caffeine` | `mg`, `g` | `.dietaryCaffeine` |

## Recording Rules

- One entry supports 1-39 quantities, at most one per nutrient.
- Values must be finite and positive, at most 1,000,000 in the supplied unit.
  These bounds validate inputs; they are not dietary or dosage recommendations.
- Record only explicitly supplied or confirmed quantities. Missing values are
  not estimated; zero amounts are omitted rather than saved as positive samples.
- `IU` and percent daily value are not accepted. Vitamin IU-to-mass conversions
  can depend on the vitamin/form; do not silently apply a universal conversion.
- Mass units cannot substitute for water volume. Energy is energy, not mass.
- Total fat/carbohydrates and their subtypes are separate samples; no totals
  or missing subtypes are inferred.
- HealthKit has no separate public dietary quantity identifiers for trans fat,
  added sugar, choline, or individual omega-3/omega-6 fatty acids in this catalog.
  Food correlations group samples; they are not an additional nutrient.

## Permissions And Retry Safety

After updating the iOS app, tap **Review Health permissions** to authorize the
new dietary types. Background sync cannot display permission dialogs. A record
requiring any missing permission remains pending; the app does not partially
acknowledge it. Once permissions are granted, tap **Sync now**.

The existing per-user/record/nutrient sync identifiers, sync version 1, local
write journal and post-save server acknowledgements apply to all 39 types.
No database migration or changes to already-synced records are required.

Source: [Apple Nutrition Type Identifiers](https://developer.apple.com/documentation/healthkit/nutrition-type-identifiers).
