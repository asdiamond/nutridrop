import { createRemoteJWKSet, jwtVerify, type JWTPayload } from "jose";

export type AuthenticatedUser = {
  subject: string;
  clientId: string;
  scopes: string[];
  token: string;
  expiresAt?: number;
};

export type TokenVerifier = (
  request: Request,
  env: Env,
) => Promise<AuthenticatedUser | null>;

function bearerToken(request: Request): string | null {
  const authorization = request.headers.get("Authorization");
  const match = authorization?.match(/^Bearer ([^\s]+)$/);
  return match?.[1] ?? null;
}

function tokenScopes(payload: JWTPayload): string[] {
  if (typeof payload.scope !== "string") {
    return [];
  }
  return payload.scope.split(" ").filter(Boolean);
}

export const verifyWorkOSToken: TokenVerifier = async (request, env) => {
  const token = bearerToken(request);
  if (!token) {
    return null;
  }

  try {
    const issuer = env.WORKOS_ISSUER.replace(/\/$/, "");
    const jwks = createRemoteJWKSet(new URL(`${issuer}/oauth2/jwks`));
    const { payload } = await jwtVerify(token, jwks, {
      issuer,
      audience: env.MCP_RESOURCE,
    });

    const scopes = tokenScopes(payload);
    if (!payload.sub || !scopes.includes("openid")) {
      return null;
    }

    return {
      subject: payload.sub,
      clientId: typeof payload.client_id === "string" ? payload.client_id : "unknown",
      scopes,
      token,
      expiresAt: payload.exp,
    };
  } catch {
    return null;
  }
};
