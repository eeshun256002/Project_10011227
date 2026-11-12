# Separate Client and Driver app onboarding

Owner decisions, 2026-09-13: separate Client and Driver applications; ordinary email/phone authentication; drivers upload their documents and the firm verifies them. A current Ghanaian driving license, face photo, vehicle insurance and roadworthiness certificate are required. Ghana Card is recommended, not mandatory.

This step adds the backend contracts. It does not build or split the Android UI projects yet.

## Tables visible in Supabase

| Schema/table | Purpose |
| --- | --- |
| `auth.users` | Supabase-managed email/phone identity, credential hashes and verification. Never store passwords in application tables. |
| `wm.profiles` | Common account record and active/suspended status. |
| `wm.client_profiles` | Explicit client-app enrollment and full name. Driver signup does not automatically create this enrollment. |
| `wm.driver_applications` | Applicant identity details, vehicle plate/make/model, submission state, version and latest firm decision. |
| `wm.driver_documents` | One versioned record per uploaded document: type, private file path, license number/class, dates, associated vehicle plate and review status. |
| `wm.driver_application_reviews` | Firm review decisions, reasons, reviewer, timestamp and application version. |
| `wm.drivers`, `wm.vehicles` | Approved employee's operational driver account and firm-assigned truck. These are provisioned only after document approval. |

Four new tables were added by `20260913000600_driver_onboarding.sql`. Documents use the private `wm-driver-documents` Storage bucket. File bytes are stored in Storage; document metadata and review history are stored in Postgres.

| Document `kind` | Required | Validation |
| --- | --- | --- |
| `driving_license` | Yes | Ghana issuing country, license number, class, expiry date, uploaded file and firm approval. |
| `profile_photo` | Yes | JPEG/PNG/WebP image and firm review for a clear face photo. PDF is rejected. |
| `vehicle_insurance` | Yes | Expiry date, uploaded certificate/sticker, matching application vehicle plate and firm approval. |
| `roadworthiness` | Yes | Expiry date, uploaded certificate/sticker, matching application vehicle plate and firm approval. |
| `ghana_card` | No | Optional private identity-verification document. Omission does not block submission or approval. |

License and vehicle certificates must not be expired. An optional issue date cannot be in the future. An expiry date is valid through that date in the database's UTC/Ghana calendar. A fresh upload is not proof of authenticity: the firm must verify the license's legality/class, photo clarity, identity and vehicle documents before recording approval. No DVLA, insurance-authority or Ghana Card registry integration is claimed.

Name and vehicle plate are required when saving an application. Date of birth, residential address, emergency contact and vehicle make/model fields are supported but not made mandatory without further owner requirements. Phone/email and verification come from Supabase Auth. The application plate is normalized to uppercase; firm provisioning should use that same plate.

## Signup versus login

**Client app:** create an Auth account using email or phone and password, complete verification, then call `client.register` with the full name. Existing clients sign in normally. Live quotes require client enrollment; they never require driver documents.

**Driver app:** create and verify an Auth account, save a driver application, upload the required documents, submit for firm review, and await approval/provisioning. The driver can sign in normally while the application is a draft or awaiting review; only onboarding/status access is available before staff approval.

Drivers do not upload documents on every login. On subsequent sign-in, call `wm_account_access` and `wm_my_driver_application`. Present the application status or the driver home screen based on server permissions. Rejected/expired documents can be renewed through the application workflow. Drivers with expired/revoked documents cannot go online for new work or accept new jobs. Existing pickup/custody actions remain available so an in-progress obligation can be resolved safely.

Both apps may share one Supabase Auth project; permissions are enforced by enrollment and database checks, not by trusting an app-name field. A person can explicitly enroll as a client as well; doing so does not grant driver permission.

Hosted Auth inspection on 2026-09-14: **email and phone signup enabled**, signup allowed, and both confirmation requirements retained. This supersedes the earlier disabled-phone observation. SMS and email delivery have not been tested with a real recipient; an enabled flag alone is not delivery verification. See [Supabase password-based Auth](https://supabase.com/docs/guides/auth/passwords).

## API sequence

Call `wm_onboarding_command(p_action, p_payload, p_command_key)` using the signed-in user's JWT. Persist/reuse the same UUID command key for uncertain retries. Every existing-application mutation requires the latest integer `version`; refresh after `VERSION_CONFLICT`. Replies return the updated version, or a full application for `application.save`.

1. `client.register`: `{full_name}` for a client account.
2. `application.save`: `{full_name, vehicle_plate, date_of_birth?, residential_address?, emergency_contact_name?, emergency_contact_phone?, vehicle_make?, vehicle_model?, version?}` for a driver. Dates are ISO `YYYY-MM-DD`; emergency phone, when supplied, is in international `+233...` form.
3. `document.reserve`: `{version, kind, content_type, document_number?, license_class?, issued_on?, expires_on?, issuing_country?}`. Returns `document_id`, `bucket`, `path`, and new `version`. Country defaults to `GH`; a supplied different country is rejected. Vehicle certificates are bound to the application plate at reservation.
4. Upload the image/PDF to that exact private Storage path, using `upsert: false`. Only the applicant can upload. Maximum size is 10 MB; profile photo is image-only.
5. `document.finalize`: `{version, document_id}`. Checks object existence, owner, MIME type and size. A reservation alone never satisfies a requirement.
6. `application.submit`: `{version}`. Requires all four current, unexpired mandatory documents to have been uploaded. Ghana Card is optional.
7. Firm uses `wm_driver_application_queue` and `wm_driver_application(application_id)` to inspect the application and private documents. Review is a privileged API; the full regulator UI is still deferred.
8. `operator.review_document`: `{application_id, version, document_id, decision, reason}`. Decision: `approved`, `rejected`, or `revoked`. A reason is mandatory. Applicant cannot review their own documents even if they also hold an operator role.
9. `operator.review_application`: `{application_id, version, decision, reason}`. Decision: `approved`, `rejected`, or `changes_requested`. Approval requires all four mandatory documents to be individually approved/current.
10. Existing `wm_command('operator.driver', ...)` provisions the employee/vehicle using `{user_id, plate, reason}`. Its database trigger now rejects missing/expired/unapproved documents and mismatched vehicles.

`application.reopen` with `{version}` reopens an approved or rejected application as a draft. Draft/changes-requested applications can replace documents. Replacement preserves the old record, removes its current flag and requires a fresh review. Submitted/approved files cannot be silently overwritten. Renewed applications must be resubmitted and approved. Changing the vehicle plate requires corresponding current vehicle certificates.

Read RPCs:

- `wm_account_access`: client enrollment, driver application status, staff provisioning and current eligibility for new jobs.
- `wm_my_driver_application`: applicant's dossier or `null` before starting.
- `wm_driver_application(p_application_id)`: own dossier or firm-authorized review.
- `wm_driver_application_queue(p_status='submitted')`: firm-only list, bounded to 100 entries.

The Flutter `WasteBackend` wrapper exposes `executeOnboarding`, `accountAccess`, `myDriverApplication` and `driverApplication`. Password authentication stays with `SupabaseClient.auth`.

## Privacy and validation

Driver identity documents are not accessible to clients, other drivers or receivers. Only the applicant and active firm operators can read them; firm users cannot upload in the applicant's place. Storage is private and has no app overwrite/delete policy. Do not put document numbers, images or signed URLs in general event logs. See [Supabase Storage access control](https://supabase.com/docs/guides/storage/security/access-control).

Regression tests cover client enrollment, missing/invalid/expired documents, forbidden uploads/read access, optional Ghana Card, self-review prevention, approval bypass prevention, vehicle mismatch, expiry, revocation and renewal history. The hosted onboarding smoke script rolls back its synthetic users/document metadata. Actual file bytes, human verification, email/SMS delivery and Android screens still need integration/field testing.

```powershell
npm test --prefix tool/backend
node tool/backend/check-auth.mjs
& ./tool/backend/node_modules/.bin/supabase.cmd db query --linked --file tool/backend/hosted-onboarding-smoke.sql
```
