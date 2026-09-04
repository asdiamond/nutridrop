# Nutridrop MCP

Cloudflare Worker exposing the authenticated `record_nutrition` MCP tool and
persisting accepted nutrition records to D1.

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
