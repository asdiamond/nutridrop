import { importPKCS8, SignJWT } from "jose";

// APNs provider credentials are service-wide, not user/request state. Reuse
// them to avoid APNs rejecting overly frequent provider-token updates.
let credential: { privateKey: string; keyId: string; teamId: string; issuedAt: number; token: string } | undefined;

export async function notifyDevice(env: Env, userId: string, recordId: string): Promise<
  "accepted_by_apns" | "not_registered" | "environment_mismatch" | "failed"
> {
  try {
    const destination = await env.DB.prepare(
      "SELECT token, environment, updated_at FROM push_tokens WHERE workos_user_id = ?",
    ).bind(userId).first<{ token: string; environment: string; updated_at: string }>();
    if (!destination) return "not_registered";
    if (destination.environment !== env.APNS_ENVIRONMENT) return "environment_mismatch";

    const now = Math.floor(Date.now() / 1000);
    if (!credential || now - credential.issuedAt >= 3000 ||
      credential.privateKey !== env.APNS_PRIVATE_KEY || credential.keyId !== env.APNS_KEY_ID ||
      credential.teamId !== env.APNS_TEAM_ID) {
      const key = await importPKCS8(env.APNS_PRIVATE_KEY, "ES256");
      const token = await new SignJWT({})
        .setProtectedHeader({ alg: "ES256", kid: env.APNS_KEY_ID })
        .setIssuer(env.APNS_TEAM_ID).setIssuedAt(now).sign(key);
      credential = { privateKey: env.APNS_PRIVATE_KEY, keyId: env.APNS_KEY_ID,
        teamId: env.APNS_TEAM_ID, issuedAt: now, token };
    }

    const host = destination.environment === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
    const response = await fetch(`https://${host}/3/device/${destination.token}`, {
      method: "POST",
      headers: {
        Authorization: `bearer ${credential.token}`,
        "apns-topic": env.APNS_TOPIC,
        "apns-push-type": "background",
        "apns-priority": "5",
        "apns-expiration": String(now + 3600),
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ aps: { "content-available": 1 }, record_id: recordId }),
      signal: AbortSignal.timeout(8000),
    });
    if (response.status === 200) return "accepted_by_apns";

    const body = await response.json<{ reason?: string }>().catch(() => ({} as { reason?: string }));
    console.error(JSON.stringify({ message: "APNs rejected notification", status: response.status,
      reason: body.reason?.match(/^[A-Za-z]+$/)?.[0] }));
    if (response.status === 410) {
      await env.DB.prepare("DELETE FROM push_tokens WHERE workos_user_id = ? AND token = ? AND environment = ? AND updated_at = ?")
        .bind(userId, destination.token, destination.environment, destination.updated_at).run();
    }
    return "failed";
  } catch (error) {
    console.error(JSON.stringify({ message: "push submission failed", errorType: error instanceof Error ? error.name : "UnknownError" }));
    return "failed";
  }
}
