# Contributing

Thanks for helping improve the Noticebird SDK. This repository holds the
client packages only — the pure-Dart `noticebird_protocol` and `noticebird`
client, the Flutter `noticebird_flutter` start and the `noticebird_native`
add-on. Service-side code does not belong here.

## Development setup

The workspace pins its Flutter/Dart toolchain with [`fvm`](https://fvm.app).

```sh
fvm flutter pub get              # resolve the workspace from the repo root
```

Run the checks that CI enforces:

```sh
# pure-Dart protocol package and client
cd packages/noticebird_protocol && fvm dart format --output=none --set-exit-if-changed . && fvm dart analyze && fvm dart test
cd packages/noticebird && fvm dart format --output=none --set-exit-if-changed . && fvm dart analyze && fvm dart test && fvm dart pub publish --dry-run

# Flutter start and its example
cd packages/noticebird_flutter && fvm dart format --output=none --set-exit-if-changed . && fvm flutter analyze && fvm flutter test && fvm flutter pub publish --dry-run
cd packages/noticebird_flutter/example && fvm flutter test

# native add-on and its crash lab
cd packages/noticebird_native && fvm flutter analyze && fvm flutter test
cd packages/noticebird_native/example && fvm flutter test
```

The publish dry-runs need a clean tree.

## Conventions

- All code, comments, docs, and commit messages are in **English**.
- `dart format` must produce no changes; `analyze` must be clean.
- Add or update tests for every behavioral change. Protocol changes need
  compatibility/property coverage; SDK changes need capture, privacy, queue,
  retry, or handler coverage as appropriate.
- Keep the boundary intact: `noticebird_protocol` and `noticebird` stay pure
  Dart (no Flutter import), everything that needs Flutter or `bloc` lives in
  `noticebird_flutter`, and no package depends on a service-side package.
- Preserve the privacy and reliability invariants:
  - the SDK must never crash or hang the host application;
  - never capture secrets, tokens, or regulated/health data — extend the
    sanitizer and privacy profiles instead;
  - clients use publishable ingest keys (`<prefix>_pk_...`, today `noticebird_pk_...`)
    only;
  - route values are templates (`/lists/:listId`), never raw identifiers.

## Commit and pull requests

- Write concise, imperative commit messages (one or two lines).
- One coherent change per pull request; keep unrelated refactors separate.
- CI runs format, analyze, tests, and the repository-boundary scan on every pull
  request; all must pass. A push to `main` or `develop` runs CI only when its
  commit message carries `[ci]`.
- The four packages move together, on one version. User-facing changes
  update the relevant package `CHANGELOG.md`, and releases are published from
  immutable tags — do not bump published versions or move tags in a feature
  pull request.

## License

By contributing you agree that your contributions are licensed under the
repository's [Apache-2.0 License](LICENSE).
