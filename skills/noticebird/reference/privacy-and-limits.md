# Privacy rules and limits

Every limit here is one an app's own input or config can hit. The client repairs what
it can: a value it can shorten is shortened, a value it can do without is left out and
the rest still goes. What it cannot repair is said per row.

The platform checks every crash event and every feedback report again when they arrive,
and refuses one that is invalid. The client writes each by the protocol's rules, so the
limits below are the ones to keep to.

## Configuration ranges

`NoticebirdConfig` throws `ArgumentError` at construction when a value is out of range,
and so does `NoticebirdFlutter.start`, which passes its `breadcrumbBuffer` (default 100,
the trail of a feedback report) and keeps the other defaults.

| Setting | Default | Allowed |
|---|---|---|
| `maxPendingEvents` | 50 | 0–200 (`0` disables the queue: a failed send becomes `dropped`) |
| `maxBreadcrumbs` | 50 | 0–50 (per event) |
| `breadcrumbBuffer` | `maxBreadcrumbs` | `maxBreadcrumbs`–200 (kept in memory for `recentBreadcrumbs`) |
| `maxDeduplicationEntries` | 100 | 1–1000 |
| `deduplicationWindow` | 1 minute | any non-negative `Duration` |

## Crash events

| Value | Limit | When it breaks the limit |
|---|---|---|
| `AppMetadata` `name` / `version` / `build` / `release` | 1–100 / 1–50 / 1–50 / 1–160 characters | `NoticebirdConfig` and the start throw `ArgumentError`; the start reports `unknown` for a version or build the platform gives that the protocol refuses |
| `PlatformMetadata` `osVersion` / `deviceClass` | 1–100 / 1–100 characters | `NoticebirdConfig` throws `ArgumentError` |
| `sessionIdFactory`'s id | `^[A-Za-z0-9_-]{16,64}$` | every event is `dropped`, every feedback report `FeedbackRejected(failed)` |
| `eventIdFactory`'s id (`NoticebirdClient`) | `^[0-9a-fA-F-]{36}$`; a UUID in the 8-4-4-4-12 shape (such as a UUIDv7) also serves as a feedback report's `relatedEventId` | every event is `dropped` |
| route template (`setRouteTemplate`, `feedbackMoment(routeTemplate:)`) | starts with `/`, at most 200 characters, and passes `NoticebirdClient.isRouteTemplate`: no query or fragment, no id-like segment | throws in a debug build; left out in release |
| `setUser` (`CrashUser`) | at least one field; `id` / `email` / `name` / `ipAddress` 1–100 / 1–254 / 1–200 / 1–45 characters | the user is left out |
| `setUserId` | — | characters outside `[A-Za-z0-9_-]` are stripped, the rest cut to 100 |
| `tags` | `AllowedTag` keys; a string, a finite number or a boolean | strings are redacted and cut to 100 characters (ellipsis included); a NaN or infinite number drops the event |
| breadcrumb `action` | `^[a-z][a-z0-9_.-]*$`, at most 100 characters | the breadcrumb is left out alone: of the event, of a feedback report's trail and of a native crash's trail |
| breadcrumb `data` | `AllowedTag` keys; a string, a finite number or a boolean | strings are redacted and cut to 100 characters; a NaN or infinite number leaves the breadcrumb out alone |
| `groupingKey` | at most 8 parts of at most 100 characters | each part redacted and cut, empty parts left out, the first 8 kept; none left is no key |
| `extra` | below | left out or cut, silently |
| the whole event | 65,536 bytes (64 KiB) of canonical JSON | the event is `dropped`; a large `extra` is the usual cause |

A breadcrumb that is left out costs only itself: before 0.6.0 one bad action
(`Route.Push`) dropped the whole crash event.

### `extra`

`extra` is for small technical context. The client applies these rules before the event
is built, and never drops the event over them:

- at most 20 keys, each `^[A-Za-z][A-Za-z0-9_.-]{0,63}$`; a key that breaks it is left out;
- a value is a string (redacted, cut to 1000 characters), a finite number, a boolean,
  `null`, a list or a map; lists and maps hold at most 20 entries and nest at most two
  levels; any other value, a NaN or infinite number, and anything deeper is left out;
- a key is left out when the protocol's `PrivacyPatterns.extraKeyViolation` names it — it
  is exactly `name` after normalization, or its normalized form contains a credential word,
  a health measure or an identity — or when it contains `fitbit`, `google` or `patient`.
  Normalization lowercases and removes everything outside `a-z0-9`, so `User_ID`,
  `user-id` and `userId` are all caught. The lists live in the protocol (`privacy.dart`).

## Redaction

Applied by the client to messages, the route template, tag strings, grouping key parts,
breadcrumb data strings, `extra` string values and native image names in **every**
privacy profile, when an event is built (the breadcrumb buffer behind `recentBreadcrumbs`
keeps the values as recorded). Each match becomes `[REDACTED]`:

- email addresses
- JWTs (`eyJ…`.`…`.`…`)
- `bearer` / `token` / `secret` / `password` / `api_key` / `authorization` followed by
  `:`, `=` or whitespace, and any of those words at the end of a value
- UUID-shaped hex runs, phone-number-like digit runs, IPv4 addresses
- `glucose`, `ecg`, `electrocardiogram`, `heart rate`, `blood pressure`, `spo2`,
  `diagnosis`, `observation` followed by `:` or `=`

The patterns are built from the protocol's `PrivacyPatterns`. A breadcrumb `action` that
matches one becomes `redacted`. A native image name, whose characters allow no
`[REDACTED]`, has each match replaced by `redacted`. The route template is redacted when
it is set, then cut to its 200 characters.

A function name in a stack frame is respelled rather than redacted, so it keeps its
words: a long digit run is cut, and a name that would read as a secret or an address
changes a separator (`AuthHeader.bearer_`, `Codec.1_2_3_4`). A native symbol also loses
its compiler hash suffixes (`.__uniq.…`, `.llvm.…`), which change with every build.

Redaction is a safety net, not a design. Do not rely on it to scrub a value you chose to
pass — pass a safe value instead.

## Stack frames

`exception.stackTrace` keeps the app's frames only, at most 50, in the VM shape
`#<i> <function> (<location>)`; a trace with none is sent as `<no-app-frames>`:

- a VM frame of a package (`#0 Cubit.load (package:app/cubit.dart:42:7)`), with its own
  number;
- a `package:stack_trace` friendly frame (`package:app/cubit.dart 42:7  Cubit.load`);
- a JavaScript frame of a dart2js build — V8's `at cOy.$0 (https://host/main.dart.js:375562:14)`
  (also anonymous, `async` and `new`) or Firefox's and Safari's
  `cOy.$0@https://host/main.dart.js:375562:14` — in a script named `<name>.dart.js` or
  `<name>.dart.js_<n>.part.js` (a deferred part). It keeps the script's file name alone,
  so no host, path or query leaves the device: `#1 cOy.$0 (main.dart.js:375562:14)`.
  Line and column stay, so the build's source map (`flutter build web --source-maps`)
  can lead them back to the Dart source. A function whose name is not identifiers and
  `<anonymous>` joined by dots is written `<anonymous>`.

A frame the redaction patterns still match (a name holding an e-mail address, a file
named like a phone number) is left out. Every other frame — the SDK's, the engine's,
`canvaskit.js`, `flutter.js`, a browser extension's, another origin's library — is left
out too. The client cuts the message and the stack trace to the protocol's lengths.

A web (dart2js) event without `package:` frames is deduplicated by its type alone; to
group such events yourself, pass a `groupingKey` (`SKILL.md`, Capturing).

In a minified dart2js build every type is named `minified:<id>`; a Dart core error
(`StateError`, `ArgumentError`, `IndexError`, `TimeoutException`, …) is sent under its core
type's name instead, and any other type keeps its minified name.

## What `regulatedStrict` changes

| | other profiles | `regulatedStrict` |
|---|---|---|
| `sanitizedMessage` | sanitized `toString()` | exception type only |
| `extra` | sanitized | `{}` |
| `user` | filtered by `CrashPiiConfig` | `null` |
| tag and breadcrumb strings | redacted and shortened to 100 chars in an event (ellipsis included); `recentBreadcrumbs` keeps them as recorded, up to 1000 | the same |
| `groupingKey` | each part redacted and cut to 100 chars, empty parts left out, the first 8 kept; none left is no key | the same |
| offline store | any | must report `isEncrypted: true` or the config throws |

## Keys

Clients authenticate with a publishable key, `<prefix>_pk_<token>` (`noticebird_pk_…`;
older `crash_pk_…` keys stay valid); `CrashHttpTransport` checks that shape rather than a
fixed prefix and refuses anything else, a secret `…_sk_…` key included, in its
constructor. It sends the key as `Authorization: Bearer <key>`. The project, environment
and privacy profile come from the key, never from the payload. A secret key in a shipped
client is a security incident, not a configuration mistake.

## Feedback reports (`captureFeedback`)

A report is not an event, and its limits are its own. The message, the contact address,
the user context and the related event id are refused: one that breaks its limit throws
`ArgumentError` in a debug build and is `FeedbackRejected(invalidInput, path)` in release,
`path` naming the value at fault. The screenshot and the diagnostics are sanitised
instead: what breaks a limit is left out, the report is sent, and the client's note group
says what went. A value the client fills in itself and the report refuses (a locale, a
route template, a user field, a trail item) is left out.

| Field | Limit |
|---|---|
| `message` | 1–4000 characters after redaction; U+0000 removed, then redacted as an exception message is and cut to 4000 |
| `contactEmail` | 3–254 characters, `^[^@\s]+@[^@\s]+$`, no U+0000 (`FeedbackContact.isValid`) |
| `userContext` | 1–32 keys `^[A-Za-z][A-Za-z0-9_-]{0,63}$`; a value is a string of 1–256 characters, a finite number, a boolean, an array of 1–16 of those, or an object of 1–32 keys holding those (one nested level, never an object in an array); no U+0000 in a key or a string; at most 8 KiB (8,192 bytes) in compact UTF-8 JSON (`FeedbackUserContext.check`) |
| `relatedEventId` | a UUID of any version in the 8-4-4-4-12 hex shape, such as a `CaptureResult.eventId`; the client lowercases it |
| screenshot | one, PNG, JPEG or WebP by its bytes' file signature, at most 5 MiB (5,242,880 bytes); bytes of another type, or more, are left out (`noticebird.screenshot_dropped`) |
| `diagnostics` | at most 16 groups of at most 32 values, keys `^[a-z][a-zA-Z0-9_]{0,63}$`, at most 16 KiB (16,384 bytes) encoded; a value is a boolean, a finite number, a UTC timestamp, a lowercase UUID v4 or a token of 1–64 characters `[A-Za-z0-9_.:+/-]`; an enum is sent as its name, a `DateTime` in UTC. The context groups (the `blocs` group of `noticebird_flutter`) come first, then the host's (the moment's `diagnostics`), whose groups of a context group's name are left out; one group's room is kept for the note. A group or value that breaks a rule is left out and counted (`noticebird.dropped_values`), and the last groups go until the whole fits; a value is never shortened |
| the note group `noticebird` | the client's own: `dropped_values` (how many diagnostics values were left out), `screenshot_dropped`, `moment_taken_at` (when a moment passed in was taken, if before the capture); a host's group of that name is left out |
| locale (`NoticebirdConfig.locale`) | at most 35 characters, a language tag `^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8}){0,3}$` (`nl-NL`); another is left out |
| trail | the newest 100 breadcrumbs of the buffer, redacted as in an event; a breadcrumb the report refuses is left out alone, and the oldest go first until the report fits |
| whole report | 65,536 bytes (64 KiB) encoded |
| reporter assertion | what the host's backend mints: a compact JWS (three base64url parts joined by dots) of 16–4096 characters, `alg` `EdDSA` (Ed25519), its `kid` naming a signing key the project knows; `aud` the project's id; `sub` 1–100 characters, optionally `email` (at most 254) and `name` (at most 200); `iat` and `exp` in seconds, `exp − iat` at most 24 hours; valid at the report's capture time (`iat` at most 5 minutes after it, the capture before `exp`). Another is left out or refused, and the report goes unverified, or is `FeedbackRejected(unverified)` under `requireVerified`. The provider is given 5 seconds; an assertion is held per user (`setUser` / `setUserId`) until 5 minutes before its `exp`, and reports captured at once share one call; without a user, or for a token without a readable `exp`, it is asked for every report; a refusal is not retried |
| submission window | the platform takes a report up to 7 days after it was captured, and none whose capture time is more than 5 minutes ahead of its clock: `FeedbackRejected(clock)`. A kept report older than 7 days is removed unsent (`FeedbackRejection.expired`) |

`userContext` is checked for its shape only and sent as the host gave it: the platform
may drop values it does not keep. Under `regulatedStrict` the client sends no `user`, no
`userContext` and no locale; the reporter assertion, when one is configured, is the one
identity such a report carries.

### Feedback offline queue

| Bound | Value |
|---|---|
| reports kept | 10 (`FeedbackOfflineStore.maxReports`), the oldest evicted first as `FeedbackRejection.evicted` |
| bytes kept | 20 MiB of report JSON and screenshots together (`FeedbackOfflineStore.maxBytes`) |
| age | 7 days (`FeedbackReport.maxAge`), then removed as `FeedbackRejection.expired` |
| retry | the platform's `Retry-After` (at most 7 days), else 30 s doubling to 6 h, less up to a quarter at random |

`FileFeedbackOfflineStore` and `FileCrashOfflineStore`, the stores `NoticebirdFlutter.start`
keeps in the support directory, are unencrypted, so `regulatedStrict` refuses them and the
start keeps none there; on the web their calls throw, so the start keeps none there either.

## Native crash reports (`noticebird_native`)

| Leaves the device | Never leaves the device |
|---|---|
| Kind and source (enums) | Absolute addresses, register values, memory, instruction bytes |
| Mach exception name, signal name, exception code, termination code (hex) | Free-text termination reasons, VM region info |
| Frames of the crashed (or hang-attributed, or ANR main) thread only: image index + offset, or a JVM/system symbol | Other threads, thread names, queue names |
| Per referenced image: file name (basename), debug id, architecture, in-app flag | Full paths, images no frame references |
| Exception class and its sanitized message; an Android abort message (not in `regulatedStrict`) | Tombstone log buffers, process arguments |
| Hang duration, disk-write bytes | Region format, device model beyond `deviceClass`, pid (used on device only), bundle path, TestFlight cohort |
| The crashed run's app/platform metadata, session id, route template, trail (trail not in `regulatedStrict`) | Identity of any kind; `user`, `extra` |

On device: an inbox (≤ 20 reports, ≤ 30 days, deleted on delivery) and a run ledger
(≤ 5 runs, ≤ 16 KB per engine file), app-private and excluded from backups; purged after
three launches without native capture configured. At most 10 reports are delivered per
launch.
