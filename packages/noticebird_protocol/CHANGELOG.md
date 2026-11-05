## 0.8.0

Moves with `noticebird` 0.8.0, `noticebird_flutter` 0.8.0 and
`noticebird_native` 0.8.0. A breadcrumb is a message first, with optional
details (protocol v2 of a breadcrumb): the crash event's schema moves to 6, the feedback
report's to 3.

Breaking changes:

- `TypedBreadcrumb({required at, required message, action, category,
  level, details})`: `at` replaces `occurredAt`; `message` is one line of 1–200
  characters; `action` (now `^[a-z][A-Za-z0-9_.-]*$`, at most 100) and
  `category` (`^[a-z][a-z0-9_]*$`, at most 32) are optional strings;
  `level` is an optional `BreadcrumbLevel` (`debug`, `info`, `warning`,
  `error`); `details` (wire key `details`) are extra lines under the step,
  a flat `Map<String, Object>` of at most `maxDetails` (16), names by
  `detailNamePattern` (at most `maxDetailNameLength`, 48), values a finite
  number of at most `maxDetailNumber` (2^53), a boolean or a string by
  `detailStringPattern` (at most `maxDetailStringLength`, 64). A step takes
  at most 512 bytes encoded. Every limit and pattern is a constant on
  `TypedBreadcrumb`, with `isDetailName`, `isDetailValue`,
  `detailEntryText`, `trailBytes` and `encodedBytes`. A character is a UTF-16 code unit, a
  byte a byte of the canonical JSON in UTF-8.
- `PrivacyPatterns.extraKeyViolation` names more identifiers: a key that
  contains `passport`, `nationalid` or `socialsecurity`, and one with `bsn`,
  `ssn` or `iban` as a word of its own (`customerBsn`, `IBAN`; not
  `className`).
- A breadcrumb's message holds no control, invisible or bidirectional
  character (`TypedBreadcrumb.controlPattern`: C0 and C1, U+2028–U+2029,
  U+200B–U+200F, U+2060–U+2064, U+FEFF, U+061C, U+202A–U+202E,
  U+2066–U+2069) and no unpaired surrogate.
  `cutText`, `hasUnpairedSurrogate` and `replaceUnpairedSurrogates` are the
  rules of a text's code units; `clampTagValue` never splits a surrogate
  pair.
- `canonicalJsonEncode` writes a whole double within ±2^53 as an integer
  (`1.0` as `1`, `-0.0` as `0`), as the web does.
- `PrivacyPatterns.extraKeyViolation` also names a key that contains
  `phonenumber`, `mobilenumber` or `mobilephone`, and the keys `phone`,
  `telephone` and `mobile` (not `isPhone` or `microphonePermission`).
- `BreadcrumbCategory` and `TypedBreadcrumb.clamped` are removed;
  `AllowedTag`, `isTagValue` and `clampTagValue` are an event's `tags`
  only.
- `CrashEvent.schemaVersion` is 6: the breadcrumbs take at most
  `CrashEvent.maxBreadcrumbsBytes` (16 KiB) together, and an event may
  carry `breadcrumbDrops` (`BreadcrumbDrops(detailsDropped:,
  stepsDropped:)`: what the client left out of its breadcrumbs).
- `FeedbackReport.schemaVersion` is 3: its trail takes at most
  `FeedbackReport.maxTrailBytes` (32 KiB), and `checkTrailItem` checks
  `at`.

## 0.7.0

Moves with `noticebird` 0.7.0, `noticebird_flutter` 0.7.0 and
`noticebird_native` 0.7.0. The feedback report's schema moves to 2; the
crash event's (5) is unchanged.

Breaking changes:

- A feedback report no longer carries a reporter assertion:
  `FeedbackReport.reporterAssertion` is removed, with its constructor
  parameter and `minReporterAssertionLength`, `maxReporterAssertionLength`
  and `reporterAssertionPattern`. A report's reporter is who the app says
  its user is (`user`), as the app gives it.
- `FeedbackReport.schemaVersion` is 2, and `toJson` writes it. The platform
  takes reports of schema 2 only: a client before 0.7.0 has its feedback
  refused as `invalid_report`.

Changes:

- `FeedbackUser` and `FeedbackUserContext` say that each is as the app
  gives it: nothing checks that it is true.

## 0.6.0

Moves with `noticebird` 0.6.0, `noticebird_flutter` 0.6.0 and
`noticebird_native` 0.6.0. The crash event's schema (5) and the feedback
report's (1) are unchanged.

Breaking changes:

- Removed the rules no client needs, neither to repair a value, for privacy
  nor to bound a payload:
  - `CrashEvent.maxTags` and `TypedBreadcrumb.maxDataTags`: a map of tags
    holds each `AllowedTag` once at most, so no event reached them;
  - `CrashEvent.userId`, `CrashEvent.userIdPattern` and the rule that `user`
    and `userId` are never both set. `toJson` no longer writes a `userId`;
    no client set one. An event names its user with `user` (`CrashUser`).
- The feedback conformance kit leaves the package: the report's JSON Schema
  and its README (`schema/`), with the platform's table of answers, and the
  fixtures of its valid reports and HTTP answers (`test/fixtures/feedback/`),
  and with them the dev dependency on `json_schema`. The report's rules are
  its writer's, `toJson` and `toJsonString`.

Changes:

- `isTagValue` answers whether a value is one a tag or a breadcrumb's data
  takes, by the rule `toJson` checks: a string of at most
  `maxTagValueLength` characters, a finite number or a boolean. A client
  leaves out a tag that is none, rather than lose the event.
- The README says what a client builds with the package, and no longer how
  the platform reads, groups or judges an event.
- The dartdoc says what each value means for a client, not how the platform
  handles it: `PrivacyViolation` and `PrivacyPatterns` are what a client
  redacts from technical text (identity sent on purpose, such as
  `CrashUser.email`, is not), `CrashUser` holds no medical data or
  credentials in any profile, `nativeStackTraceMarker` keeps native frames
  out of the stack trace text, where they would read as identifiers, and
  `groupingKey` groups every event with the same parts into one issue.
- The unused `crypto` dev dependency is dropped.

## 0.5.0

Moves with `noticebird` 0.5.0 and `noticebird_flutter` 0.5.0; no change of
its own. The crash event's schema (5) and the feedback report's (1) are
unchanged.

## 0.4.0

Moves with `noticebird` 0.4.0 and the new `noticebird_flutter` 0.4.0; no
change of its own. The crash event's schema (5) and the feedback report's (1)
are unchanged.

## 0.3.0

Moves with `noticebird` 0.3.0. The crash event's schema (5) and the
feedback report's (1) are unchanged.

Breaking changes:

- `package:noticebird_protocol/noticebird_protocol.dart` holds what a client
  needs to build and send a crash event; reading one, grouping it into an
  issue and judging what it carries are the platform's. Removed:
  - `CrashEvent.fromJson`, `fromJsonString`, `sourceSchemaVersion` and
    `minSupportedSchemaVersion`, and `validateCrashEventJson` with the
    reading of schema versions 1–4 and of unknown fields;
  - `parseTags` and `parseExtra`, and the `fromJson` of `AppMetadata`,
    `PlatformMetadata`, `CrashUser`, `CrashException`, `TypedBreadcrumb`,
    `NativeImage`, `NativeFrame` and `NativeCrashInfo`;
  - `crashFingerprint` and `canonicalFingerprintSources`, the platform's
    grouping;
  - `privacyViolation`, the platform's privacy verdict. `PrivacyPatterns`
    and the `PrivacyViolation` categories its `extraKeyViolation` sorts a
    key into stay: a client redacts by them.
- `CrashEvent.toJson` and `toCanonicalJson` write schema 5 only and refuse
  what they refused before, by the rules of each value they write, the
  64 KiB of the encoded event included.
- The fixtures of schemas 1–4 leave the package; `test/fixtures/v5_event.json`
  stays.
- The package no longer depends on `crypto`.
- `package:noticebird_protocol/feedback.dart` holds what a client needs to
  build a report; reading one is the platform's. Removed:
  `FeedbackReport.fromJson`, `fromJsonString`, `checkSubmission` and
  `withContent`; `FeedbackAttachmentRef.slotFromJsonString` and `sameAs`;
  `FeedbackUserContext.without`; `FeedbackContentType.byMimeType`; and
  `normalizeJsonNumbers`. `toJson`, `toJsonString` and `toSlotJson` refuse
  what they refused before, by the rules of each value they write, the
  64 KiB of the encoded report included.
- `FeedbackDiagnostics.build` refuses a value with a `ProtocolException`
  whose path names it within the report (`$.diagnostics.sync.note`), as
  `FeedbackUserContext.check` does, instead of an `ArgumentError`.
- `UserReport`, the exception type of `noticebird`'s removed
  `captureUserReport`, is removed.
- The conformance kit's invalid fixtures and their `expectations.json`
  leave the package: a client builds only valid reports, and the corpus of
  reports the server refuses is the platform's. The HTTP pairs
  `submit_invalid_report` and `submit_payload_too_large` carry their
  request bodies inline.

New:

- The checks of a crash event's value a client sets before an event is
  built, each refusing with the violation and path `toJson` refuses it
  with: `AppMetadata.check`, `PlatformMetadata.check`, `CrashUser.check`,
  `TypedBreadcrumb.check` and `NativeCrashInfo.check`.
- Every limit and pattern of a crash event's field is named:
  `CrashEvent.eventIdPattern`, `sessionIdPattern`, `maxRouteTemplateLength`,
  `userIdPattern`, `maxTags`, `maxExtraEntries`, `maxExtraDepth`,
  `maxExtraStringLength` and `extraKeyPattern`; `CrashException.maxTypeLength`,
  `maxMessageLength` and `maxStackTraceLength`; `AppMetadata.maxNameLength`,
  `maxVersionLength`, `maxBuildLength` and `maxReleaseLength`;
  `PlatformMetadata.maxOsVersionLength` and `maxDeviceClassLength`;
  `CrashUser.maxIdLength`, `maxEmailLength`, `maxNameLength` and
  `maxIpAddressLength`; `TypedBreadcrumb.maxActionLength`, `actionPattern`
  and `maxDataTags`; `NativeImage.maxNameLength`, `namePattern` and
  `debugIdPattern`; `NativeFrame.maxSymbolLength` and `symbolPattern`; and
  `NativeCrashInfo.machExceptionPattern`, `signalPattern` and
  `hexCodePattern`.
- The checks of a single value a client fills in itself, each refusing with
  the violation and path the server answers: `FeedbackReport.checkContactEmail`,
  `checkLocale`, `checkRouteTemplate` and `checkTrailItem` (a trail item,
  against the report's `createdAt`), and `FeedbackReport.isUtcTimestamp`.
- Every limit and pattern of a field a client writes is named:
  `FeedbackReport.minContactEmailLength`, `maxContactEmailLength`,
  `contactEmailPattern`, `maxLocaleLength`, `localePattern`,
  `maxRouteTemplateLength`, `routeTemplatePattern`, `sessionIdPattern`,
  `minReporterAssertionLength`, `maxReporterAssertionLength` and
  `reporterAssertionPattern`; `FeedbackAttachmentRef.sha256Pattern`;
  `FeedbackUser.maxIdLength`, `minEmailLength`, `maxEmailLength` and
  `maxNameLength`; and `FeedbackDiagnostics.keyPattern` and `tokenPattern`.

The conformance kit's README states the client's side more exactly:

- a client checks `userContext` for its shape and limits only and sends it
  as the host gave it: the platform drops the values it may not keep;
- a refused reporter assertion (`401 invalid_reporter_assertion`) is not
  asked for again: the report is sent once more without it, unverified, or
  is final when the host requires verification;
- `report_conflict` to a slot request means a report is stored under its id
  already: the client submits the report, which answers a replay with its
  ticket, or `report_conflict` again, which delivers the report without a
  ticket, since the stored report is the client's own earlier delivery that
  the platform can no longer compare once retention deleted its attachment;
  to a first submit, `report_conflict` stays final;
- a `404`'s body is not part of the contract;
- as since 0.2.0, the slot's `uploadUrl` may be relative, and is resolved
  against the URL of the slot request, never against the API's base URL
  alone.

The descriptions of the HTTP pairs `submit_invalid_reporter_assertion`,
`slot_not_found_index`, `slot_not_found_report_id` and `slot_report_conflict`
follow; their requests and answers are unchanged.

## 0.2.0

- The feedback report, schema version 1, in a library of its own,
  `package:noticebird_protocol/feedback.dart`: `FeedbackReport` with its
  kinds, triggers, screenshot reference, unverified user, user context and
  diagnostics values; `fromJson`/`fromJsonString`, which fail closed, and
  `toJson`/`toJsonString`, which validate before they return (64 KiB
  included); `checkSubmission` for the rules that depend on the moment and
  the project; `FeedbackUserContext.check` and `FeedbackDiagnostics.build`
  for a host's own values; `FeedbackContentType.matches` for a screenshot's
  file signature; and `normalizeJsonNumbers`.
- The feedback report's conformance kit for SDKs in other languages: the JSON
  Schema (`schema/feedback-report.v1.schema.json`), valid and invalid
  fixtures with their expected violation and path, and the HTTP requests and
  answers of a report's delivery (`test/fixtures/feedback/v1/`), described in
  `schema/README.md`.

## 0.1.0

First public release.
