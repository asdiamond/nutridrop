import { McpServer } from "@modelcontextprotocol/server";
import { createMcpHandler } from "agents/mcp/server";
import { z } from "zod";
import { verifyAccessToken, type TokenVerifier } from "./auth";
import { notifyDevice } from "./push";
import {
  nutritionInputSchema,
  nutritionOutputSchema,
  recordNutrition,
} from "./nutrition";

const MAX_MCP_BODY_BYTES = 64 * 1024;

const pushTokenSchema = z.object({
  token: z.string().min(2).max(1024).regex(/^(?:[a-fA-F0-9]{2})+$/).transform(value => value.toLowerCase()),
  environment: z.enum(["sandbox", "production"]),
}).strict();

function protectedResourceMetadata(env: Env): Response {
  return Response.json({
    resource: env.MCP_RESOURCE,
    authorization_servers: [env.WORKOS_ISSUER.replace(/\/$/, "")],
    scopes_supported: ["openid"],
    bearer_methods_supported: ["header"],
  });
}

function unauthorized(env: Env): Response {
  const metadataUrl = new URL("/.well-known/oauth-protected-resource", env.MCP_RESOURCE);
  return Response.json(
    { error: "unauthorized" },
    {
      status: 401,
      headers: {
        "Cache-Control": "no-store",
        "WWW-Authenticate": `Bearer resource_metadata="${metadataUrl.href}", scope="openid"`,
      },
    },
  );
}

async function parseJsonBody(request: Request, maxBytes: number): Promise<unknown> {
  const contentLength = request.headers.get("Content-Length");
  if (contentLength && Number(contentLength) > maxBytes) {
    throw new RangeError("Request body is too large");
  }

  if (!request.body) {
    throw new SyntaxError("Request body is required");
  }

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let totalBytes = 0;

  while (true) {
    const { done, value } = await reader.read();
    if (done) {
      break;
    }
    totalBytes += value.byteLength;
    if (totalBytes > maxBytes) {
      await reader.cancel();
      throw new RangeError("Request body is too large");
    }
    chunks.push(value);
  }

  const bytes = new Uint8Array(totalBytes);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }

  return JSON.parse(new TextDecoder().decode(bytes)) as unknown;
}

function createServer(env: Env, workosUserId: string): McpServer {
  const server = new McpServer(
    { name: "nutridrop", version: "0.1.0" },
    {
      instructions:
        "Record only explicit nutrition quantities supplied or confirmed by the user. Do not estimate missing nutrition values.",
    },
  );

  server.registerTool(
    "record_nutrition",
    {
      title: "Record nutrition",
      description:
        "Record explicit nutrient quantities for later synchronization to the user's iPhone and Apple Health. Do not use this tool to estimate nutrition.",
      inputSchema: nutritionInputSchema,
      outputSchema: nutritionOutputSchema,
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        openWorldHint: false,
      },
    },
    async (input) => {
      try {
        const validatedInput = nutritionInputSchema.parse(input);
        const recordId = await recordNutrition(env.DB, workosUserId, validatedInput);
        const notificationStatus = await notifyDevice(env, workosUserId, recordId);
        const structuredContent = { recordId, status: "accepted" as const, notificationStatus };
        return {
          structuredContent,
          content: [
            {
              type: "text",
              text: `Nutrition was saved. Push submission: ${notificationStatus}. This does not confirm device receipt or an Apple Health write.`,
            },
          ],
        };
      } catch (error) {
        console.error(
          JSON.stringify({
            message: "nutrition record failed",
            errorType: error instanceof Error ? error.name : "UnknownError",
          }),
        );
        return {
          isError: true,
          content: [{ type: "text", text: "Nutrition could not be recorded." }],
        };
      }
    },
  );

  return server;
}

type NutridropWorker = {
  fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response>;
};

export function createWorker(verifyToken: TokenVerifier): NutridropWorker {
  return {
    async fetch(request, env, ctx): Promise<Response> {
      const url = new URL(request.url);

      if (
        request.method === "GET" &&
        url.pathname === "/.well-known/oauth-protected-resource"
      ) {
        return protectedResourceMetadata(env);
      }

      if (!["/mcp", "/v1/session", "/v1/push-token"].includes(url.pathname)) {
        return Response.json({ error: "not_found" }, { status: 404 });
      }

      if (url.pathname === "/v1/session" && request.method !== "GET") {
        return new Response(null, { status: 405, headers: { Allow: "GET" } });
      }

      if (url.pathname === "/v1/push-token" && !["PUT", "DELETE"].includes(request.method)) {
        return new Response(null, { status: 405, headers: { Allow: "PUT, DELETE" } });
      }

      const user = await verifyToken(request, env);
      if (!user) {
        return unauthorized(env);
      }

      if (url.pathname === "/v1/session") {
        return Response.json(
          { userId: user.userId },
          { headers: { "Cache-Control": "no-store" } },
        );
      }

      if (url.pathname === "/v1/push-token") {
        const headers = { "Cache-Control": "no-store" };
        if (request.headers.get("Content-Type")?.split(";")[0].trim().toLowerCase() !== "application/json") {
          return Response.json({ error: "unsupported_media_type" }, { status: 415, headers });
        }
        let input: z.infer<typeof pushTokenSchema>;
        try {
          input = pushTokenSchema.parse(await parseJsonBody(request, 4096));
        } catch (error) {
          return Response.json({ error: error instanceof RangeError ? "request_too_large" : "invalid_request" },
            { status: error instanceof RangeError ? 413 : 400, headers });
        }
        try {
          if (request.method === "DELETE") {
            await env.DB.prepare("DELETE FROM push_tokens WHERE workos_user_id = ? AND token = ? AND environment = ?")
              .bind(user.userId, input.token, input.environment).run();
          } else {
            // A token belongs to one signed-in account; one destination per user.
            await env.DB.batch([
              env.DB.prepare("DELETE FROM push_tokens WHERE token = ? AND environment = ? AND workos_user_id != ?")
                .bind(input.token, input.environment, user.userId),
              env.DB.prepare(`INSERT INTO push_tokens (workos_user_id, token, environment, updated_at)
                VALUES (?, ?, ?, ?) ON CONFLICT(workos_user_id) DO UPDATE SET
                token = excluded.token, environment = excluded.environment, updated_at = excluded.updated_at`)
                .bind(user.userId, input.token, input.environment, new Date().toISOString()),
            ]);
          }
          return new Response(null, { status: 204, headers });
        } catch {
          console.error(JSON.stringify({ message: "push token storage failed" }));
          return Response.json({ error: "storage_failed" }, { status: 500, headers });
        }
      }

      try {
        const parsedBody = request.method === "POST" ? await parseJsonBody(request, MAX_MCP_BODY_BYTES) : undefined;
        const handler = createMcpHandler(() => createServer(env, user.userId), {
          route: "/mcp",
        });
        return await handler.fetch(request, { parsedBody });
      } catch (error) {
        const tooLarge = error instanceof RangeError;
        console.error(
          JSON.stringify({
            message: tooLarge ? "mcp request rejected" : "mcp request failed",
            path: url.pathname,
            error: error instanceof Error ? error.message : "Unknown error",
          }),
        );
        return Response.json(
          { error: tooLarge ? "request_too_large" : "invalid_request" },
          { status: tooLarge ? 413 : 400 },
        );
      }
    },
  };
}

export default createWorker(verifyAccessToken) satisfies ExportedHandler<Env>;
