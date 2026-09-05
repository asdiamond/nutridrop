import { env } from "cloudflare:workers";
import { beforeEach, afterEach, describe, expect, it, vi } from "vitest";
import { exportPKCS8, generateKeyPair, jwtVerify } from "jose";
import migration from "../migrations/0004_create_push_tokens.sql?raw";
import { notifyDevice } from "../src/push";

beforeEach(async () => {
  await env.DB.exec("DROP TABLE IF EXISTS push_tokens");
  await env.DB.prepare(migration).run();
});
afterEach(() => vi.restoreAllMocks());

async function register(environment = "sandbox") {
  await env.DB.prepare("INSERT INTO push_tokens VALUES (?, ?, ?, ?)")
    .bind("user_test", "ab".repeat(32), environment, "2026-09-05T00:00:00Z").run();
}

describe("APNs submission", () => {
  it("does not send without a destination or with a mismatched key environment", async () => {
    const fetch = vi.spyOn(globalThis, "fetch");
    expect(await notifyDevice(env, "user_test", "record")).toBe("not_registered");
    await register("production");
    expect(await notifyDevice(env, "user_test", "record")).toBe("environment_mismatch");
    expect(fetch).not.toHaveBeenCalled();
  });

  it("sends a signed, data-minimal background push and reuses the provider token", async () => {
    await register();
    const keys = await generateKeyPair("ES256", { extractable: true });
    const testEnv = { ...env, APNS_PRIVATE_KEY: await exportPKCS8(keys.privateKey) };
    const authorizations: string[] = [];
    vi.spyOn(globalThis, "fetch").mockImplementation(async (url, init) => {
      expect(String(url)).toBe(`https://api.sandbox.push.apple.com/3/device/${"ab".repeat(32)}`);
      const headers = new Headers(init?.headers);
      expect(headers.get("apns-topic")).toBe("app.nutridrop");
      expect(headers.get("apns-push-type")).toBe("background");
      expect(headers.get("apns-priority")).toBe("5");
      const authorization = headers.get("Authorization")!;
      authorizations.push(authorization);
      const verified = await jwtVerify(authorization.slice(7), keys.publicKey, { issuer: env.APNS_TEAM_ID });
      expect(verified.protectedHeader.kid).toBe(env.APNS_KEY_ID);
      expect(JSON.parse(String(init?.body))).toEqual({ aps: { "content-available": 1 }, record_id: "record" });
      return new Response(null, { status: 200 });
    });
    expect(await notifyDevice(testEnv, "user_test", "record")).toBe("accepted_by_apns");
    expect(await notifyDevice(testEnv, "user_test", "record")).toBe("accepted_by_apns");
    expect(authorizations[0]).toBe(authorizations[1]);
  });

  it("reports APNs rejection and removes an unregistered destination", async () => {
    await register();
    const keys = await generateKeyPair("ES256", { extractable: true });
    vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(globalThis, "fetch").mockResolvedValue(Response.json({ reason: "Unregistered" }, { status: 410 }));
    expect(await notifyDevice({ ...env, APNS_PRIVATE_KEY: await exportPKCS8(keys.privateKey) }, "user_test", "record"))
      .toBe("unregistered");
    expect(await env.DB.prepare("SELECT * FROM push_tokens").first()).toBeNull();
  });

  it("contains signing failures rather than failing the saved nutrition call", async () => {
    await register();
    vi.spyOn(console, "error").mockImplementation(() => {});
    expect(await notifyDevice({ ...env, APNS_PRIVATE_KEY: "invalid" }, "user_test", "record")).toBe("failed");
  });

  it.each([[429, "failed"], [503, "failed"], [400, "rejected"]])(
    "classifies APNs HTTP %s as %s", async (status, expected) => {
      await register();
      const keys = await generateKeyPair("ES256", { extractable: true });
      vi.spyOn(console, "error").mockImplementation(() => {});
      vi.spyOn(globalThis, "fetch").mockResolvedValue(Response.json({ reason: "Rejected" }, { status: Number(status) }));
      expect(await notifyDevice({ ...env, APNS_PRIVATE_KEY: await exportPKCS8(keys.privateKey) }, "user_test", "record"))
        .toBe(expected);
    },
  );
});
