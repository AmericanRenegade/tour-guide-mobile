# Tour Guide Mobile App — Agent Instructions

## CI/CD: Automated Android Builds via GitHub Actions

**All Android builds are offloaded to GitHub Actions.** Do not ask the user to build locally.

### How it works
1. Every push to any branch triggers `.github/workflows/build-android.yml`
2. GitHub Actions builds a release APK (~8-12 min on free-tier Linux runners)
3. The APK is uploaded as a GitHub artifact (retained 30 days)
4. If Firebase App Distribution is configured, the APK is automatically delivered to the user's Pixel 6 Pro — no USB required

### Manual trigger
Builds can also be triggered manually from the GitHub Actions tab (`workflow_dispatch`).

### Firebase config in CI
Two gitignored files are restored from GitHub Secrets during CI:
- `android/app/google-services.json` → secret `GOOGLE_SERVICES_JSON` (base64-encoded)
- `lib/firebase_options.dart` → secret `FIREBASE_OPTIONS_DART` (base64-encoded)

These are base64-encoded in secrets. The workflow decodes them at build time.

### Firebase App Distribution
When the `FIREBASE_SERVICE_ACCOUNT` secret is set, builds are automatically distributed to the `testers` group in Firebase App Distribution. The user receives a notification on their device and can install directly.

### Required GitHub Secrets
| Secret | Description |
|--------|-------------|
| `GOOGLE_SERVICES_JSON` | base64-encoded `android/app/google-services.json` |
| `FIREBASE_OPTIONS_DART` | base64-encoded `lib/firebase_options.dart` |
| `FIREBASE_SERVICE_ACCOUNT` | (Optional) Firebase service account JSON for App Distribution |

### Important notes
- Builds are always `--release`, never debug
- The app currently uses debug signing keys for release builds (fine for sideloading, not for Play Store)
- Target device: Pixel 6 Pro (device ID `1C141FDEE003R1`)
- Firebase project: `fc-tour-guides`
- Android App ID: `1:940376231423:android:1f50b66135f3a7f0c5abca`

## Project Basics
- Flutter app: `pubspec.yaml` at repo root
- Application ID: `com.example.tour_guide`
- Backend: Railway at `https://tour-guide-backend-production.up.railway.app`
- 5-tab BottomNavigationBar: Now Playing, Tour Guides, Simulate, Settings, Admin
