import { z } from "zod";
import nutrients from "./nutrients.json";

const nutrientSchema = z.enum(Object.keys(nutrients) as [keyof typeof nutrients])
  .describe("HealthKit dietary quantities. Thiamin=B1, riboflavin=B2, niacin=B3, pantothenic_acid=B5, biotin=B7, folate=B9. Only record explicit amounts; do not infer missing values or derive totals from subtypes.");

const quantitySchema = z
  .object({
    nutrient: nutrientSchema,
    value: z.number().finite().positive().max(1_000_000),
    unit: z.enum(["g", "mg", "mcg", "kcal", "kJ", "mL", "L"])
      .describe("Energy: kcal or kJ. Water: mL or L. Protein/carbohydrates/fats/fiber/sugar: g. Cholesterol/sodium/potassium/caffeine: mg or g. Vitamins and other minerals: mcg, mg or g. mcg means micrograms. Do not supply IU, percent daily value, or infer missing quantities."),
  })
  .strict()
  .superRefine((quantity, context) => {
    const allowedUnits = nutrients[quantity.nutrient].units;
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
    quantities: z.array(quantitySchema).min(1).max(Object.keys(nutrients).length),
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
  notificationStatus: z.enum(["queued", "enqueue_failed"]),
});

export type NutritionInput = z.infer<typeof nutritionInputSchema>;

export const nutritionCursorSchema = z.tuple([z.iso.datetime(), z.uuid()]);
export const nutritionAcknowledgementSchema = z.object({
  recordIds: z.array(z.uuid()).min(1).max(50),
}).strict();

export async function acknowledgeNutrition(db: D1Database, userId: string, recordIds: string[]) {
  const ids = [...new Set(recordIds)];
  const { results } = await db.prepare(`UPDATE nutrition_records
    SET healthkit_acknowledged_at = COALESCE(healthkit_acknowledged_at, ?)
    WHERE workos_user_id = ? AND id IN (${ids.map(() => "?").join(",")}) RETURNING id`)
    .bind(new Date().toISOString(), userId, ...ids).all<{ id: string }>();
  return { acknowledgedIds: results.map(row => row.id) };
}

export async function pendingNutrition(db: D1Database, userId: string, after?: [string, string]) {
  const { results } = await db.prepare(`SELECT id, consumed_at, meal_label,
    nutrition_data, schema_version, created_at FROM nutrition_records
    WHERE workos_user_id = ? AND healthkit_acknowledged_at IS NULL AND (created_at, id) > (?, ?)
    ORDER BY created_at, id LIMIT 51`)
    .bind(userId, after?.[0] ?? "", after?.[1] ?? "")
    .all<{ id: string; consumed_at: string; meal_label: string | null;
      nutrition_data: string; schema_version: number; created_at: string }>();
  // Fetching never consumes a record; only the acknowledgement endpoint does.
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
