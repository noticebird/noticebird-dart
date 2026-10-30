# Privacy rules and hard limits

Every number here is enforced. A violation drops the event (`CaptureOutcome.dropped`)
rather than truncating it, except where this file says the value is silently stripped.

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

## Field limits

| Field | Limit |
|---|---|
| `eventId` | `^[0-9a-fA-F-]{36}$` |
| `sessionId` | `^[A-Za-z0-9_-]{16,64}$` |
| `exception.type` | 160 chars (truncated by the client) |
| `exception.sanitizedMessage` | 512 chars |
| `exception.stackTrace` | 32768 chars, max 50 frames |
| `routeTemplate` | starts with `/`, max 200 chars |
| `app.name` / `version` / `build` / `release` | 100 / 50 / 50 / 160 |
| `platform.osVersion` / `deviceClass` | 100 / 100 |
| `userId` (legacy) | `^[A-Za-z0-9_-]{1,100}$` |
| `user.id` / `email` / `name` / `ipAddress` | 100 / 254 / 200 / 45 |
| `tags` | 20 entries, string values 100 chars, numbers must be finite |
| breadcrumb `data` | 8 entries |
| breadcrumb `action` | `^[a-z][a-z0-9_.-]*$`, 100 chars |
| `breadcrumbs` | 50 entries |
| `extra` | 20 fields, keys `^[A-Za-z][A-Za-z0-9_.-]{0,63}$` |
| `extra` values | strings 1000 chars, lists/maps 20 entries, nesting under 2 levels, numbers must be finite |
| whole envelope | 65536 bytes of canonical JSON |

`user` and the legacy `userId` can never both be present.

## Redaction

Applied by the client to messages, the route template, tag strings, grouping key
parts, breadcrumb data strings, `extra` string values and native image names in **every** privacy profile, when an event is built (the breadcrumb buffer
behind `recentBreadcrumbs` keeps the values as recorded). Each match becomes `[REDACTED]`:

- email addresses
- JWTs (`eyJ…`.`…`.`…`)
- `bearer` / `token` / `secret` / `password` / `api_key` / `authorization` followed by
  `:`, `=` or whitespace
- any of those keywords at the end of a value (the platform's firewall reads an event's
  values as one text and would take the next value as its secret)
- UUID-shaped hex runs, phone-number-like digit runs, IPv4 addresses
- `glucose`, `ecg`, `electrocardiogram`, `heart rate`, `blood pressure`, `spo2`,
  `diagnosis`, `observation` followed by `:` or `=`

The patterns are built from the protocol's `PrivacyPatterns`, the ones the platform's
privacy firewall scans an event with and rejects a whole event by; the
client adds the wider forms above (any whitespace after a credential word, any UUID-shaped
run, a health value up to the next separator). A breadcrumb `action` that matches one becomes
`redacted`. A native image name, whose characters allow no `[REDACTED]`, has each match
replaced by `redacted`. The route template is redacted when it is set (and again when a
native report carries the one its run recorded), then cut to its 200 characters.

A frame symbol — a native frame's, or the function name of a Dart or web stack frame —
is respelled, not redacted, so it keeps every word: a run of ten digits is cut to nine, a
symbol that reads as a credential assignment (`auth::token::`) spells its namespaces with
dots, a dotted IPv4- or JWT-shaped run its dots with underscores (`Codec.1_2_3_4`), and a
symbol ending in a credential word gets an underscore after it (`AuthHeader.bearer_`),
since the firewall would take the next value as its secret. A native symbol first loses
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

Every kept frame, whatever its shape, has its function name respelled as a frame symbol
(see Redaction): `#0 AuthHeader.bearer (package:app/a.dart:1:2)` would have the firewall
take the location as a bearer token, so it is sent as
`#0 AuthHeader.bearer_ (package:app/a.dart:1:2)`. A frame the redaction patterns still
match (a name holding an e-mail address, a file named like a phone number) is left out.

Every other frame — the SDK's, the engine's, `canvaskit.js`, `flutter.js`, a browser
extension's, another origin's library — is left out.

A web (dart2js) event without `package:` frames is deduplicated by its type alone; to
group such events yourself, pass a `groupingKey` (`SKILL.md`, Capturing).

In a minified dart2js build every type is named `minified:<id>`; a Dart core error
(`StateError`, `ArgumentError`, `IndexError`, `TimeoutException`, …) is sent under its core
type's name instead, and any other type keeps its minified name.

## Dropped `extra` keys

A key is dropped **silently** (the rest of the event is still sent) when the protocol's
`PrivacyPatterns.extraKeyViolation` names it — it is exactly `name` after normalization, or
its normalized form contains a credential word, a health measure or an identity — or when it
contains `fitbit`, `google` or `patient`, which the client drops on top. The lists live
in the protocol (`privacy.dart`); read them there rather than from a copy here.

Normalization lowercases and removes everything outside `a-z0-9`, so `User_ID`, `user-id`
and `userId` are all caught. Values that are not `String`, `num`, `bool`, `null`, `List`
or `Map` are dropped the same way, as are non-finite numbers and anything nested deeper
than two levels.

## What `regulatedStrict` changes

| | other profiles | `regulatedStrict` |
|---|---|---|
| `sanitizedMessage` | sanitized `toString()` | exception type only |
| `extra` | sanitized | `{}` |
| `user` | filtered by `CrashPiiConfig` | `null` |
| tag and breadcrumb strings | redacted and shortened to 100 chars in an event (ellipsis included); `recentBreadcrumbs` keeps them as recorded, up to 1000 | the same |
| `groupingKey` | each part redacted and cut to 100 chars, empty parts left out, the first 8 kept; none left is no key | the same |
| offline store | any | must report `isEncrypted: true` or the config throws |

## Server-side invariants

The project, environment and privacy profile are derived from the ingest key on the
server and are **never** read from the payload. Clients authenticate with a publishable
key, `<prefix>_pk_<token>` (`noticebird_pk_…`; older `crash_pk_…` keys stay valid); `CrashHttpTransport` checks that shape
rather than a fixed prefix and refuses anything else, a secret `…_sk_…` key included,
in its constructor. It sends the key as `Authorization: Bearer <key>`. A
secret key in a shipped client is a security incident, not a configuration mistake.

## Feedback reports (`captureFeedback`)

A report is not an event, and its limits are its own. The message, the contact address,
the user context and the related event id are refused: one that breaks its limit throws
`ArgumentError` in a debug build and is `FeedbackRejected(invalidInput, path)` in release.
The screenshot and the diagnostics are sanitised instead: what breaks a limit is left out,
the report is sent, and the client's note group says what went.

| Field | Limit |
|---|---|
| `message` | 1–4000 characters after redaction; U+0000 removed, then redacted as an exception message is and cut to 4000 |
| screenshot | one, PNG, JPEG or WebP by its bytes' file signature, at most 5 MiB (5,242,880 bytes); bytes of another type, or more, are left out (`noticebird.screenshot_dropped`) |
| trail | the newest 100 breadcrumbs of the buffer, redacted as in an event; the oldest left out first until the report fits |
| `diagnostics` | at most 16 groups of at most 32 values, keys `^[a-z][a-zA-Z0-9_]{0,63}$`, at most 16 KiB (16,384 bytes) encoded; a value is a boolean, a finite number, a UTC timestamp, a lowercase UUID v4 or a token of 1–64 characters `[A-Za-z0-9_.:+/-]`; an enum is sent as its name, a `DateTime` in UTC. The context groups (the `blocs` group of `noticebird_flutter`) come first, then the host's (the moment's `diagnostics`), whose groups of a context group's name are left out; one group's room is kept for the note. A group or value that breaks a rule is left out and counted (`noticebird.dropped_values`), and the last groups go until the whole fits; a value is never shortened |
| the note group `noticebird` | the client's own: `dropped_values` (how many diagnostics values were left out), `screenshot_dropped`, `moment_taken_at` (when a moment passed in was taken, if before the capture); a host's group of that name is left out |
| `userContext` | 1–32 keys `^[A-Za-z][A-Za-z0-9_-]{0,63}$`; a value is a string of 1–256 characters, a finite number, a boolean, an array of 1–16 of those, or an object of 1–32 keys holding those (one nested level, never an object in an array); at most 8 KiB (8,192 bytes) in compact UTF-8 JSON |
| `contactEmail` | 3–254 characters, an address the report accepts (`FeedbackContact.isValid`) |
| whole report | 65,536 bytes (64 KiB) encoded |
| reporter assertion | the provider is given 5 seconds; an assertion is held per user (`setUser` / `setUserId`) until 5 minutes before its `exp`, and reports captured at once share one call; without a user, or for a token without a readable `exp`, it is asked for every report; a refusal is not retried |

`userContext` is checked for its shape only and sent as the host gave it: the platform
drops the credential and health values it may not keep, before it stores the report.
Under `regulatedStrict` the client sends no `user`, no `userContext` and no locale; the
reporter assertion, when one is configured, is the one identity such a report carries.

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
| The crashed run's app/platform metadata, session id, route template, trail (trail not in `regulatedStrict`) | Identity of any kind; `user`, `userId`, `extra` |

On device: an inbox (≤ 20 reports, ≤ 30 days, deleted on delivery) and a run ledger
(≤ 5 runs, ≤ 16 KB per engine file), app-private and excluded from backups; purged after
three launches without native capture configured. Per record: ≤ 64 frames, ≤ 32 images,
≤ 10 delivered per launch.

