import { env } from "cloudflare:workers";
import { createMessageBatch, createExecutionContext, getQueueResult } from "cloudflare:test";
import { afterEach, expect, it, vi } from "vitest";
import { consumeNotifications } from "../src/notifications";
import { notifyDevice } from "../src/push";

vi.mock("../src/push", () => ({ notifyDevice: vi.fn() }));
afterEach(() => vi.resetAllMocks());

it.each(["accepted_by_apns", "not_registered", "environment_mismatch", "unregistered", "rejected", "failed"] as const)(
  "handles notification outcome %s", async outcome => {
    vi.mocked(notifyDevice).mockResolvedValue(outcome);
    const body = { userId: "user_test", recordId: crypto.randomUUID() };
    const batch = createMessageBatch("notifications", [{ id: "message", timestamp: new Date(), attempts: 1, body }]);
    const ctx = createExecutionContext();
    await consumeNotifications(batch, env);
    const result = await getQueueResult(batch, ctx);
    expect(notifyDevice).toHaveBeenCalledWith(env, body.userId, body.recordId);
    expect(result.explicitAcks).toEqual(outcome === "failed" ? [] : ["message"]);
    expect(result.retryMessages).toHaveLength(outcome === "failed" ? 1 : 0);
  },
);

it("acknowledges malformed messages without sending a push", async () => {
  vi.spyOn(console, "error").mockImplementation(() => {});
  const batch = createMessageBatch("notifications", [{ id: "invalid", timestamp: new Date(), attempts: 1, body: {} }]);
  const ctx = createExecutionContext();
  await consumeNotifications(batch, env);
  expect((await getQueueResult(batch, ctx)).explicitAcks).toEqual(["invalid"]);
  expect(notifyDevice).not.toHaveBeenCalled();
});
