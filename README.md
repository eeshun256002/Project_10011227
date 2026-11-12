# Mohotew

Frontend: [canonical plan](docs/FRONTEND_PLAN.md) and [implemented gap contracts / owner setup checklist](docs/FRONTEND_GAPS_IMPLEMENTATION.md).

Android mobile application built with Flutter and hosted Supabase. Development, builds, and device testing currently target Android. The iOS scaffold is retained for later; iOS development is on hold. The project lives in this directory, with a placeholder screen for upcoming design work.

Backend: [implementation and setup guide](docs/BACKEND_IMPLEMENTATION.md), [canonical working plan](docs/BACKEND_PLAN.md), and [exception handling specification](docs/EXCEPTION_HANDLING.md). The first backend is deployed to hosted Supabase with live bookings disabled pending operational configuration. It includes client/driver APIs, dispatch, cash payment attestation and one warehouse-confirmation QR per client's pickup. The regulator dashboard remains deferred. The implementation guide distinguishes tested features from remaining integrations and proposed exception handlers.

Designated non-biodegradable receiver: Coliba Ghana / Lapaz Buyback Center, House No. 25 Dela Avenue, adjacent to the NHIS office, Abeka Lapaz, Accra. The owner-supplied coordinates 5.60601, -0.24717 are an approximate area reference, not a verified vehicle entrance. Biodegradable collections remain unavailable for live booking pending a separate receiving partner. Supported payments: cash, MTN MoMo and Telecel Cash; merchant/API integration is not yet configured. Dynamic transport prices remain intentionally unset.

## Development

Separate Client/Driver account and document requirements: [driver onboarding](docs/DRIVER_ONBOARDING.md). The backend includes private document upload/review tables; phone signup is enabled, with SMS delivery still unverified. The current Android UI remains a scaffold. See the [verified backend health review](docs/BACKEND_HEALTH_REVIEW.md) for security, performance and provider-status findings.

Setup uses Flutter 3.47.4 and Dart 3.13.3.

```powershell
flutter pub get
dart run tool/check_connection.dart
flutter devices
flutter run -d <android-device-id> --dart-define-from-file=.env
```

Start an emulator in Android Studio or connect an Android phone with USB debugging enabled. Replace `<android-device-id>` with the Android device ID from `flutter devices`. In VS Code, select that Android device and use the Mohotew (Android) launch configuration, which passes the environment file automatically.

Your existing .env is preserved. For another checkout, copy .env.example to .env and supply the hosted project URL and publishable key. Flutter reads these via --dart-define-from-file; the file is not bundled as an asset. Supabase initializes at startup and supabase_flutter handles session persistence. Initialization alone does not verify connectivity; use the Dart connection check to read Auth settings without changing remote data.

Only use a publishable or legacy anon key. Client configuration is recoverable from compiled apps, so protect database access with row level security. Never use secret or service-role keys in the mobile app. Git ignores .env.

```powershell
flutter analyze
flutter test
flutter build apk --debug --dart-define-from-file=.env
```

The generated com.example.mohotew identifier and default icons are development placeholders to replace before Android release. Revisit iOS setup and its macOS/Xcode requirements when iOS work resumes.

Documentation: https://supabase.com/docs/guides/getting-started/quickstarts/flutter

## Setup validation

- Flutter analysis and both widget tests passed.
- The Dart connection check successfully reached hosted Supabase Auth.
- Flutter doctor passes for Flutter and the Android toolchain after installing command-line tools and accepting SDK licenses.
- The first debug APK build was stopped while Gradle waited for an HTTPS dependency response. APK creation and device launch remain unverified. Retry the build command above when dependency downloads are available.
- Visual Studio is absent; it is only needed for Windows desktop development.
