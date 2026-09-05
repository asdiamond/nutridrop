import { z } from "zod";
import { notifyDevice } from "./push";

const notificationSchema = z.object({ userId: z.string().startsWith("user_"), recordId: z.uuid() }).strict();

export async function consumeNotifications(batch: MessageBatch<unknown>, env: Env): Promise<void> {
  for (const message of batch.messages) {
    const parsed = notificationSchema.safeParse(message.body);
    if (!parsed.success) {
      console.error(JSON.stringify({ message: "invalid notification queue message", messageId: message.id }));
      message.ack();
      continue;
    }
    const { userId, recordId } = parsed.data;
    const outcome = await notifyDevice(env, userId, recordId);
    console.log(JSON.stringify({ message: "notification processed", messageId: message.id,
      recordId, attempt: message.attempts, outcome }));
    if (outcome === "failed") message.retry();
    else message.ack();
  }
}
