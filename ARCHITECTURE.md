# Nutridrop Architecture

## Scope

The MVP accepts explicit nutrition quantities from a ChatGPT app, stores them
in the Nutridrop backend, and syncs them to Apple Health through a companion
iOS app.

The MVP is append-only. It does not infer nutrition values, edit existing
records, delete HealthKit samples, or provide a browser dashboard.

## Repository Layout

```text
nutridrop/
├── ios/                 # SwiftUI iOS app (iOS 18 deployment target)
├── web/                 # Cloudflare Worker API, D1 schema, and queue consumer
├── chatgpt-plugin/      # MCP server exposed as a ChatGPT app
├── ARCHITECTURE.md
└── README.md
```

`web/` and `chatgpt-plugin/` are separate deployable Workers. The MCP Worker
calls the API Worker through a Cloudflare service binding rather than public
HTTP. The iOS app uses the API Worker's public HTTPS endpoints.

## Components

### ChatGPT App

The ChatGPT app is an MCP server using Streamable HTTP. It exposes one initial
tool:

```text
record_nutrition
```

The tool requires OAuth and accepts:

- An optional user-facing meal label.
- A client-generated UUID that remains stable if ChatGPT retries the same tool
  call.
- The time the nutrition was consumed, including its UTC offset.
- One or more explicit nutrient quantities.
- A stable nutrient identifier, numeric value, and unit for each quantity.

The tool only accepts supported HealthKit nutrition quantity types. It does
not accept a food description in place of quantities and does not estimate
missing values. Its result says that the record was accepted for device sync;
it must not claim that Apple Health was updated yet.

The MCP Worker validates the Auth0 access token, validates and normalizes the
tool input (including the client record UUID), and calls the API Worker through
a service binding.

### Cloudflare Backend

The backend consists of:

- A Cloudflare Worker for authenticated iOS and internal MCP APIs.
- D1 for users, devices, nutrition records, quantities, and delivery state.
- Cloudflare Queues for asynchronous APNs delivery attempts.
- A queue consumer in the API Worker that sends background notifications to
  Apple Push Notification service (APNs).
- A scheduled reconciliation handler that retries notification enqueueing for
  pending records. This closes the gap if a record is committed to D1 but its
  initial queue publish fails.

The record is committed to D1 before the MCP call returns. Publishing to the
queue is awaited on the normal path, but D1 remains the source of truth. A
notification failure never loses a nutrition record.

### iOS App

The iOS app is a SwiftUI app built with the current Xcode SDK and an iOS 18
deployment target. It:

- Signs in with Auth0 using Authorization Code with PKCE.
- Requests HealthKit write access only for supported nutrition types.
- Registers for remote notifications and sends its APNs device token and
  environment to the backend.
- Becomes the account's active writer device. The MVP permits one active writer
  device per account to avoid duplicate samples when Apple Health synchronizes
  across multiple iPhones.
- Fetches pending records after a background notification.
- Also fetches pending records at launch, after login, and whenever the app
  returns to the foreground.
- Writes each quantity to HealthKit and acknowledges successful records to the
  backend.
- Displays local sync status and actionable authorization or write errors.

HealthKit permission prompts must occur while the app is in the foreground.
The app cannot grant or repair HealthKit authorization from a background push.

## End-to-End Flow

1. The user links Nutridrop to ChatGPT using Auth0 OAuth 2.1.
2. ChatGPT calls `record_nutrition` with explicit quantities.
3. The MCP Worker validates the access token, scope, schema, values, and units.
4. The MCP Worker invokes the API Worker over a service binding.
5. The API Worker inserts the nutrition record, its quantities, and pending
   quantity deliveries for the active writer device in D1 in one transaction.
6. The API Worker publishes a lightweight notification job to Cloudflare
   Queues and returns an `accepted` result with the record ID.
7. The queue consumer sends a silent APNs background notification to each
   active device belonging to the user.
8. iOS wakes when the system permits it and requests pending records from the
   API. The push payload is only a wake-up hint and contains no health data.
9. iOS writes the quantities to HealthKit and acknowledges each quantity that
   was saved, blocked by authorization, or failed.
10. The API updates those quantity deliveries and derives the record's overall
    sync status.

If APNs is delayed, throttled, discarded, or the app was force-quit, steps 8-10
run the next time the user opens or foregrounds the app.

## Delivery Semantics

Silent APNs notifications are best-effort. Apple does not guarantee delivery,
may throttle frequent background notifications, and provides limited
background execution time. Nutridrop therefore uses pull-based synchronization
with push as an optimization, not as the source of truth.

Delivery is at-least-once. Every layer must be idempotent:

- The tool input has a client record UUID so retries return the existing
  record. A separate invocation for an intentionally identical meal uses a new
  UUID.
- D1 enforces uniqueness for that user and client record UUID.
- The iOS app records which backend quantity IDs it has processed.
- HealthKit samples use the backend quantity ID as their sync identifier and a
  fixed initial sync version.
- Backend acknowledgements can be safely repeated.

HealthKit authorization is granted per nutrient type. Tracking each quantity
separately allows permitted nutrients to sync once while denied nutrients are
marked blocked instead of causing the whole meal to retry. Transient failures
remain pending and are retried without resaving acknowledged quantities.

## Data Model

### `users`

- `id`: internal UUID
- `auth0_subject`: unique Auth0 subject
- `created_at`

### `devices`

- `id`: internal UUID
- `user_id`
- `apns_token`: encrypted or otherwise access-restricted device token
- `apns_environment`: `development` or `production`
- `is_active_writer`: at most one active writer device per user in the MVP
- `last_seen_at`
- `disabled_at`: set when APNs reports that the token is no longer valid

### `nutrition_records`

- `id`: UUID generated by the backend
- `user_id`
- `client_record_id`: UUID supplied by the tool; unique per user
- `consumed_at`: UTC instant
- `consumed_utc_offset_minutes`: preserves the submitted local context
- `meal_label`: optional text
- `source`: `chatgpt`
- `created_at`

### `nutrition_quantities`

- `id`: stable UUID used as the HealthKit sync identifier
- `record_id`
- `nutrient_type`: canonical HealthKit-aligned identifier
- `value`: finite positive numeric value
- `unit`: canonical unit valid for the nutrient type

The nutrient representation is platform-neutral. Each identifier has a
server-side allowlist of valid units and ranges. The iOS app owns the final
mapping to `HKQuantityType` and `HKUnit`. Unsupported or unavailable types are
reported instead of silently dropped. A record contains at most one quantity
for each nutrient type.

### `quantity_deliveries`

- `quantity_id`
- `device_id`
- `status`: `pending`, `synced`, `blocked`, or `failed`
- `attempt_count`
- `last_error_code`: sanitized machine-readable error
- `synced_at`
- `updated_at`

The primary key is `(quantity_id, device_id)`. `blocked` represents a condition
requiring user action, such as denied HealthKit write access. It remains
visible to the iOS app but should not be retried continuously in the
background. A record is synced when every quantity is synced, and partially
blocked when at least one quantity is blocked.

## Interfaces

### MCP

`record_nutrition` requires the `nutrition:write` OAuth scope. Its structured
result contains:

- `recordId`
- `status: "accepted"`
- A short message explaining that the iPhone will sync when available

The tool is mutating, non-destructive, and closed-world. Tool annotations must
not mark it read-only.

### iOS API

```text
PUT  /v1/devices/current       Register or refresh an APNs token
GET  /v1/nutrition/pending     Fetch pending records for this device
POST /v1/nutrition/ack         Acknowledge synced, blocked, or failed records
```

All endpoints require an Auth0 access token with the expected issuer,
audience, expiry, and scopes. The backend derives the user from the token and
never accepts a user ID from the client.

Pending-record responses are bounded and cursor-paginated. Acknowledgements
include the device ID, quantity ID, result, and sanitized error code. The API
rejects acknowledgements for devices, quantities, or records that do not
belong to the authenticated user.

### Internal MCP API

```text
POST /internal/v1/nutrition
```

This route is reachable through a Worker service binding. It receives the
already-validated Auth0 subject plus normalized nutrition input, but the API
Worker still validates the payload and enforces idempotency.

## Authentication And Authorization

Auth0 is the shared identity provider:

- ChatGPT uses OAuth 2.1 Authorization Code with PKCE and MCP protected
  resource metadata.
- The native iOS application uses Auth0 Universal Login with PKCE.
- Auth0 access tokens target the Nutridrop API audience.
- The MCP tool requires `nutrition:write`.
- iOS device and sync routes use dedicated device/sync scopes.

The MCP server publishes OAuth protected-resource metadata and returns the
required authentication challenge for unauthenticated tool calls. Both Workers
validate signatures through Auth0 JWKS and enforce issuer, audience, expiry,
and scopes on every request.

No custom browser UI is required for the MVP. Auth0 hosts login and consent.
Public static endpoints needed for ChatGPT review, privacy policy, terms, and
support can be plain documents rather than an application frontend.

## Privacy And Security

- Nutrition values are health-related data and are never included in APNs
  payloads, logs, analytics events, or error messages.
- Worker logs use record IDs and machine-readable status codes only.
- Access tokens and APNs signing keys are stored as Worker secrets, never in
  source control or D1.
- D1 queries are always scoped to the authenticated user.
- Tool and API inputs use strict schemas, bounded arrays, finite positive
  numeric values, an allowlist of nutrient identifiers, and per-type units.
- The iOS app requests write-only HealthKit access unless a later feature has
  a concrete need to read health data.
- The backend retains its copy until a documented retention/deletion policy is
  implemented before production release.

## APNs Configuration

The APNs request uses token-based authentication and the app's bundle ID as
the topic. Background pushes use:

```text
apns-push-type: background
apns-priority: 5
aps.content-available: 1
```

The payload contains only a generic sync hint. Queue retries handle transient
APNs errors. Permanent token errors disable the device token. Notification jobs
may be coalesced per user or device because the iOS app always fetches all
pending records.

## Initial Deployment Units

1. `nutridrop-api`: public iOS API, internal MCP service endpoint, D1 access,
   queue producer/consumer, and scheduled reconciliation.
2. `nutridrop-chatgpt`: public MCP endpoint and Auth0 resource metadata; calls
   `nutridrop-api` through a service binding.
3. `nutridrop-notifications`: Cloudflare Queue bound to `nutridrop-api` as
   producer and consumer.
4. `nutridrop-db`: D1 database owned by `nutridrop-api`.
5. Auth0 tenant resources: API audience, native iOS application, and MCP OAuth
   client configuration compatible with ChatGPT.

## Deferred Work

- Nutrition estimation from natural-language food descriptions.
- Editing, deletion, and HealthKit sample replacement.
- Browser history/dashboard.
- Reading nutrition data back from HealthKit.
- Multiple source integrations beyond ChatGPT.
- User-facing controls for retention, export, and account deletion. These are
  required before a public production launch even though they are outside the
  first technical slice.

## Implementation Order

1. Define the shared nutrient contract and D1 migrations in `web/`.
2. Implement and test record creation, pending fetch, and acknowledgement in
   the API Worker.
3. Implement the MCP tool against the API service binding with Auth0.
4. Build the iOS Auth0, HealthKit, local idempotency, and foreground sync path.
5. Add APNs device registration, queue consumption, and background sync.
6. Add reconciliation, observability, privacy documents, and end-to-end tests.
