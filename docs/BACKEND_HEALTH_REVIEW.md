# Backend health review — 2026-09-14

Project: `wjjabfihijpilgimdhzp` / Waste Management Platform. Final database audit: 15:33 UTC; provider status: 15:34 UTC.

**Assessment: partly correct.** The database and tested authorization paths work. Private table REST access is intentionally unavailable. Index coverage needed improvement. Disabled gateway JWT checks did not mean the functions were anonymous: user handlers already validated tokens against Auth, and the worker checked a separate secret. Those controls have now been strengthened and tested live. The previous incident conclusion was not reliable.

## Findings and fixes

| Assessment item | Verified result | Action |
| --- | --- | --- |
| Database structure | 27 application tables; all have RLS. Hosted pickup/payment/QR and onboarding regression tests pass. | Preserved the schema; deployed two hardening migrations. |
| Direct REST access | Requests with `Accept-Profile: wm` return HTTP 406. There are no authenticated-role insert/update/delete grants on application tables. | Kept `wm` private. Apps use explicit public RPCs; exposing all tables would bypass the intended API boundary. |
| SECURITY DEFINER RPCs | Only `wm_catalog()` is anonymously executable. Every application definer function has an empty fixed search path. Privileged RPCs reject ordinary users. | Removed the unused public dispatch helper, moved the internal quote implementation into `wm`, and revoked permissive defaults for future functions created by the migration owner. Existing RPC grants remain explicit. |
| Edge Functions | All three previously had `verify_jwt=false`, but had handler-level authentication. Anonymous/invalid tokens were already rejected in live checks. | Enabled gateway JWT checks for `wm-quote` and `wm-dispatch`, retaining live Auth validation. Worker remains `false` intentionally because Cron uses a dedicated secret; tightened its Bearer parsing and tested correct/incorrect secrets. |
| Performance | 29 foreign keys lacked complete supporting indexes. Caller-only RLS predicates ran repeatedly, and order history re-queried authorization per result. | Added complete FK index coverage and targeted queue/history/evidence indexes; added statement-level caller checks to RLS; changed order-history filtering to ownership predicates. Final audit: zero uncovered FKs. |
| Evidence upload | The uploader's pre-finalization SELECT policy did not match Storage's INSERT RETURNING needs. | Allowed the uploader to read the reserved upload before finalization; other participants still cannot read it until finalized. Tested INSERT RETURNING and privacy. |
| Incident reporting | Application incident query is available and returns zero open incidents. Supabase's external feed is available and reports unresolved incidents. | Health tooling distinguishes local incidents from provider incidents and returns `unknown` when the feed cannot be checked. It no longer treats an unavailable status request as an empty incident list. |

The final guard functions execute at runtime. Error/authorization helpers are not marked immutable: an always-raising immutable function can be evaluated during planning even in a branch no row takes. A regression test covers this case.

The dispatcher now checks database authorization before reading Google configuration. Permission failures map to HTTP 403 instead of generic HTTP 400. No Google, payment or SMS credentials were changed.

## Evidence

- `tool/backend/health-before.json`: initial read-only metadata audit; 29 uncovered foreign keys.
- `tool/backend/health-after.json`: final metadata audit; 27 RLS-enabled tables, zero direct user write grants, zero unsafe definer search paths, zero uncovered foreign keys and only the catalogue anonymously callable.
- `tool/backend/health-functions.json`: hosted `wm-quote` and `wm-dispatch` have JWT verification enabled; `wm-worker` has its documented secret-based mode. All three are active.
- `tool/backend/health-http.json`: catalogue reachable, protected RPCs/Edge routes reject anonymous or invalid credentials, private table REST rejected, provider status warning surfaced.
- 19 Node/Postgres/status tests pass, including the normal driver/client workflows and new hardening regressions.
- Eight Deno auth/routing/HTTP tests pass; all Edge entry points type-check.
- Hosted `public,wm` database lint at error level returns no issues.
- Both hosted transactional smoke tests pass and roll back synthetic application data.
- A confirmed temporary Auth account exercised actual signed user JWTs. A valid JWT reached the quote's client-registration check; an ordinary user could not dispatch, invoke the worker, grant operator privileges or forge a service-role claim. The test sends no email/SMS and removes its Auth account/profile afterward.

There are no real users or orders in the audited project. Index coverage and query-plan structure are verified; these checks are **not production-load benchmarks**. Real SMS delivery, document bytes, live Google routing, mobile-money integration and Android field behavior remain separate integration checks. Live bookings remain disabled by configuration.

Phone signup is now enabled, with confirmation still required; email signup is enabled too. This supersedes the earlier observation that phone signup was disabled. An enabled flag does not establish that an SMS was delivered.

## Provider status

At 15:34 UTC, Supabase's feed reported:

- [401 errors due to JWT rejections](https://status.supabase.com/incidents/6q5902p2xd9f), identified; API Gateway degraded performance.
- [Network access issues affecting a limited number of users in Myanmar](https://status.supabase.com/incidents/swgfk4tv1rvs), monitoring. This does not establish an impact on the Ghana deployment.

The authenticated checks on this project passed. They do not rule out an intermittent provider fault on future token renewal. A platform incident cannot be repaired by changing this application's tables or weakening authentication. Provider status is a timestamped snapshot, not a permanent verdict.

## Repeat the checks

```powershell
npm test --prefix tool/backend
& ./tool/backend/node_modules/.bin/deno.cmd task --config supabase/functions/deno.json test
& ./tool/backend/node_modules/.bin/deno.cmd task --config supabase/functions/deno.json check
& ./tool/backend/node_modules/.bin/supabase.cmd db lint --linked --schema public,wm --level error --fail-on error
& ./tool/backend/node_modules/.bin/supabase.cmd db query --linked --file tool/backend/health-audit.sql
node tool/backend/check-hosted.mjs
```

`check-hosted.mjs` exit codes: `0` checks pass and no provider warning; `1` a local/backend assertion or request failed; `2` backend checks pass but provider status is degraded, has active incidents, or is unavailable. The JSON separates `backend_check`, `overall` and `platform`. Inspect `bookings_enabled` separately from health.

`node tool/backend/check-authenticated.mjs` creates a synthetic confirmed account in this development project for the live token tests. It captures management credentials only in memory and never prints them. It cleans up in `finally`. If a network/CLI failure interrupts cleanup, `node tool/backend/check-authenticated.mjs --cleanup` uses the ignored recovery record, verifies the synthetic account identity and removes it. Do not run several management CLI processes concurrently with this test's cleanup.

Changes: `20260914000100_health_hardening.sql`, `20260914000200_runtime_guards.sql`, Edge authentication/configuration, and repeatable checks. The full operator dashboard remains deferred.

References: [Supabase Edge authorization headers](https://supabase.com/docs/guides/functions/auth-headers), [RLS performance guidance](https://supabase.com/docs/guides/database/postgres/row-level-security), [Storage access control](https://supabase.com/docs/guides/storage/security/access-control), [provider status feed](https://status.supabase.com/api/v2/summary.json).
