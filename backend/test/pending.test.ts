import { env } from "cloudflare:workers";
import { createExecutionContext } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { createWorker } from "../src";
import { recordNutrition } from "../src/nutrition";

beforeEach(async () => {
  await env.DB.exec("DROP TABLE IF EXISTS nutrition_records");
  await env.DB.prepare(`CREATE TABLE nutrition_records (
    id TEXT PRIMARY KEY, workos_user_id TEXT NOT NULL, ingestion_id TEXT NOT NULL,
    consumed_at TEXT NOT NULL, meal_label TEXT, nutrition_data TEXT NOT NULL,
    schema_version INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL, healthkit_acknowledged_at TEXT
  ) STRICT`).run();
});

function get(userId: string | null, cursor?: string, method = "GET") {
  const url = new URL("https://example.com/v1/nutrition/pending");
  if (cursor !== undefined) url.searchParams.set("cursor", cursor);
  return createWorker(async () => userId ? { userId } : null)
    .fetch(new Request(url, { method }), env, createExecutionContext());
}

type Page = { records: { id: string; consumedAt: string; mealLabel: string | null;
  quantities: unknown[]; schemaVersion: number; createdAt: string }[]; nextCursor: string | null };

describe("pending nutrition", () => {
  it("requires authentication and GET", async () => {
    expect((await get(null)).status).toBe(401);
    const response = await get("user_one", undefined, "POST");
    expect(response.status).toBe(405);
    expect(response.headers.get("Allow")).toBe("GET");
  });

  it("returns an empty bounded page", async () => {
    const response = await get("user_one");
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(await response.json()).toEqual({ records: [], nextCursor: null });
  });

  it("returns actual data only for the verified user, without consuming it", async () => {
    const input = { consumed_at: "2026-09-04T12:30:00-07:00", meal_label: "Lunch",
      quantities: [{ nutrient: "energy" as const, value: 500, unit: "kcal" as const }] };
    const id = await recordNutrition(env.DB, "user_one", input);
    await recordNutrition(env.DB, "user_two", input);
    const page = await (await get("user_one")).json<Page>();
    expect(page.records).toHaveLength(1);
    expect(page.records[0]).toMatchObject({ id, consumedAt: input.consumed_at,
      mealLabel: "Lunch", quantities: input.quantities, schemaVersion: 1 });
    expect(await (await get("user_one")).json()).toEqual(page);
  });

  it("paginates a backlog without skipping timestamp ties or leaking another user", async () => {
    const ids = Array.from({ length: 103 }, () => crypto.randomUUID()).sort();
    const timestamp = "2026-09-04T20:00:00.000Z";
    await env.DB.batch(ids.map(id => env.DB.prepare(`INSERT INTO nutrition_records
      VALUES (?, 'user_one', ?, ?, NULL, '[]', 1, ?, NULL)`).bind(id, id, timestamp, timestamp)));
    await env.DB.prepare(`INSERT INTO nutrition_records VALUES (?, 'user_two', ?, ?, NULL, '[]', 1, ?, NULL)`)
      .bind(crypto.randomUUID(), crypto.randomUUID(), timestamp, timestamp).run();
    const first = await (await get("user_one")).json<Page>();
    expect(first.records).toHaveLength(50);
    expect(first.nextCursor).not.toBeNull();
    const second = await (await get("user_one", first.nextCursor!)).json<Page>();
    const third = await (await get("user_one", second.nextCursor!)).json<Page>();
    expect(second.records).toHaveLength(50);
    expect(third.records).toHaveLength(3);
    expect(third.nextCursor).toBeNull();
    expect([...first.records, ...second.records, ...third.records].map(r => r.id)).toEqual(ids);
    expect((await (await get("user_three", first.nextCursor!)).json<Page>()).records).toEqual([]);
  });

  it.each(["", "not-base64", btoa("{}"), btoa('["bad-date","bad-id"]'), "a".repeat(257)])(
    "rejects malformed cursor %s", async cursor => {
      expect((await get("user_one", cursor)).status).toBe(400);
    },
  );
});
