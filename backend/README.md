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

After `record_nutrition` persists a record, it publishes `{ userId, recordId }`
to `NOTIFICATIONS`. `notificationStatus` reports `queued` or `enqueue_failed`;
neither means APNs accepted a push or the phone received it. The same Worker
consumes the queue and sends the silent push using the user's current destination.
The consumer logs its outcome and acknowledges accepted pushes, missing/mismatched
destinations, unregistered tokens, and permanent request rejections. Network,
signing, provider-auth, rate-limit, and server failures retry up to five times
at 60-second intervals. Messages are discarded after retry exhaustion; no
dead-letter queue is configured. Duplicate delivery can cause duplicate wake-up
hints; iOS already merges nutrition by record ID.

There is intentionally no outbox. A crash or publish failure after the D1 write
can leave a saved record without notification work. Publish failures return
`status: accepted` with `notificationStatus: enqueue_failed` and log the record
ID. Do not repeat the nutrition call just to retry notification: ingestion is
append-only. A later delivered push can recover the record through pending sync.
APNs accepting but not delivering a push is not detectable by this queue.

Staging queue: `nutridrop-notifications-staging`. Create it with
`npx wrangler queues create nutridrop-notifications-staging` before first deploy.
The local queue is emulated by Wrangler. No iOS update is needed for this change.

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
