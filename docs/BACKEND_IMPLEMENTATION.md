# Backend implementation and operation

Deployment: 2026-09-13, Supabase project `wjjabfihijpilgimdhzp` (Waste Management Platform).

The backend is deployed with live bookings **disabled**. The database contains no transport tariffs, verified East Legon boundary, verified warehouse entrance, staff accounts or customer orders. Coliba's supplied coordinates remain approximate reference data. Biodegradable remains unavailable. No real mobile-money payment or Google route has been tested.

## Delivered

| Component | Behavior |
| --- | --- |
| Eight migrations | Private `wm` schema, PostGIS, RLS on every application table, explicit RPC grants, verified-user checks, indexed relationships and staff roles that clients cannot grant themselves. See [health review](BACKEND_HEALTH_REVIEW.md). |
| App enrollment and driver signup | Separate client enrollment and driver applications, private license/photo/insurance/roadworthiness uploads, optional Ghana Card, firm review and expiry gates. See [onboarding API](DRIVER_ONBOARDING.md). |
| Quotes | Server-only Google route finalization; versioned tariff snapshot; expiry; no invented rates; transport is client-to-warehouse. |
| Client booking | Quote ownership, single-use quotes, idempotency, address/pin, searching cancellation, controlled replacement after failed visit, order history and scoped tracking. |
| Driver | Firm provisioning, availability, sequenced GPS, load status, expiring private offers, decline before acceptance, atomic acceptance and state transitions. No voluntary refusal after acceptance. |
| Dispatch | Five geographically nearest eligible candidates, ranked by Google traffic-aware road duration. Full/unknown trucks and drivers with an active client visit are excluded. Existing visits are never displaced by incident reports. |
| Pickup and waiting | Server-recorded arrival requires fresh nearby GPS; five free minutes, then 90 pesewas/minute; waiting stops at `driver.start_loading`. Loading/payment add no waiting fees. |
| Evidence | Reserved upload paths in private `wm-evidence` bucket, 10 MB image limit, uploader checks, finalize-after-upload and no app overwrite/delete permission. Pickup collection requires driver evidence. |
| Cash | Driver attests the exact amount received from the requesting client. Payment state, collection state and warehouse receipt remain separate. Normal departure requires payment. Cash remittance is a separate firm record. |
| Receiver | Minimal preview/confirm APIs, warehouse membership, no driver self-confirmation, expiring random QR secret stored only as a hash, single use, one client's pickup per QR. Partial/rejected receipt creates unresolved custody. |
| Exceptions | Stale versions, duplicate commands, expired quotes/offers/QRs, stale GPS, unauthorized access, unavailable services, missing photos, payment mismatch, unresolved custody and failed visits reject unsafe transitions. Firm resolutions require a recorded reason. |
| Worker | Leased dispatch queue, expired-offer sweep, retries with backoff, dead-letter visibility and operator retry. Hosted Cron checks every 30 seconds; no external call while bookings are disabled or no work is due. |
| Flutter | `lib/backend/waste_backend.dart` API wrapper, persisted command-key support and application errors. Existing app screen remains a placeholder. |

The first implementation uses a configurable linear transport model:

`transport_pesewas = max(minimum, round(kilometres × per_km_minor + traffic_aware_travel_minutes × per_travel_minute_minor))`

The formula is an implementation choice, not an approved tariff. The booking fee is 100 pesewas; waiting is added separately. Quote transport is locked until expiry and is not recomputed from driver approach distance. `waiting_rounding` must explicitly be configured as `pro_rata` or `ceil_minute`; no live rounding choice was made for the owner.

## API contract

Use Supabase Auth to sign in first. An account needs verified email or phone. Sign-up creates only a basic profile; UI role selections and user metadata do not grant staff privileges. The mobile app must use its publishable key and the signed-in user's access token. Keep service keys and the worker secret off devices.

Read RPCs: `wm_catalog` (public), `wm_list_orders`, `wm_get_order`, `wm_tracking`, `wm_my_offers`, `wm_preview_handoff`, `wm_driver_destination` and `wm_operator_overview` (operator only).

All user mutations go through:

```json
{
  "p_action": "driver.travel",
  "p_payload": {"order_id": "ORDER_UUID", "version": 2},
  "p_command_key": "NEW_UUID_FOR_THIS_INTENT"
}
```

Call RPC `wm_command`. Persist the command before submitting it; reuse its exact key and payload after a timeout. A changed payload with the same key fails. Refresh order state on `VERSION_CONFLICT`; do not silently repeat a changed action. A replayed `handoff.issue` intentionally returns `refresh_required` without the token; issue a fresh command to rotate the QR. Do not log QR tokens or add them to URLs.

| Action | Payload in addition to order ID/version where specified |
| --- | --- |
| `profile.update` | `display_name` |
| `booking.submit` | `quote_id`, `address`, optional `access_note`, optional `replacement_of`; no order ID/version |
| `booking.cancel` | Order ID/version; client, searching only |
| `driver.availability` | `online` boolean; no order ID/version |
| `driver.location` | `latitude`, `longitude`, `accuracy_m`, UTC `measured_at`, increasing integer `sequence`; no order ID/version |
| `driver.load` | `load_state`: `full`, `nearly_full`, `unknown`; only firm reconciliation can reset to `available` |
| `offer.accept`, `offer.decline` | `offer_id`; no order ID/version |
| `driver.travel`, `driver.arrive`, `driver.start_loading`, `driver.collect`, `driver.depart` | Order ID/version |
| `evidence.reserve` | Order ID/version, `purpose`: `pickup` or `incident`; returns bucket/path/evidence ID |
| `evidence.finalize` | `evidence_id` after Storage upload; no order ID/version |
| `payment.cash` | Order ID/version, exact `amount_minor`; assigned driver attestation |
| `payment.mobile_money` | Order ID/version, `network`: `mtn_momo` or `telecel_cash`; returns `PAYMENT_PROVIDER_NOT_CONFIGURED` |
| `handoff.issue` | Order ID/version; collected and departed, custody still outstanding |
| `handoff.confirm` | `token`, `outcome`: `confirmed`, `partial`, `rejected`; reason for non-confirmation; receiver only |
| `incident.report` | `kind`, `details`, optional order ID/version |

Upload evidence to the returned path with `upsert: false`. Database tests exercise Storage metadata and policies; actual image bytes still require an Android/Storage integration test. Retrieve private images using the authenticated Storage API. Do not make the bucket public.

`warehouse_confirmed_at != null` indicates final completion; `state=collected` alone does not. `total_minor` is available after waiting stops. Driver access to failed/cancelled attempts is revoked. Clients cannot inspect other clients' orders. Offers expose only a coarse area/category before acceptance. Receiver previews omit client address and contact data.

Edge Functions:

- `wm-quote`: authenticated POST `{category, latitude, longitude}`; serviceability check, Google Routes request and server-finalized quote.
- `wm-dispatch`: operator POST `{order_id}`; immediate road-ETA-based offer.
- `wm-worker`: private scheduled worker, authenticated with `WM_WORKER_SECRET`. It processes dispatch events only; it does **not** claim push notifications were delivered.

Both user endpoints have gateway `verify_jwt` enabled and independently validate bearer tokens against Supabase Auth before calling business RPCs. Database permissions apply again. The worker intentionally has gateway JWT verification disabled because its scheduled caller uses a dedicated secret, which the handler verifies before obtaining service access.

## Configure and activate deliberately

1. Add `GOOGLE_MAPS_SERVER_KEY=...` to the ignored **`.env.server`** file locally. Enable Routes API/billing and restrict this server key to its required API. Do not paste it into chat or `.env` used by Flutter. `tool/configure-worker.ps1` generates/preserves the worker secret, configures hosted function secrets and stores scheduler credentials in Supabase Vault. It never turns bookings on.
2. Create a real, verified firm operator account through the selected Auth flow. From a trusted server using the service role, call `wm_bootstrap_operator(p_user_id)`. This privileged bootstrap is not a client operation. No staff accounts or passwords were fabricated during deployment.
3. As that operator, use `wm_command` with `operator.*` actions below. Configure actual boundary, receiver entrance, operational rules and approved tariffs. The approximate Coliba pin must be verified in the field before being entered as the entrance.
4. Provision employee drivers and warehouse receivers using their existing verified Auth user IDs. Configure the firm's approved vehicles. Validate the agreed cash procedure and receiver handoff using a controlled field test.
5. Select and connect a real MTN/Telecel merchant integration before enabling mobile-money checkout in the app. The current endpoint deliberately cannot create a charge. Signing, callbacks, reconciliation and refunds require that provider's contract and credentials.
6. Review the open release items below. Enable non-biodegradable and `bookings_enabled` only when operationally ready; bookings should stay disabled during configuration/testing. Biodegradable cannot be enabled through the initial release's operator API.

Operator commands require a `reason` of at least three characters:

| Action | Configuration / purpose |
| --- | --- |
| `operator.settings` | `bookings_enabled`, `quote_ttl_seconds`, `offer_ttl_seconds`, `location_max_age_seconds`, `arrival_radius_m`, `waiting_rounding`, `qr_ttl_seconds` |
| `operator.area` | `geojson` Polygon/MultiPolygon for the agreed East Legon boundary |
| `operator.warehouse` | Existing `warehouse_id`, verified `latitude`/`longitude`, `entrance_verified`, `receiving_enabled`, `receiving_hours`, `material_restrictions` |
| `operator.tariff` | `category`, unique `tariff_version`, `per_km_minor`, `per_travel_minute_minor`, optional `min_transport_minor`; values in pesewas |
| `operator.category` | `category=non_biodegradable`, `enabled` |
| `operator.driver` | Existing `user_id`, `plate`; requires approved/current driver application and matching vehicle documents before granting employee-driver permission and vehicle association |
| `operator.receiver` | Existing `user_id`, `warehouse_id`; scoped receiving permission |
| `operator.suspend` | `user_id`; revokes active access and opens an incident without silently dropping custody |
| `operator.fail_visit` | Order ID/version, before loading/custody; closes old attempt so client can explicitly rebook |
| `operator.departure_override` | Order ID/version; documented safety exception, not payment confirmation |
| `operator.adjust_waiting` | Order ID/version and reduced `waiting_minor`; only before payment/departure |
| `operator.load_reset` | `driver_id`; blocked until every outstanding pickup is warehouse-confirmed |
| `operator.resolve_incident` | `incident_id`; records the resolution; does not itself confirm residual waste |
| `operator.cash_remittance` | `payment_id`, firm `reference` |
| `operator.retry_dispatch` | Searching order ID/version; retries failed dispatch work, preserving previous driver declines |

## Development and deployment commands

Node tooling is isolated under `tool/backend`; it is not part of the Android app. Docker is unnecessary for the included PGlite/PostGIS domain tests and API-based Edge deployments.

```powershell
npm ci --prefix tool/backend
npm test --prefix tool/backend
& ./tool/backend/node_modules/.bin/deno.cmd task --config supabase/functions/deno.json check
& ./tool/backend/node_modules/.bin/deno.cmd task --config supabase/functions/deno.json test
flutter analyze
flutter test

& ./tool/backend/node_modules/.bin/supabase.cmd login
& ./tool/backend/node_modules/.bin/supabase.cmd link --project-ref wjjabfihijpilgimdhzp
& ./tool/backend/node_modules/.bin/supabase.cmd db push --linked --dry-run
& ./tool/backend/node_modules/.bin/supabase.cmd db push --linked
& ./tool/backend/node_modules/.bin/supabase.cmd functions deploy wm-quote wm-dispatch wm-worker --use-api
& ./tool/configure-worker.ps1
node tool/backend/check-hosted.mjs
```

`tool/backend/hosted-smoke.sql` exercises the real hosted Postgres/PostGIS lifecycle in a transaction and rolls back all synthetic records. Run it only against this development project; it temporarily configures synthetic rates and writes Storage metadata within that transaction. It does not contact Google, collect money or store actual images.

```powershell
& ./tool/backend/node_modules/.bin/supabase.cmd db query --linked --file tool/backend/hosted-smoke.sql
```

Check `wm_operator_overview` for unresolved incidents, custody, queue size and failed dispatch records. A Google failure never becomes a fabricated route or price. Five worker failures result in a dead dispatch event for firm review. Previous declines/expired offers are not endlessly offered back to the same driver. The five-candidate shortlist and 30-second scheduler interval are initial engineering settings that need fleet/load testing.

## Validation evidence and remaining release work

- 19 database/status test results passed, including real PostGIS migrations and role/lifecycle/onboarding subtests. Checks cover zero-rate defaults, privilege escalation, quote ownership, idempotency conflicts, full trucks, offer ownership, stale GPS/version, waiting calculation, private immutable evidence, payment gates, two pickups on one truck, QR expiry/replay/partial receipt, replacement access revocation, leases, suspension, required document approval/renewal, index coverage and provider-status failures.
- Hosted transactional lifecycle passed on this project's PostgreSQL 17; rollback verified zero users/orders/tariffs and bookings disabled afterward.
- Eight Deno authentication/contract tests passed; all three Edge entry points type-check. Google responses are mocked in those contract tests.
- Hosted public catalogue responds; anonymous protected RPC calls and absent/invalid user tokens are rejected; unauthorized worker invocation is rejected.
- Flutter analysis and three tests pass, including command persistence across an uncertain retry. Android device journeys, GPS spoofing resistance, image upload, push delivery and concurrent fleet load remain unverified.

This is an operational backend foundation, **not a claim that every row in the exception specification has shipped**. Remaining delivery dependencies and limitations:

- Google key/billing, approved tariffs, field-verified entrance, East Legon polygon, real staff accounts, receiving rules and a biodegradable partner are not supplied.
- MTN/Telecel merchant implementation, signed webhooks, reconciliation/refunds and payment field tests are pending provider selection/access.
- Android screens, phone/SMS sign-in configuration, background location, push/FCM credentials, durable device retry queues and the small receiver UI still need implementation/integration. Read RPCs support foreground refresh; no push-delivery promise is made by an outbox insert.
- Warehouse hours/material restrictions are descriptive configuration, with a firm-controlled receiving switch; there is no automatic holiday/capacity-hours engine or material classifier yet. Real receiving availability must be operated by the firm.
- Database locks/unique indexes protect acceptance and idempotency. The included tests are sequential and do not establish simultaneous multi-session race or production-load performance.
- Evidence retention/deletion, account deletion with retained financial records, automated failed-pickup SLA escalation, FCM delivery, refunds and abnormal mixed/unsafe waste logistics require the remaining policy/integration work. Existing handlers block unsafe transitions and preserve incidents/custody for firm resolution.

Technical references: [Supabase Auth validation](https://supabase.com/docs/reference/javascript/auth-getuser), [Google traffic-aware routes](https://developers.google.com/maps/documentation/routes/compute_route_directions), [Supabase Cron and Vault scheduling](https://supabase.com/docs/guides/functions/schedule-functions).
