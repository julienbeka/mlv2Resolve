# Project conventions

- Increment the app patch version for every correction delivered to the user, including local builds. A build-number-only increment is insufficient.
- Keep `MARKETING_VERSION` in `app/project.yml` and the default version in `scripts/build-app.sh` synchronized. Update release notes for the correction.
- Rebuild the local app after changing the version and verify `CFBundleShortVersionString` in `build/mlv2Resolve.app/Contents/Info.plist` before sharing it.
