# Frontend gap implementation and owner handoff

2026-09-15. The migration and `wm-eta` are deployed to the existing hosted development project. The Flutter screen remains the existing scaffold; these are backend contracts and Flutter adapters for the planned screens. Live bookings remain disabled.

## Implemented

| Gap | Delivery | Remaining limit |
| --- | --- | --- |
| Assigned-driver identity | `wm_order_presentation(order_id)` returns display name and assigned vehicle plate | No phone disclosure or sharing of the private onboarding photo. A public-facing photo/contact workflow remains engineering work after contact policy is chosen |
| Driver restoration | `wm_driver_status()` returns own online/load/vehicle, document eligibility, last GPS sequence and measurement time | Flutter screen/lifecycle wiring and multi-device location ownership remain work; `can_take_jobs` is account/document eligibility, not a dispatch guarantee |
| Outstanding work restoration | `wm_active_orders(app, before, before_id, limit)` returns own unfinished work, including older departed custody | Iterate pages until short/empty. Paired timestamp/ID cursor handles equal timestamps; client and driver scopes are explicit |
| Warehouse and payment presentation | Order presentation includes payment records and handoff outcomes/reasons, without tokens/hashes | Does not implement mobile money, refunds, or downloadable tax invoices |
| Staff route access | `wm_staff_access()` returns operator flag and own receiving warehouses | Staff screens still need construction; authorization remains enforced by each RPC |
| ETA | Authenticated `wm-eta` Edge endpoint uses current authorized approach coordinates and Google traffic-aware routing | Requires Google credentials/billing; not yet live-tested. On-demand only, no automatic paid polling. Add shared cache/rate limits before high-frequency production use |
| Missed foreground updates | `wm_updates(after_id, limit)` returns scoped event IDs, kinds and timestamps | Not FCM/push. Poll offers separately. Always refresh active-work state on resume; event ID is a deduplication cursor, not a complete transactional snapshot |

New migration: `supabase/migrations/20260915000100_frontend_reads.sql`. Flutter methods are in `lib/backend/waste_backend.dart`. No backend secrets or private driver-document paths are returned by these new presentation reads.

### ETA request

Authenticated POST to `wm-eta` with `{ "order_id": "<UUID>" }`. Returns distance in metres, estimated seconds, location measurement time, calculation time and source. It is an approach estimate, not a fare or an arrival promise. Access is checked before the provider call and again afterward; stale locations, changed order versions and provider failures do not produce invented fallback values.

### Validation

Validation completed:

- Full Node/PGlite suite: 20 passing tests/results. After the final foreground-feed addition, the affected lifecycle suite passed again (11 results), including feed privacy and pagination checks.
- Deno: 11 tests passed; all four Edge entry points type-check.
- Flutter: analysis passed; all three existing tests passed. These tests do not exercise new screens, which are not implemented yet.
- Hosted transactional pickup/payment/QR test passed, including the new driver restoration, identity, ETA context and receipt reads. Rollback verified zero Auth users/orders/tariffs and bookings disabled.
- Live HTTP checks reject anonymous/invalid tokens for the new reads and ETA endpoint. A synthetic signed-in account exercised allowed empty reads, denied driver/staff escalation and unauthorized ETA access; account/profile cleanup succeeded.
- Supabase's status feed reported an API Gateway incident during these successful application checks. This is a provider warning, not a failed migration or a claim that future requests cannot be affected.

No real Google route, SMS, mobile-money payment, push delivery or Android device journey was validated in this change.

## What you need to do personally

Do these in order; you do not need to write application code.

### 1. Google project and routing access

- Use a company-controlled Google Cloud project; enable billing and Routes API.
- Create a server credential restricted to the required API. Put it in the ignored `.env.server` file as `GOOGLE_MAPS_SERVER_KEY`; do not paste the value into chat or the Flutter `.env`.
- Tell me when the project/key is ready. I can configure deployment and test the integration afterward. Android map display needs a separate restricted client key when the two application IDs are finalized.

Reference: [Google Routes setup](https://developers.google.com/maps/documentation/routes/cloud-setup).

### 2. Decide pilot payment scope

- Confirm either **cash-first pilot** or **mobile money required before pilot**.
- For mobile money, obtain a company merchant account and API/sandbox access for a provider supporting both MTN MoMo and Telecel Cash, or the respective direct integrations.
- Supply the provider name, official API documentation, merchant approval status and sandbox-access availability. Keep credentials in a private local server configuration, not chat.
- I still need to implement the selected provider's initiation, status checks, signed callbacks and reconciliation. Credentials alone will not turn on payments.

### 3. Firebase ownership for notifications

- Create or nominate a company-controlled Firebase project and provide its project ID.
- Confirm final Client and Driver app names. I can set up their distinct Android IDs and register/configure apps once access is available; avoid registering the temporary `com.example.mohotew` ID as the final release app.
- Arrange server access to FCM through the project's authorized setup. Do not place a service-account private key in Flutter assets.
- I still need to implement device registration/refresh, delivery/retry handling, Android notification behavior and screen-off tests. The foreground update feed does not replace that work.

Reference: [Firebase Flutter messaging setup](https://firebase.google.com/docs/cloud-messaging/flutter/get-started).

### 4. Approve operational facts

- Provide approved transport rates and choose partial-minute waiting rounding. Rates remain open until you decide; no need to invent them just to continue interface development.
- Provide the agreed East Legon pickup boundary and field-verified warehouse vehicle entrance.
- Confirm warehouse receiving hours, accepted material restrictions and named receiver staff. Biodegradable remains unavailable until its receiving partner exists.
- Name the firm operator who reviews drivers and resolves incidents, and give the support contact/channel customers and drivers should use.
- Decide whether customer/driver contact uses ordinary phone calls, a masked-call provider, or firm-mediated contact.

### 5. Verification and field-test access

- Configure/approve the email and SMS provider accounts in Supabase as required and provide a real test phone/email you control for verification testing. An enabled signup flag is not proof of delivered SMS.
- Arrange an Android test phone plus a driver/receiver field session to validate GPS, photos, notifications and the actual receiving entrance.

Reference: [Supabase phone authentication setup](https://supabase.com/docs/guides/auth/phone-login).

## Work that remains mine, not yours

- Completed: deploy the migration and `wm-eta`, and verify hosted authorization/response contracts.
- Implement Client/Driver UI, state restoration and durable device command journal.
- Add safe public driver photo/contact delivery after the contact choice.
- Implement FCM registration, dispatch delivery and Android background location/notifications after project setup; test on devices.
- Integrate the chosen mobile-money provider after merchant/API access; test actual sandbox reconciliation.
- Add ETA rate limiting/caching and real Google validation before automatic tracking refresh at scale.
- Build the minimum receiver and firm workflows or document the agreed pilot operator procedure.

## Deployment runbook

The following deployment commands were completed successfully against the already-linked development project; retained here for reproducibility:

```powershell
& ./tool/backend/node_modules/.bin/supabase.cmd db push --linked --dry-run
& ./tool/backend/node_modules/.bin/supabase.cmd db push --linked
& ./tool/backend/node_modules/.bin/supabase.cmd functions deploy wm-eta --use-api
```

The migration grants only explicit authenticated reads and does not change service settings. Google configuration is required only when requesting ETA. Hosted authentication tests passed; real provider and Android integration remain separate validation steps. Live bookings remain governed by existing operational settings; do not enable them merely because this migration succeeds.
