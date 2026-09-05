import { createRemoteJWKSet, jwtVerify } from "jose";

export type TokenVerifier = (
  request: Request,
  env: Env,
) => Promise<{ userId: string } | null>;

export const verifyAccessToken: TokenVerifier = async (request, env) => {
  const token = request.headers.get("Authorization")?.match(/^Bearer ([^\s]+)$/i)?.[1];
  if (!token) return null;

  try {
    const issuer = env.WORKOS_ISSUER.replace(/\/$/, "");
    const jwks = createRemoteJWKSet(new URL(`${issuer}/oauth2/jwks`));
    const { payload } = await jwtVerify(token, jwks, {
      issuer,
      audience: env.MCP_RESOURCE,
      algorithms: ["RS256"],
      requiredClaims: ["sub", "exp", "iat"],
    });
    if (
      !payload.sub?.startsWith("user_") ||
      typeof payload.scope !== "string" ||
      !payload.scope.split(" ").includes("openid")
    ) return null;

    return { userId: payload.sub };
  } catch {
    return null;
  }
};
