# Nutridrop MCP

Cloudflare Worker exposing the authenticated `record_nutrition` MCP tool and
persisting accepted nutrition records to D1.

`GET /v1/session` returns `{ "userId": "user_..." }`. Both routes use the same
WorkOS Connect verifier, issuer, resource audience, and `openid` scope. iOS uses
a public Connect client with PKCE; MCP clients discover the authorization server
through `/.well-known/oauth-protected-resource`. AuthKit session tokens are not
accepted. Tokens and nutrition values must never be logged.

## Development

```sh
npm install
npm run types
npm run migrate:local
npm test
npm run dev
```

The MCP endpoint is `http://localhost:8787/mcp`. Configure MCP Inspector with a
valid WorkOS access token whose audience is that exact resource URL.

## Staging

Staging uses the WorkOS sandbox issuer and the
`nutridrop-mcp-staging.diamondaleksandr.workers.dev` Worker. Its `/mcp` URL is
configured as the default WorkOS resource indicator.

```sh
npm run migrate:staging
npm run deploy:staging
```

The Worker stores explicit quantities only. An accepted result means the data
was persisted for future iPhone sync; it does not mean Apple Health was updated.
