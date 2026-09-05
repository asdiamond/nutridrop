import { env } from "cloudflare:workers";
import { createExecutionContext } from "cloudflare:test";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { exportJWK, generateKeyPair, SignJWT, type JWTPayload } from "jose";
import { verifyAccessToken } from "../src/auth";
import { createWorker } from "../src";

let keys: Awaited<ReturnType<typeof generateKeyPair>>;
let jwks: { keys: Awaited<ReturnType<typeof exportJWK>>[] };

beforeAll(async () => {
  keys = await generateKeyPair("RS256");
  jwks = { keys: [{ ...await exportJWK(keys.publicKey), kid: "test", alg: "RS256" }] };
});
beforeEach(() => {
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
    expect(String(input)).toBe(`${env.WORKOS_ISSUER}/oauth2/jwks`);
    return new Response(JSON.stringify(jwks));
  });
});
afterEach(() => vi.restoreAllMocks());

async function token(overrides: JWTPayload = {}, key = keys.privateKey) {
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({
    iss: env.WORKOS_ISSUER, aud: env.MCP_RESOURCE, sub: "user_test",
    scope: "openid offline_access", iat: now, exp: now + 300, ...overrides,
  }).setProtectedHeader({ alg: "RS256", kid: "test" }).sign(key);
}

function request(accessToken: string, path = "/v1/session") {
  return new Request(`http://localhost:8787${path}`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
}

describe("Connect authentication", () => {
  it("accepts the same user from different OAuth clients", async () => {
    for (const client_id of ["ios-client", "mcp-client"]) {
      expect(await verifyAccessToken(request(await token({ client_id })), env))
        .toEqual({ userId: "user_test" });
    }
  });

  it.each([
    ["wrong issuer", { iss: "https://other.example" }],
    ["old AuthKit issuer", { iss: "https://api.workos.com/user_management/client_old" }],
    ["wrong audience", { aud: "other-resource" }],
    ["ID token audience", { aud: "ios-client" }],
    ["expired", { exp: 1 }],
    ["missing expiry", { exp: undefined }],
    ["missing issued-at", { iat: undefined }],
    ["missing user", { sub: undefined }],
    ["machine identity", { sub: "client_machine" }],
    ["missing scope", { scope: undefined }],
    ["wrong scope", { scope: "profile" }],
  ] satisfies [string, JWTPayload][])("rejects %s", async (_, claims) => {
    expect(await verifyAccessToken(request(await token(claims)), env)).toBeNull();
  });

  it("rejects a signature from another key", async () => {
    const other = await generateKeyPair("RS256");
    expect(await verifyAccessToken(request(await token({}, other.privateKey)), env)).toBeNull();
  });

  it("rejects malformed and missing bearer tokens", async () => {
    expect(await verifyAccessToken(request("not-a-jwt"), env)).toBeNull();
    expect(await verifyAccessToken(new Request("https://example.com"), env)).toBeNull();
  });

  it("uses one real verifier for REST and MCP", async () => {
    const worker = createWorker(verifyAccessToken);
    const accessToken = await token();
    const session = await worker.fetch(request(accessToken), env, createExecutionContext());
    expect(await session.json()).toEqual({ userId: "user_test" });
    const mcp = await worker.fetch(new Request("http://localhost:8787/mcp", {
      method: "POST",
      headers: {
        Host: "localhost:8787",
        Authorization: `Bearer ${accessToken}`,
        Accept: "application/json, text/event-stream",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {
        protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1" },
      } }),
    }), env, createExecutionContext());
    expect(mcp.status).toBe(200);
    expect(await mcp.text()).toContain("protocolVersion");
  });
});
