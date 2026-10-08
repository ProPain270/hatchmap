# hatch_map (Flutter client)

Android client for [HatchMap](../../README.md). It polls the same `topology.json` the macOS
app reads (see `../../SHARED-CONTRACT.md`) and caches the last good payload for offline use.

```bash
flutter pub get
flutter run --dart-define=HATCH_API=https://<your-node>:8443/topology.json
flutter test
```

`build-apk.sh` builds signed split-ABI release APKs and expects an `android/key.properties`
(never committed) that points at your own keystore.
