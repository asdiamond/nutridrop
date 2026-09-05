import { env } from "cloudflare:workers";
import { createExecutionContext } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { createWorker } from "../src";
import { recordNutrition, pendingNutrition } from "../src/nutrition";
import migration from "../migrations/0006_healthkit_acknowledgements.sql?raw";

beforeEach(async () => {
  await env.DB.exec("DROP TABLE IF EXISTS nutrition_records");
  await env.DB.prepare(`CREATE TABLE nutrition_records (
    id TEXT PRIMARY KEY, workos_user_id TEXT NOT NULL, ingestion_id TEXT NOT NULL,
    consumed_at TEXT NOT NULL, meal_label TEXT, nutrition_data TEXT NOT NULL,
    schema_version INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL
  ) STRICT`).run();
  for (const sql of migration.split(";").filter(sql => sql.trim())) await env.DB.prepare(sql).run();
});

const input = { consumed_at: "2026-09-04T12:30:00-07:00",
  quantities: [{ nutrient: "energy" as const, value: 500, unit: "kcal" as const }] };

function acknowledge(userId: string | null, body: unknown, method = "POST", contentType = "application/json") {
  return createWorker(async () => userId ? { userId } : null).fetch(
    new Request("https://example.com/v1/nutrition/acknowledge", {
      method, headers: { "Content-Type": contentType },
      ...(method === "GET" ? {} : { body: JSON.stringify(body) }),
    }), env, createExecutionContext(),
  );
}

describe("HealthKit acknowledgements", () => {
  it("requires authentication and POST", async () => {
    expect((await acknowledge(null, { recordIds: [crypto.randomUUID()] })).status).toBe(401);
    const response = await acknowledge("user_one", {}, "GET");
    expect(response.status).toBe(405);
    expect(response.headers.get("Allow")).toBe("POST");
  });

  it("excludes acknowledged records from pending without deleting them", async () => {
    const id = await recordNutrition(env.DB, "user_one", input);
    const other = await recordNutrition(env.DB, "user_one", input);
    const response = await acknowledge("user_one", { recordIds: [id] });
    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(await response.json()).toEqual({ acknowledgedIds: [id] });
    expect((await pendingNutrition(env.DB, "user_one")).records.map(r => r.id)).toEqual([other]);
    expect((await env.DB.prepare("SELECT COUNT(*) AS count FROM nutrition_records").first())?.count).toBe(2);
  });

  it("is idempotent, including duplicate IDs, and retains the first timestamp", async () => {
    const id = await recordNutrition(env.DB, "user_one", input);
    await acknowledge("user_one", { recordIds: [id] });
    const first = await env.DB.prepare("SELECT healthkit_acknowledged_at FROM nutrition_records WHERE id = ?").bind(id).first();
    const response = await acknowledge("user_one", { recordIds: [id, id] });
    expect(await response.json()).toEqual({ acknowledgedIds: [id] });
    expect(await env.DB.prepare("SELECT healthkit_acknowledged_at FROM nutrition_records WHERE id = ?").bind(id).first()).toEqual(first);
  });

  it("never acknowledges or reveals another user's records", async () => {
    const own = await recordNutrition(env.DB, "user_one", input);
    const other = await recordNutrition(env.DB, "user_two", input);
    const response = await acknowledge("user_one", { recordIds: [own, other, crypto.randomUUID()] });
    expect(await response.json()).toEqual({ acknowledgedIds: [own] });
    expect((await pendingNutrition(env.DB, "user_two")).records.map(r => r.id)).toEqual([other]);
  });

  it.each([{}, { recordIds: [] }, { recordIds: ["invalid"] },
    { recordIds: [crypto.randomUUID()], userId: "user_two" },
    { recordIds: Array.from({ length: 51 }, () => crypto.randomUUID()) }])("rejects invalid input", async body => {
    expect((await acknowledge("user_one", body)).status).toBe(400);
  });

  it("bounds bodies and requires JSON", async () => {
    expect((await acknowledge("user_one", { padding: "x".repeat(5000) })).status).toBe(413);
    expect((await acknowledge("user_one", {}, "POST", "text/plain")).status).toBe(415);
  });
});
