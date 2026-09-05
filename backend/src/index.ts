import { McpServer } from "@modelcontextprotocol/server";
import { createMcpHandler } from "agents/mcp/server";
import { verifyAccessToken, type TokenVerifier } from "./auth";
import {
  nutritionInputSchema,
  nutritionOutputSchema,
  recordNutrition,
} from "./nutrition";

const MAX_MCP_BODY_BYTES = 64 * 1024;

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

async function parseMcpBody(request: Request): Promise<unknown> {
  const contentLength = request.headers.get("Content-Length");
  if (contentLength && Number(contentLength) > MAX_MCP_BODY_BYTES) {
    throw new RangeError("MCP request body is too large");
  }

  if (!request.body) {
    throw new SyntaxError("MCP request body is required");
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
    if (totalBytes > MAX_MCP_BODY_BYTES) {
      await reader.cancel();
      throw new RangeError("MCP request body is too large");
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
        const structuredContent = { recordId, status: "accepted" as const };
        return {
          structuredContent,
          content: [
            {
              type: "text",
              text: "Nutrition was recorded and will be available for iPhone sync.",
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

      if (url.pathname !== "/mcp" && url.pathname !== "/v1/session") {
        return Response.json({ error: "not_found" }, { status: 404 });
      }

      if (url.pathname === "/v1/session" && request.method !== "GET") {
        return new Response(null, { status: 405, headers: { Allow: "GET" } });
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

      try {
        const parsedBody = request.method === "POST" ? await parseMcpBody(request) : undefined;
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
