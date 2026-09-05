import { describe, expect, it } from "vitest";
import { z } from "zod";
import nutrients from "../src/nutrients.json";
import { nutritionInputSchema } from "../src/nutrition";
import record from "./fixtures/all-nutrients.json";

describe("complete HealthKit dietary catalog", () => {
  it("exposes all 39 distinct types in the MCP JSON schema and accepts one complete record", () => {
    expect(Object.keys(nutrients)).toHaveLength(39);
    expect(new Set(Object.values(nutrients).map(n => n.healthKitIdentifier)).size).toBe(39);
    expect(record.quantities.map(q => q.nutrient).sort()).toEqual(Object.keys(nutrients).sort());
    const input = { consumed_at: record.consumedAt, meal_label: record.mealLabel, quantities: record.quantities };
    expect(nutritionInputSchema.parse(input)).toEqual(input);
    const schema = z.toJSONSchema(nutritionInputSchema, { unrepresentable: "any" });
    const quantities = schema.properties?.quantities as { maxItems: number; items: { properties: { nutrient: { enum: string[] } } } };
    expect(quantities.maxItems).toBe(39);
    expect(quantities.items.properties.nutrient.enum.sort()).toEqual(Object.keys(nutrients).sort());
  });

  it("validates every nutrient against every wire unit", () => {
    for (const [nutrient, definition] of Object.entries(nutrients)) {
      for (const unit of ["g", "mg", "mcg", "kcal", "kJ", "mL", "L", "IU", "%", "oz"]) {
        const result = nutritionInputSchema.safeParse({ consumed_at: record.consumedAt,
          quantities: [{ nutrient, value: 2, unit }] });
        expect(result.success, `${nutrient}/${unit}`).toBe(definition.units.includes(unit));
      }
    }
  });

  it("rejects more than 39 quantities and unsupported dietary names", () => {
    expect(nutritionInputSchema.safeParse({ consumed_at: record.consumedAt,
      quantities: [...record.quantities, record.quantities[0]] }).success).toBe(false);
    for (const nutrient of ["trans_fat", "added_sugar", "omega_3", "choline"]) {
      expect(nutritionInputSchema.safeParse({ consumed_at: record.consumedAt,
        quantities: [{ nutrient, value: 2, unit: "g" }] }).success).toBe(false);
    }
  });
});
