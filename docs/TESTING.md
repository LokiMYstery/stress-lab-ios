# Validation

Run the Foundation-only policy and analysis tests on macOS:

```sh
swift test
```

Current validation (2026-10-27): 66 core tests passed; the iOS Debug build succeeded. Tests cover HRV analysis, heart-rate trends, main-sleep episode aggregation, notification deduplication and quiet-hour boundaries (23:00–07:00 local time).

Open `StressLab.xcodeproj` in Xcode, choose your development team and run on a physical iPhone to validate HealthKit read access and background updates. Simulator tests cannot prove real HealthKit delivery. Notification submission does not prove visible delivery. Sleep detection remains experimental.

Private device validation history and real health caches are intentionally excluded from the public repository.
