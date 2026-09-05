import { z } from "zod";

const nutrientUnits = {
  energy: ["kcal", "kJ"],
  protein: ["g"],
  carbohydrates: ["g"],
  total_fat: ["g"],
  saturated_fat: ["g"],
  fiber: ["g"],
  sugar: ["g"],
  sodium: ["mg", "g"],
  cholesterol: ["mg", "g"],
  potassium: ["mg", "g"],
  caffeine: ["mg", "g"],
} as const;

const nutrientSchema = z.enum(Object.keys(nutrientUnits) as [keyof typeof nutrientUnits]);

const quantitySchema = z
  .object({
    nutrient: nutrientSchema,
    value: z.number().finite().positive().max(1_000_000),
    unit: z.enum(["g", "mg", "kcal", "kJ"]),
  })
  .strict()
  .superRefine((quantity, context) => {
    const allowedUnits: readonly string[] = nutrientUnits[quantity.nutrient];
    if (!allowedUnits.includes(quantity.unit)) {
      context.addIssue({
        code: "custom",
        path: ["unit"],
        message: `${quantity.unit} is not valid for ${quantity.nutrient}`,
      });
    }
  });

export const nutritionInputSchema = z
  .object({
    consumed_at: z.iso.datetime({ offset: true }),
    meal_label: z.string().trim().min(1).max(120).optional(),
    quantities: z.array(quantitySchema).min(1).max(32),
  })
  .strict()
  .superRefine((input, context) => {
    const seen = new Set<string>();
    input.quantities.forEach((quantity, index) => {
      if (seen.has(quantity.nutrient)) {
        context.addIssue({
          code: "custom",
          path: ["quantities", index, "nutrient"],
          message: `Only one ${quantity.nutrient} quantity is allowed per record`,
        });
      }
      seen.add(quantity.nutrient);
    });
  });

export const nutritionOutputSchema = z.object({
  recordId: z.string(),
  status: z.literal("accepted"),
  notificationStatus: z.enum(["accepted_by_apns", "not_registered", "environment_mismatch", "failed"]),
});

export type NutritionInput = z.infer<typeof nutritionInputSchema>;

export const nutritionCursorSchema = z.tuple([z.iso.datetime(), z.uuid()]);

export async function pendingNutrition(db: D1Database, userId: string, after?: [string, string]) {
  const { results } = await db.prepare(`SELECT id, consumed_at, meal_label,
    nutrition_data, schema_version, created_at FROM nutrition_records
    WHERE workos_user_id = ? AND (created_at, id) > (?, ?)
    ORDER BY created_at, id LIMIT 51`)
    .bind(userId, after?.[0] ?? "", after?.[1] ?? "")
    .all<{ id: string; consumed_at: string; meal_label: string | null;
      nutrition_data: string; schema_version: number; created_at: string }>();
  // Nothing is acknowledged yet; fetching never consumes a record.
  const records = results.slice(0, 50).map(row => ({
    id: row.id, consumedAt: row.consumed_at, mealLabel: row.meal_label,
    quantities: JSON.parse(row.nutrition_data) as NutritionInput["quantities"],
    schemaVersion: row.schema_version, createdAt: row.created_at,
  }));
  const last = records.at(-1);
  return { records, nextCursor: results.length > 50 && last
    ? btoa(JSON.stringify([last.createdAt, last.id])) : null };
}

export async function recordNutrition(
  db: D1Database,
  workosUserId: string,
  input: NutritionInput,
): Promise<string> {
  const candidateId = crypto.randomUUID();
  const createdAt = new Date().toISOString();

  const result = await db
    .prepare(
      `INSERT INTO nutrition_records (
        id,
        workos_user_id,
        ingestion_id,
        consumed_at,
        meal_label,
        nutrition_data,
        schema_version,
        created_at
      ) VALUES (?, ?, ?, ?, ?, ?, 1, ?)`,
    )
    .bind(
      candidateId,
      workosUserId,
      candidateId,
      input.consumed_at,
      input.meal_label ?? null,
      JSON.stringify(input.quantities),
      createdAt,
    )
    .run();

  if (!result.success) {
    throw new Error("Nutrition record was not persisted");
  }

  return candidateId;
}
