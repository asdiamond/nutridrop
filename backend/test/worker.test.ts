import { env } from "cloudflare:workers";
import { createExecutionContext } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createWorker } from "../src";
import fullRecord from "./fixtures/all-nutrients.json";

const IncomingRequest = Request<unknown, IncomingRequestCfProperties>;
afterEach(() => vi.restoreAllMocks());

describe("MCP Worker", () => {
  it("publishes protected resource metadata", async () => {
    const worker = createWorker(async () => null);
    const request = new IncomingRequest(
      "http://example.com/.well-known/oauth-protected-resource",
    );
    const response = await worker.fetch(request, env, createExecutionContext());

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      resource: env.MCP_RESOURCE,
      authorization_servers: [env.WORKOS_ISSUER],
      scopes_supported: ["openid"],
      bearer_methods_supported: ["header"],
    });
  });

  it("challenges unauthenticated MCP requests", async () => {
    const worker = createWorker(async () => null);
    const request = new IncomingRequest("http://example.com/mcp", { method: "POST" });
    const response = await worker.fetch(request, env, createExecutionContext());

    expect(response.status).toBe(401);
    expect(response.headers.get("WWW-Authenticate")).toContain(
      "resource_metadata=\"http://localhost:8787/.well-known/oauth-protected-resource\"",
    );
  });

  it("does not expose other application routes", async () => {
    const worker = createWorker(async () => null);
    const request = new IncomingRequest("http://example.com/");
    const response = await worker.fetch(request, env, createExecutionContext());

    expect(response.status).toBe(404);
  });

  it("rejects unauthenticated iOS session checks", async () => {
    const worker = createWorker(async () => null);
    const request = new IncomingRequest("http://example.com/v1/session");
    const response = await worker.fetch(request, env, createExecutionContext());

    expect(response.status).toBe(401);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(await response.json()).toEqual({ error: "unauthorized" });
  });

  it("returns the verified identity to the signed-in client", async () => {
    const worker = createWorker(async () => ({
      userId: "user_authenticated",
    }));
    const request = new IncomingRequest("http://example.com/v1/session", {
      headers: { Authorization: "Bearer ios-test-token" },
    });
    const response = await worker.fetch(request, env, createExecutionContext());

    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(await response.json()).toEqual({ userId: "user_authenticated" });
  });

  it("rejects unsupported session methods", async () => {
    const worker = createWorker(async () => null);
    const response = await worker.fetch(
      new IncomingRequest("http://example.com/v1/session", { method: "POST" }),
      env, createExecutionContext(),
    );
    expect(response.status).toBe(405);
    expect(response.headers.get("Allow")).toBe("GET");
  });

  it.each([false, true])("persists nutrition even if queue publishing fails: %s", async (publishFails) => {
    const send = vi.spyOn(env.NOTIFICATIONS, "send");
    if (publishFails) {
      send.mockRejectedValue(new Error("Queue unavailable"));
      vi.spyOn(console, "error").mockImplementation(() => {});
    } else {
      send.mockResolvedValue({ metadata: { metrics: { backlogCount: 1, backlogBytes: 100 } } });
    }
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
        healthkit_acknowledged_at TEXT,
        UNIQUE (workos_user_id, ingestion_id)
      ) STRICT`,
    ).run();

    const worker = createWorker(
      async () => ({
        userId: "user_authenticated",
      }),
    );
    const request = new IncomingRequest("http://localhost:8787/mcp", {
      method: "POST",
      headers: {
        Authorization: "Bearer test-token",
        Accept: "application/json, text/event-stream",
        "Content-Type": "application/json",
        Host: "localhost:8787",
      },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
          name: "record_nutrition",
          arguments: {
            consumed_at: fullRecord.consumedAt,
            meal_label: fullRecord.mealLabel,
            quantities: fullRecord.quantities,
          },
        },
      }),
    });

    const response = await worker.fetch(request, env, createExecutionContext());
    const responseText = await response.text();
    const dataLine = responseText.split("\n").find((line) => line.startsWith("data: "));
    const body = JSON.parse(dataLine?.slice(6) ?? "{}") as {
      result?: { structuredContent?: { status?: string; recordId?: string; notificationStatus?: string } };
    };
    const stored = await env.DB.prepare(
      "SELECT workos_user_id FROM nutrition_records ORDER BY created_at DESC LIMIT 1",
    )
      .first<{ workos_user_id: string }>();

    expect(response.status, JSON.stringify(body)).toBe(200);
    expect(body.result?.structuredContent?.status).toBe("accepted");
    expect(body.result?.structuredContent?.notificationStatus).toBe(publishFails ? "enqueue_failed" : "queued");
    expect(send).toHaveBeenCalledExactlyOnceWith({ userId: "user_authenticated", recordId: body.result?.structuredContent?.recordId });
    expect(stored?.workos_user_id).toBe("user_authenticated");
    const pending = await worker.fetch(new IncomingRequest("http://localhost:8787/v1/nutrition/pending"), env, createExecutionContext());
    const page = await pending.json<{ records: unknown[] }>();
    expect(page.records).toEqual([{ ...fullRecord, id: body.result?.structuredContent?.recordId, createdAt: expect.any(String) }]);
    const acknowledged = await worker.fetch(new IncomingRequest("http://localhost:8787/v1/nutrition/acknowledge", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ recordIds: [body.result?.structuredContent?.recordId] }),
    }), env, createExecutionContext());
    expect(acknowledged.status).toBe(200);
    const remaining = await worker.fetch(new IncomingRequest("http://localhost:8787/v1/nutrition/pending"), env, createExecutionContext());
    expect(await remaining.json()).toEqual({ records: [], nextCursor: null });
  });
});
