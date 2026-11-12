# Exception handling specification

Version: 0.6, 2026-09-13. Parent: [canonical backend plan](BACKEND_PLAN.md).

Status: implementation and acceptance specification, with partial delivery. See the [deployed implementation and validation boundary](BACKEND_IMPLEMENTATION.md); this document is not a claim that every proposed handler is deployed. Confirmed owner rules take precedence: East Legon only, no mandatory household measurements, employee drivers can decline before acceptance but cannot voluntarily refuse after, clients pay cash/mobile money before normal departure, full trucks go to partner warehouses, urgent reports do not delay promised pickups, and collector QR confirmation records final completion. Stranded clients may rebook.

Policy markers: **C** = confirmed requirement; **P** = proposed recovery behavior; **O** = business parameter or choice still open. All unmarked handling below is proposed. Do not invent fees, time limits, geofence boundaries or completed payment/receipt events to unblock a flow.

Follow-up confirmations: booking fee GH₵1; client-to-warehouse dynamic transport fare based on distance, estimated travel duration, traffic and biodegradable/non-biodegradable service; five free minutes from arrival then GH₵0.90/min waiting; minimal authenticated collector screen with one QR per client pickup. Loading/payment time is interpreted as excluded, as stated back to the owner. Numeric dynamic rule values and rounding remain open. Live tariffs must not default missing parameters to zero or invent rates.

The owner explicitly has no transport prices yet and asked to keep them open. `PRICING_NOT_CONFIGURED` is the expected live response until a valid tariff is activated; payable booking must not advertise the GH₵1 booking component as the entire fare. Synthetic tariffs are allowed only in isolated development/test environments.

Owner designated Coliba Ghana / Lapaz Buyback Center, House No. 25 Dela Avenue adjacent to NHIS, Abeka Lapaz, for non-biodegradable collections only. Approximate Lapaz Total area reference: 5.60601, -0.24717; exact receiving entrance remains unverified. Biodegradable receiver is still being sought, so its live service stays unavailable. Material restrictions/hours, receiver accounts and MTN/Telecel merchant/API access remain open. Neither approximate coordinates nor network designation establishes operational readiness.

## 1. Common response contract

Every business command checks authenticated identity, authorized role, resource ownership/membership, current state/version and idempotency. Avoid holding a transaction open across Google/payment calls. Record successful mutation, actor/audit event and outbox intent atomically. Return a stable domain error rather than raw SQL/provider messages.

Example error envelope:

```json
{
  "code": "OFFER_EXPIRED",
  "message": "This offer has expired. Refresh your jobs.",
  "retryable": false,
  "recovery_action": "refresh_jobs",
  "current_version": 8,
  "correlation_id": "opaque-support-reference"
}
```

Unauthenticated responses use 401; forbidden access uses 403 or non-disclosing 404; state/version conflicts use 409; invalid/unsupported business inputs use 422; throttling uses 429 with retry guidance; temporary provider failure may use 503. A payment submitted but awaiting settlement has a pending result, not a misleading success/paid flag. Never put client personal data, provider secrets, raw QR tokens or raw SQL in logs/error responses.

Client retries reuse the same command key after an ambiguous timeout. Store the payload hash and committed result; same key/different payload returns `IDEMPOTENCY_CONFLICT`. Retention must cover expected offline/retry periods. Database/provider uniqueness constraints prevent duplicate assignment, payment references and handoff confirmation after deduplication records expire.

All incident records need type, affected request/assignment/load/payment as applicable, actor, server/device timestamps, evidence references, owner, severity, current state and audited resolution. Response targets are open, so do not promise a support SLA in the UI yet.

## 2. Authentication, staff access and device setup

| ID / trigger | Backend handling | User recovery / responsible owner |
| --- | --- | --- |
| A01 Invalid/expired OTP or login credential | Reject without creating an authenticated session or granting a role; rate-limit attempts and resend. Provider/method open. | Clear retry/recovery flow; firm assists employee provisioning, never requests a user's OTP. |
| A02 Duplicate signup or lost phone | Preserve account ownership; do not merge accounts by name or unverified phone. Require verified recovery before changing ownership. | Client follows recovery; firm reviews staff cases with an audit trail. |
| A03 Client chooses Driver/Collector or changes role metadata | Deny privileged capability; check protected employment/membership records. | Explain invitation/approval requirement. Firm grants bounded roles. |
| A04 Employee suspended, licence/approval expired | Stop new offers; revoke relevant sessions/tokens where supported. Existing client/waste custody becomes a firm incident, not a vanished job. | Firm arranges safe continuation or replacement. Suspended actor cannot perform ordinary commands. |
| A05 Session expires during collection | Do not discard local evidence or assume server acceptance. Preserve encrypted/local pending work within the device-security design. | Reauthenticate, refetch state, replay only still-authorized commands. |
| A06 Second device uses the same driver account | Track authorized devices and active assignment; prevent two conflicting active location sources with session/sequence controls. | Driver chooses current work device; firm investigates suspicious access. |
| A07 GPS denied, inaccurate or spoof-like jump | Allow manual client pin confirmation; exclude untrustworthy driver positions from precise ETA/arrival billing. Record measured_at/received_at/accuracy. | Driver restores permissions or contacts firm; no fabricated GPS. Anti-fraud threshold open. |
| A08 Camera/storage/push permission denied | No fake photo or push success. Explain which action requires evidence; allow agreed alternative evidence if supported. Push is not the job source of truth. | Resume upload/settings or firm-authorized evidence alternative. |

## 3. Booking, category and service boundary

| ID / trigger | Backend handling | User recovery / responsible owner |
| --- | --- | --- |
| B01 Pin outside service polygon | **C:** reject East-Legon-outside bookings once the approved polygon exists. No radius guessed from the name. | Client corrects pin; firm owns boundary configuration. |
| B02 Polygon missing/ambiguous boundary or unavailable geocoding | No claim of guaranteed serviceability. Accept explicit coordinates for validation if polygon is available; otherwise do not confirm a payable booking. | Retry or ask firm to validate; quote/booking pending rather than charged. |
| B03 Driver cannot access supplied pin/road/gate | Keep original location snapshot and evidence; changed pickup point requires client confirmation and fare/assignment revalidation. | Driver reports access issue; client gives access instructions; firm resolves failure if necessary. |
| B04 Client cannot provide quantity | **C:** allow booking without measurements. Missing is unknown, not zero. | Driver assesses operational load; never force a scale/measurement purchase. |
| B05 Both categories, mixed or misclassified waste | Do not quietly change category or add a surcharge. Preserve requested and assessed classifications; apply approved mixing/acceptance policy when defined. | Ask for separation or report problem; firm determines permitted handling. Mixed-request policy **O**. |
| B06 Suspected hazardous/medical/chemical/sharp or unsupported bulky material | Pause affected collection and create a firm safety/acceptance incident. Neither two-category label nor payment authorizes unsafe handling. | Firm determines approved service/referral. No unsupported automatic fee. Exclusion list **O**. |
| B07 Duplicate tap or network response lost | Replay committed booking result using client command key; no second request or second quote acceptance. | Show the existing request after reconnection. |
| B08 Apparent duplicate active booking from same household | Flag possible duplicate; do not automatically block valid separate category/household needs. A confirmed replacement needs a lineage link and mutually exclusive active coverage. | Client confirms intent; firm resolves accidental duplicates. |
| B09 Quote expired or tariff changes before booking | Recalculate with a new version; require client acceptance of material changes. Existing accepted quote is not silently rewritten. | Client sees updated fare components. Quote lifetime and change threshold **O**. |
| B10 Google route estimate unavailable | Do not use straight-line distance as billable road distance or invent a fare. Preserve input draft; retry or use a disclosed, firm-authorized alternative quote if such policy is adopted. | Client can retry/cancel draft; no confirmed paid service on a fabricated quote. |
| B11 Photo upload interrupted/orphaned | Keep upload pending and bind finalized objects to authorized records. Retry resumably where supported; clean unreferenced objects through a retention job. | Request remains honest about missing evidence; photo requirement **O**. |
| B12 User selects future date while scheduling not supported | Reject unsupported schedule through capability validation; no hidden conversion to immediate service. | Client selects supported immediate service. Scheduled release scope **O**. |
| B13 Client requests biodegradable collection before a receiving partner exists | Return `SERVICE_CATEGORY_UNAVAILABLE` with `receiver_pending` reason during category eligibility checks. Reject direct API and mixed-request attempts to route biodegradable scope to Coliba; create no fare, payment initiation or driver offer for that scope. | Display unavailable status without a promised launch date. Keep category in the model for future partner onboarding; do not silently substitute non-biodegradable service. |

## 4. Dispatch, acceptance and rebooking

| ID / trigger | Backend handling | User recovery / responsible owner |
| --- | --- | --- |
| D01 No eligible driver or all offers declined | Continue bounded search under the selected policy, then return no-driver status. Never claim a driver accepted because push was sent. | Client retries or ends search. Search duration/fees **O**; proposed no unsupported penalty. |
| D02 Driver declines or offer expires before acceptance | **C:** allow decline before acceptance. Atomically close offer and move dispatch forward; record cause. | Driver sees other eligible offers; client remains searching. |
| D03 Two drivers accept or an old offer arrives late | Lock/version check and unique active assignment; exactly one acceptance wins. Expired/revoked offer cannot be revived. | Loser refreshes; client sees one driver. |
| D04 Acceptance response lost | Retry same idempotency key and return existing assignment, not another acceptance. | Driver refetches accepted work before moving. |
| D05 Driver presses refuse after acceptance | **C:** deny voluntary refusal. Expose Report problem with a firm-owned incident instead. | Firm resolves; no ordinary driver cancellation privilege. |
| D06 Accepted driver offline or fails to arrive | Use stale-location/heartbeat indicators, not immediate automatic abandonment. Escalate after agreed thresholds; firm decides resolution. | Client sees tracking unavailable and contacts support; explicit linked rebooking available after original coverage is ended. |
| D07 Breakdown, accident, illness or unsafe situation | Preserve incident and custody. Block new offers; firm authorizes interrupted work handling. No requirement to continue physically unsafe work to satisfy an app state. | Firm arranges recovery/transfer or enables client replacement; emergency payment/departure exception recorded. |
| D08 Client rebooks stranded service | **C:** client may book another driver. End/supersede the old active assignment for the affected uncollected scope; create linked replacement with client consent atomically where possible. | Old driver sees revocation; only one active service covers that scope. Fee credit/requote rule **O**. |
| D09 Old driver arrives after replacement accepted | Reject stale progress commands using assignment revision; do not take another payment for the superseded scope. | Firm handles arrival confusion; current client/driver see authoritative replacement. |
| D10 Urgent report appears during promised pickup | **C:** do not preempt/delay accepted pickup. Queue or offer only to genuinely available capacity. | Firm triages urgency and explains any pending report. |
| D11 Driver goes offline/ends shift with accepted work | Availability toggle stops new offers, not existing obligations. Ending active duty with client/custody obligations requires resolution. | Driver completes promised work or reports incident to firm. |
| D12 All trucks full | **C:** route full trucks to partner warehouses. Owner expects many trucks; still no impossible immediate pickup commitment. Proposed available-fleet flow does not require clients to wait for unloading. | Return truthful searching/unavailability rather than invent another driver. Escalate to firm if exceptional shortage persists; thresholds **O**. |
| D13 Vehicle load changes after quote/offer | Revalidate capability before atomic acceptance; reject stale offer if infeasible. After acceptance use the incident workflow. | Firm coordinates unload/return or replacement without erasing acceptance history. |
| D14 Client cancels at same instant as driver accepts | Serialize state transition; one authoritative outcome. Apply only agreed cancellation policy, never both active assignment and final cancellation. | Show outcome and any proposed charge only under adopted fare policy. |

## 5. Arrival, waiting and physical collection

| ID / trigger | Backend handling | User recovery / responsible owner |
| --- | --- | --- |
| C01 Driver starts waiting away from pickup or before arrival | Reject unsupported waiting start; proximity alone is insufficient. **C:** five free minutes start at actual arrival. Require a validated arrival event and customer notice. | Driver corrects location or reports access problem. Arrival validation rules **O**. |
| C02 Exactly five minutes of eligible waiting | **C:** five free minutes, then GH₵0.90/min chargeable waiting begins; do not backdate to minute one. | Show free allowance/countdown; partial-minute rounding remains open. |
| C03 App killed, duplicate wait taps or device clock changed | Server state allows one active wait session for the visit. Derive charges from verified events; do not trust client wall-clock deltas. Offline disputed intervals are pending review. | Restore timer view from server; no double-start billing. |
| C04 Driver-caused delay, loading time, client payment time or provider outage | Distinguish reasons. Owner wording is interpreted as excluding loading/payment, so stop pickup-readiness waiting at loading start. Proposed also exclude driver/firm/provider-caused delay. | Itemize only eligible waiting; client can challenge it. Do not keep the meter running through payment. |
| C05 Client absent, gate locked, no response | Record arrival/contact attempt; notify client; cap or escalate waiting per adopted policy rather than charging indefinitely. | Firm ends failed attempt if unresolved; client may rebook. Wait cap/no-show fee **O**. |
| C06 Waste absent or another collector already removed it | Record no-collection outcome and evidence; no warehouse completion or fabricated pickup. | Firm handles any disputed callout fee; new request only if needed. |
| C07 More waste than driver can safely carry | No obligation to exceed capacity. Report affected scope and load state; partial collection requires explicit client/firm agreement and a receipt for what actually happened. | Firm handles unload/return or linked remainder collection. No automatic unapproved surcharge. |
| C08 Truck fills after some waste is loaded | **C:** direct to warehouse when full. Preserve collected custody and uncollected remainder; do not mark whole request done. | Firm resolves remaining service and client payment treatment; full-truck dispatch interpretation **O**. |
| C09 Waste spills, property damage or client alleges loss | Record incident/evidence without editing the original pickup/payment history; separate service recovery and dispute. | Firm handles cleanup, claims and any authorized financial adjustment. |
| C10 Driver marks collected with no evidence/invalid state | Check assigned actor and agreed evidence contract; reject illegal transition. Offline proof remains pending. | Submit evidence or obtain logged firm resolution; pickup proof method **O**. |
| C11 Client disputes waiting/collection/category | Freeze disputed additions pending decision under proposed policy; preserve uncontested and disputed amounts distinctly. | Firm reviews evidence; no forced acceptance or silently inflated amount. |
| C12 Client requests a different pickup site after acceptance | Snapshot change, service-area and route/fare revalidation; do not silently redirect driver. | Driver/client get proposed change; firm resolves conflicts with promised service. |

## 6. Cash and mobile-money payment

Payment exceptions never manufacture payment success or warehouse confirmation. The firm owns recovery. Normal departure follows confirmed payment (**C**); safety/provider/dispute exceptions require an auditable firm path (**P**).

| ID / trigger | Backend handling | User recovery / responsible owner |
| --- | --- | --- |
| P01 Fare computation differs across apps | Compute authoritative server fare from accepted tariff/distance and approved waiting. Return breakdown and version. | Refresh; driver cannot edit unit rates. |
| P02 Client rejects an added waiting fee | Preserve timer reason/events and quote disclosure; create dispute. Do not rewrite history or automatically add a dispute penalty. | Firm resolves payable amount and permitted departure exception. |
| P03 Cash insufficient/no change/no cash | Record amount actually received, if any, separately from total due. No paid status for an unpaid balance. | Offer supported mobile money or firm resolution. Split-tender support **O**. |
| P04 Driver claims cash paid but client denies | Mark cash entry as driver-attested and open dispute; preserve both claims. | Firm reconciles. Digital receipt alone does not prove exchange of physical cash. |
| P05 Driver receives cash but does not remit to firm | Client remains paid if payment is established; create employee cash reconciliation variance. | Firm handles employee remittance separately; do not recharge client. |
| P06 Mobile-money request accepted/202 or handset prompt displayed | Store pending payment attempt, not paid. | Client completes authorization; app waits for verified final provider status. |
| P07 Client declines, has insufficient balance or provider returns failure | Record final failure for that attempt; never loop automatic debits. | Client chooses supported retry/new attempt or cash. |
| P08 Request times out with unknown outcome | Keep stable provider reference; query status and reconcile. Do not create a second charge while the first outcome is unknown. | Explain payment checking; firm handles departure exception if needed. |
| P09 Callback missing, delayed, duplicated or out of order | Persist deduplicated provider events; reconcile final authoritative status; reject regressions without a legitimate reversal event. | Background reconciliation/firm queue; no duplicate receipt or outbox effect. |
| P10 Callback forged or amount/currency/reference mismatch | Verify using selected provider's supported scheme and authoritative query where needed; quarantine mismatch. | Firm/provider investigate; do not mark paid. |
| P11 Client shows screenshot/SMS/transfer to wrong number | Treat as claimed payment, not settlement proof. Do not ingest another customer's transaction as this payment. | Firm traces merchant reference; MTN/Telecel networks confirmed, recipient merchant and API integration **O**. |
| P12 Switch from pending MoMo to cash, then late MoMo succeeds | Track both tender events and overpayment liability; do not overwrite the earlier cash receipt or hide the extra payment. | Firm reconciles and performs one documented refund/credit under chosen policy. |
| P13 Success then provider reversal/chargeback | Append reversal/dispute ledger entry; reopen financial issue only. Preserve collected and warehouse-confirmed facts. | Firm reviews recovery/refund; no automatic second debit. |
| P14 Duplicate refund request or refund pending | Stable adjustment/refund key, unique provider reference and pending status; do not issue twice after timeout. | Query/reconcile and notify client when final. Refund policy/provider features **O**. |
| P15 Client cannot/will not pay after collection | Outstanding balance + firm incident. No fake payment, fabricated warehouse cancellation or driver detention workflow. | Firm decides recovery and departure exception; driver safety takes precedence. Penalties/restrictions **O**. |
| P16 Network outage at premises | Cash can be recorded locally as pending sync under proposed policy; MoMo cannot become verified paid from an offline guess. Preserve receipt reference. | Restore network or firm resolves departure; replay is idempotent. |
| P17 Replacement requested after original payment | Link original fare/payment to affected collected/uncollected scope; block automatic double-charge or automatic transfer without policy. | Firm determines credit/refund/new fare and client accepts it. |
| P18 Future warehouse leg changes after client paid | Preserve locked quote/fare; no silent charge for later reroute or receiver closure. | Firm absorbs or handles an explicitly authorized adjustment policy. Client-to-warehouse is confirmed; quote locking/adjustment policy **O**. |
| P19 Dynamic fare rules missing or estimator input invalid | Block activation of incomplete fare rule; no guessed/zero live rates. Validate biodegradable/non-biodegradable category, estimated travel duration, tariff version and required estimator inputs. | Firm defines numeric dynamic rates when ready; category/time definitions, booking and waiting rates are already confirmed. |
| P20 Multiple clients share the truckload | **C:** each client's billable journey is client-to-warehouse. Proposed charge the accepted direct road-distance quote for that client's selected warehouse, not the total shared pickup tour. | Adopt warehouse selection and distance-commitment policy; show each client's own fare breakdown. |
| P21 Traffic/time changes after quote or pickup payment | Proposed lock the accepted transport quote; no retroactive traffic/time surcharge without an adopted adjustment policy and consent. | Before booking, an expired quote requires a new accepted version; after payment, firm resolves exceptional change. |
| P22 Pricing counts traffic twice or mixes travel time with waiting | Use named components and documented rules. A traffic-aware travel-duration fee must not automatically gain another fee for the same delay. Exclude loading/payment from pickup waiting under the stated interpretation. | Test representative fares and show separate components; firm adopts pricing policy before activation. |
| P23 Wrong wallet network selected or wallet validation fails | Validate the selected MTN/Telecel wallet through the chosen integration; do not infer current network solely from phone prefix or automatically debit the other network. | Client corrects details. If an attempt was already submitted, reconcile its outcome before a replacement attempt. |
| P24 One network unavailable, merchant not configured, or client switches between networks | Disable initiation for unready network; retain cash/other network only if configured and supported. Switching an unknown/pending attempt must not produce two independent debits. | Explain unavailable/pending status; verify/cancel/reconcile existing attempt through supported mechanisms before creating a new one. Any late duplicate payment follows P12. |

## 7. Routing, warehouses and QR receipt

| ID / trigger | Backend handling | User recovery / responsible owner |
| --- | --- | --- |
| W01 Google unavailable/quota exceeded/no feasible route | Use last valid operational plan only if still suitable; flag timestamp and suppress stale precision. No fabricated navigation or billable distance. | Firm gives authorized routing instruction; preserve accepted commitments. |
| W02 Road blocked or unsafe for actual vehicle | Driver reports issue; firm-authorized reroute, recorded reason and revised ETA. Ordinary route output is not a guarantee of truck access. | Client gets delay information; no unapproved detour charge. |
| W03 Warehouse closed/full/not accepting category | Do not route as a confirmed destination or mark unload complete. Validate approved alternative's capability/hours. | Firm contacts approved partner or resolves hold; no arbitrary dumping destination. |
| W04 No warehouse can receive a full truck | Preserve full/unresolved custody, stop new impossible commitments, open a priority operational incident. | Firm arranges lawful/approved receiving route; client wait/rebook follows agreed policy. |
| W05 Warehouse outside East Legon | Distinguish approved operational destination from client service-area eligibility. | Owner confirms destination; never expand client booking polygon implicitly. |
| W06 Driver requests QR before relevant waste is collected | Deny token for ineligible/unowned pickup scope or a request to complete a whole truckload. **C:** one QR represents one client's pickup; payment/custody exception must be explicit. | Correct handoff or firm reviews. |
| W07 Scanner is unauthenticated, wrong warehouse or the driver | Deny receipt confirmation regardless of possession of QR. Do not leak private manifest data. | Authorized receiving staff sign in; firm manages membership. |
| W08 Expired/revoked QR or screenshot of previous QR | Reject stale token; regenerating rotates token and preserves handoff identity/manifest. | Driver displays fresh code. Token lifetime **O**. |
| W09 QR scanned but collector has not confirmed | Record optional presentation/audit only; no completion or load reset. | Collector reviews and explicitly confirms/rejects. |
| W10 Two receivers scan/confirm simultaneously | Atomic token consumption and per-pickup handoff-item uniqueness; one result, safe idempotent replay. | Other screen refreshes existing confirmation or receives conflict. |
| W11 Manifest changes after QR issuance | Reject confirmation against outdated version; revoke/regenerate token after permitted change. | Collector reviews current list before confirming. |
| W12 QR corrupted/camera unavailable/driver phone dead | No unauthenticated bypass or universal completion code. Proposed alternate authenticated handoff lookup with driver/manifest verification and firm authorization. | Receiving staff contact firm; manual exception retains equivalent audit/evidence. |
| W13 Offline scan/confirmation submission | Queue pending intent with actor/session info and operation key; reauthenticate/revalidate current token and manifest when online. Do not automatically backdate/accept expired authority. | Firm reconciles physical receipt if ordinary online confirmation can no longer be verified. |
| W14 Warehouse rejects contamination or some items | Record rejection/accepted items, reason and evidence. Complete only accepted attributable scope; keep rejected custody and load state. A partially received pickup remains unresolved overall. | Firm arranges appropriate follow-up. Mixed pickup attribution and residual handoff policy **O**. |
| W15 Driver claims unloaded but collector disputes receipt | Keep custody unresolved and load reset unverified; do not release unsafe capacity on a unilateral claim. | Firm investigates; approved correction is append-only with reason. |
| W16 Partner confirms wrong manifest by mistake | Never delete confirmation silently. Append correction/reversal of receipt assertion and affected completion projection, retaining prior evidence. | Firm authorizes correction and notifies affected parties. |
| W17 Client paid but warehouse confirmation overdue | Preserve paid/collected state and identify warehouse handoff as pending, not client non-payment. Track aged custody for firm review. | Client sees truthful status; firm resolves. Max handoff time **O**. |
| W18 Truck carries multiple clients/categories | **C:** scan and confirm each client's pickup QR separately; never complete unrelated pickups. Do not reset truck to empty after its first QR. Check all carried scope for receipt/authorized transfer before load reset. | Receiver uses outstanding-pickup list. Define category segregation and physical attribution if waste has been mixed. |
| W19 Driver loses waste or makes an unauthorized transfer | Preserve incident and custody chain; require receiving-actor/vehicle transfer record for any authorized recovery. | Firm investigates and arranges resolution; no self-issued QR completion. |
| W20 Coliba routing attempts use approximate area reference or unsupported materials | Preserve owner-confirmed Lapaz address and non-biodegradable assignment. Store 5.60601, -0.24717 as approximate reference only; never silently promote it to a billing endpoint/arrival geofence. Do not treat all non-biodegradable materials as accepted without restrictions. | Firm verifies vehicle entrance, receiving hours/materials and accounts. Biodegradable cannot use Coliba as fallback while its partner is pending. |

## 8. Synchronization, notifications and data operations

| ID / trigger | Backend handling | User recovery / responsible owner |
| --- | --- | --- |
| S01 App crashes after successful command | Refetch authoritative state with the same operation key; never repeat charge/assignment/confirmation as new work. | Restore current screen and pending queue. |
| S02 Offline status arrives after reassignment/completion | Check assignment revision/current authority; reject stale mutation. Preserve submitted evidence for authorized incident review, without applying it to replacement work. | Explain conflict; firm reviews legitimate past activity. |
| S03 Location updates arrive out of order | Compare session/sequence and measurement times; keep last trustworthy position; preserve received time for staleness handling. | Show stale tracking until fresh input. |
| S04 Push fails, duplicate push or user disables alerts | Persist outbox/in-app state, deduplicate event effects and retry bounded delivery. Do not change job/payment state based on push. | Client/driver can refresh; firm gets unresolved critical delivery visibility. |
| S05 Database/provider temporary failure | Roll back partial business mutation; retry transient failure with bounded backoff and same command reference. Keep committed provider operation discoverable for reconciliation. | Display pending/retry state; no optimistic irreversible success. |
| S06 Worker crashes after sending push/provider request but before acknowledging queue | At-least-once processing with idempotent side effects and unique external references. | Worker recovers; firm reviews exhausted retries/dead-letter items. |
| S07 Data leak attempt via IDs, photo URL or realtime channel | Enforce owned/scoped access for database, Storage, functions and realtime; signed links expire. No client-wide driver-history subscription. | Deny and log security event without leaking the record. |
| S08 Account deletion with active work/payment/custody | Revoke appropriate access; resolve active obligations and apply adopted retention/anonymization rules. Do not erase audit/financial facts accidentally. | Firm handles deletion request using documented policy. Retention periods **O**. |
| S09 Firm overrides assignment, fare or handoff | Narrow permission, required reason, version check and append-only audit; adjustment has distinct author and event. | Affected actors see updated authoritative result. No routine service-key sharing. |
| S10 Staff operator unavailable while dashboard deferred | Incident remains owned/visible through the minimum firm workflow and agreed contact path. | Pilot cannot launch without named duty coverage and an escalation contact. |
| S11 Report dumping action used before triage/funding adopted | Capability disabled or clearly unavailable; do not accept a request into a nonexistent service queue. | Explain unsupported feature until scope is agreed. |
| S12 Future dumping report duplicates/is false/is genuinely urgent | If feature is adopted, preserve evidence, link duplicates, restrict abuse and route to firm triage. **C:** urgent work never delays existing promises. | Report funding/response rules remain **O**; no automatic paid collection obligation. |

## 9. Test and launch acceptance contract

Each catalogue ID must map to a test or a documented field drill; unit tests alone cannot verify GPS, cash exchange, actual device background behavior or physical warehouse receipt. Tests should assert resulting state, authorization, financial/custody effects and recovery, not just response messages.

Required high-risk automated scenarios:

1. Two concurrent driver acceptances: one active assignment, one losing conflict, one accepted-event effect.
2. Acceptance/cancellation race and rebooking/old-driver race: no duplicate active coverage or duplicate fare.
3. Driver refusal after acceptance is denied; firm interruption preserves incident, authorization and client replacement path.
4. Client measurements are optional. Non-biodegradable booking can succeed in a configured test environment; biodegradable without a receiver returns `SERVICE_CATEGORY_UNAVAILABLE`, with no quote/payment/driver offer. Calling the API directly or requesting mixed scope cannot bypass this rule; unsupported area also fails without payment initiation.
5. Waiting at exactly 300 seconds has no fee; 301 seconds follows the selected excess/rounding rule; duplicate starts and a changed device clock cannot overbill. Loading/payment time stops or excludes the meter under the stated interpretation.
6. GH₵1 booking fee is applied once per adopted booking/credit policy; only client-to-warehouse distance is considered. Tariff change after acceptance cannot silently change the booked fare; unapproved driver detours/provider-delay waiting do not add charges under the proposed policy. Incomplete or ambiguous tariffs cannot activate.
7. Ambiguous mobile-money timeout uses the existing reference; replayed/out-of-order callbacks and late success after cash cannot create hidden double settlement.
8. Driver cannot mark MoMo paid from a screenshot, set arbitrary rates, alter another driver's assignment, or confirm their own warehouse receipt.
9. QR scan alone changes no completion state; wrong receiver, expiry, replay, altered pickup handoff and concurrent confirmations are handled atomically. Each QR covers exactly one client's pickup.
10. Partial/rejected warehouse receipt retains unresolved custody and does not reset the truck as empty or finish unrelated orders. With three clients' loads, confirming the first QR leaves the other two pending.
11. Offline replay after reassignment cannot modify replacement work; evidence and unresolved incidents remain recoverable.
12. Client A/driver B/warehouse C isolation holds across tables, functions, Storage and realtime; private contact/location data is inaccessible outside authorized scope.
13. MTN and Telecel each pass pending/success/failure and duplicate-event scenarios through the selected integration. Wrong network, unavailable merchant and switching after a timeout cannot produce silent double payment or a false paid flag.
14. Coliba Lapaz with only approximate reference coordinates cannot be treated as a verified routing endpoint. Non-biodegradable assignment does not enable biodegradable service or accept every possible material. Confirming the entrance does not expand the East Legon client-service polygon.

Required field drills: low/no signal at client and warehouse; denied location/camera permissions; driver app killed during waiting; cash change shortage; pending mobile-money payment at departure; full truck with accepted work; inaccessible property; warehouse closed/rejecting a load; unreadable QR; operator correction; provider outage and restoration.

Pass criteria include no duplicate charge/assignment/confirmation, no false paid/completed label, no unowned stranded client or waste custody, and an intelligible recovery path. Quantitative pilot targets and escalation deadlines still require owner input.

## 10. Decisions required before implementing dependent handlers

- Approved East Legon boundary; exact vehicle entrance for the specified Coliba Lapaz address, receiving hours/material restrictions and receiver accounts; waste exclusions, mixing and partial collection policy. Biodegradable receiver remains pending and its service unavailable; do not repeatedly ask for a partner before one is secured.
- Full-truck edge-case resolution if the normal available-fleet proposal is not adopted; one accepted client visit per driver; offer/arrival/search thresholds.
- Dynamic rate activation when the firm is ready, client-to-warehouse quote commitment, excess-wait rounding, waiting cap, cancellation/rebooking/refund treatment. Service category and estimated travel duration definitions are confirmed.
- MTN/Telecel firm merchant destinations and API access; direct integrations versus payment integration provider; cash remittance and disputed/nonpayment departure authority.
- Placement of the approved per-client QR receiver interface, pickup evidence, mixed-load attribution, residual handoff and receipt correction authority.
- Auth/recovery provider, Android tracking/offline requirements, role provisioning, retention and minimum firm duty coverage.

Missing decisions block only the handlers that depend on them. Foundation work can proceed with explicit interfaces and disabled capabilities; live billing and final completion cannot be guessed.
