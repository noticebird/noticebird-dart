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
