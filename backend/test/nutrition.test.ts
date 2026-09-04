import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { nutritionInputSchema, recordNutrition } from "../src/nutrition";

const validInput = {
  consumed_at: "2026-09-03T12:30:00-07:00",
  meal_label: "Breakfast",
  quantities: [
    { nutrient: "energy" as const, value: 420, unit: "kcal" as const },
    { nutrient: "protein" as const, value: 24, unit: "g" as const },
  ],
};

beforeEach(async () => {
  await env.DB.exec("DROP TABLE IF EXISTS nutrition_records");
  await env.DB.prepare(
    `CREATE TABLE nutrition_records (
      id TEXT PRIMARY KEY,
      workos_user_id TEXT NOT NULL,
      ingestion_id TEXT NOT NULL,
      consumed_at TEXT NOT NULL,
      meal_label TEXT,
      nutrition_data TEXT NOT NULL CHECK (json_valid(nutrition_data)),
      schema_version INTEGER NOT NULL DEFAULT 1 CHECK (schema_version = 1),
      created_at TEXT NOT NULL,
      UNIQUE (workos_user_id, ingestion_id)
    ) STRICT`,
  ).run();
});

describe("nutrition input", () => {
  it("accepts explicit supported quantities", () => {
    expect(nutritionInputSchema.parse(validInput)).toEqual(validInput);
  });

  it("rejects units that do not match the nutrient", () => {
    const result = nutritionInputSchema.safeParse({
      ...validInput,
      quantities: [{ nutrient: "protein", value: 24, unit: "mg" }],
    });
    expect(result.success).toBe(false);
  });

  it("rejects duplicate nutrients", () => {
    const result = nutritionInputSchema.safeParse({
      ...validInput,
      quantities: [validInput.quantities[0], validInput.quantities[0]],
    });
    expect(result.success).toBe(false);
  });
});

describe("recordNutrition", () => {
  it("stores a versioned nutrition record", async () => {
    const recordId = await recordNutrition(env.DB, "user_123", validInput);
    const row = await env.DB.prepare(
      "SELECT workos_user_id, nutrition_data, schema_version FROM nutrition_records WHERE id = ?",
    )
      .bind(recordId)
      .first<{
        workos_user_id: string;
        nutrition_data: string;
        schema_version: number;
      }>();

    expect(row?.workos_user_id).toBe("user_123");
    expect(JSON.parse(row?.nutrition_data ?? "[]")).toEqual(validInput.quantities);
    expect(row?.schema_version).toBe(1);
  });

  it("generates a new record ID for each invocation", async () => {
    const firstId = await recordNutrition(env.DB, "user_123", validInput);
    const secondId = await recordNutrition(env.DB, "user_123", validInput);
    const count = await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM nutrition_records",
    ).first<{ count: number }>();

    expect(secondId).not.toBe(firstId);
    expect(count?.count).toBe(2);
  });

  it("stores the authenticated WorkOS user for each invocation", async () => {
    const recordId = await recordNutrition(env.DB, "user_456", validInput);
    const row = await env.DB.prepare(
      "SELECT workos_user_id FROM nutrition_records WHERE id = ?",
    )
      .bind(recordId)
      .first<{ workos_user_id: string }>();

    expect(row?.workos_user_id).toBe("user_456");
  });
});
