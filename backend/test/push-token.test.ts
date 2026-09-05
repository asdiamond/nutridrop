import { env } from "cloudflare:workers";
import { createExecutionContext } from "cloudflare:test";
import migration from "../migrations/0004_create_push_tokens.sql?raw";
import { beforeEach, describe, expect, it } from "vitest";
import { createWorker } from "../src";

beforeEach(async () => {
  await env.DB.exec("DROP TABLE IF EXISTS push_tokens");
  await env.DB.prepare(migration).run();
});

async function send(userId: string | null, body: unknown, method = "PUT") {
  return createWorker(async () => userId ? { userId } : null).fetch(new Request("https://example.com/v1/push-token", {
    method, headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
  }), env, createExecutionContext());
}
const registration = { token: "ab".repeat(32), environment: "sandbox" };

describe("push-token registration", () => {
  it("requires authentication", async () => {
    expect((await send(null, registration)).status).toBe(401);
  });

  it("stores the authenticated user's destination and is idempotent", async () => {
    expect((await send("user_one", registration)).status).toBe(204);
    expect((await send("user_one", registration)).status).toBe(204);
    const rows = await env.DB.prepare("SELECT workos_user_id, token, environment FROM push_tokens").all();
    expect(rows.results).toEqual([{ workos_user_id: "user_one", ...registration }]);
  });

  it("replaces the user's previous phone and environment", async () => {
    await send("user_one", registration);
    await send("user_one", { token: "CD".repeat(48), environment: "production" });
    const rows = await env.DB.prepare("SELECT token, environment FROM push_tokens").all();
    expect(rows.results).toEqual([{ token: "cd".repeat(48), environment: "production" }]);
  });

  it("moves a token to its newly signed-in account", async () => {
    await send("user_one", registration);
    await send("user_two", registration);
    const rows = await env.DB.prepare("SELECT workos_user_id FROM push_tokens").all();
    expect(rows.results).toEqual([{ workos_user_id: "user_two" }]);
  });

  it("keeps different users' destinations separate", async () => {
    await send("user_one", registration);
    await send("user_two", { ...registration, token: "cd".repeat(32) });
    expect((await env.DB.prepare("SELECT COUNT(*) AS count FROM push_tokens").first())?.count).toBe(2);
  });

  it("deletes only the matching user's current destination", async () => {
    await send("user_one", registration);
    await send("user_two", registration, "DELETE");
    await send("user_one", { ...registration, token: "cd".repeat(32) }, "DELETE");
    expect((await env.DB.prepare("SELECT COUNT(*) AS count FROM push_tokens").first())?.count).toBe(1);
    expect((await send("user_one", registration, "DELETE")).status).toBe(204);
    expect((await env.DB.prepare("SELECT COUNT(*) AS count FROM push_tokens").first())?.count).toBe(0);
  });

  it.each([
    { ...registration, userId: "user_other" },
    { ...registration, environment: "development" },
    { ...registration, token: "not-hex" },
    { ...registration, token: "abc" },
    { ...registration, token: "" },
  ])("rejects invalid input %j", async input => {
    expect((await send("user_one", input)).status).toBe(400);
  });

  it("bounds request bodies", async () => {
    expect((await send("user_one", { ...registration, token: "a".repeat(5000) })).status).toBe(413);
  });

  it("rejects malformed JSON and unsupported media types and methods", async () => {
    const worker = createWorker(async () => ({ userId: "user_one" }));
    for (const [method, contentType, body, expected] of [
      ["PUT", "application/json", "{", 400],
      ["PUT", "text/plain", "{}", 415],
      ["POST", "application/json", "{}", 405],
    ] as const) {
      const response = await worker.fetch(new Request("https://example.com/v1/push-token", {
        method, headers: { "Content-Type": contentType }, body,
      }), env, createExecutionContext());
      expect(response.status).toBe(expected);
    }
  });
});
