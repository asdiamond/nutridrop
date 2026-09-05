# Nutridrop MCP

Cloudflare Worker exposing the authenticated `record_nutrition` MCP tool and
persisting accepted nutrition records to D1.

`GET /v1/session` returns `{ "userId": "user_..." }`. Both routes use the same
WorkOS Connect verifier, issuer, resource audience, and `openid` scope. iOS uses
a public Connect client with PKCE; MCP clients discover the authorization server
through `/.well-known/oauth-protected-resource`. AuthKit session tokens are not
accepted. Tokens and nutrition values must never be logged.

`GET /v1/nutrition/pending` returns `{ records, nextCursor }`, with at most 50
records per page. Pass `nextCursor` as the URL-encoded `cursor` query parameter
until it is null. Records contain `id`, `consumedAt`, `mealLabel`, `quantities`,
`schemaVersion`, and `createdAt`; ordering is by `(created_at, id)`. Every query
is scoped to the verified user, including requests with a supplied cursor.
Responses are non-cacheable. All records remain pending until HealthKit
acknowledgements are implemented; GET never consumes or deletes records.

`PUT /v1/push-token` accepts `{ "token": "<hex>", "environment": "sandbox" }`
(or `production`) and returns 204. It stores one destination per authenticated
user; a later registration replaces it. The same token cannot belong to two
users in one APNs environment. `DELETE` accepts the same body and removes only
the caller's matching destination, making stale-device sign-out safe. Run the
`0004` migration before deployment.

After `record_nutrition` persists a record, it directly submits one silent push
containing only `record_id`. `notificationStatus` reports `accepted_by_apns`,
`not_registered`, `environment_mismatch`, or `failed`. APNs acceptance is not
device receipt. A failed push never turns a successful database write into a
failed tool call. There is no notification queue or application-level retry.

APNs uses `APNS_PRIVATE_KEY` as a Worker secret, with public key ID, team ID,
topic, and supported environment in Wrangler config. The current key is configured
for sandbox only; production registrations are not sent with it. Local tests use
generated keys; never commit `.p8` keys or add the real key to test fixtures.

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
