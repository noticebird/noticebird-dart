# noticebird_protocol

Pure-Dart protocol package for versioned crash event envelopes: what a
client needs to build and send one. It provides typed metadata, the named
limits and patterns of every field, canonical JSON, a writer that validates
an event before it returns it (`toJson`, `toCanonicalJson`, at most 64 KiB),
the checks of a single value (`AppMetadata.check`, `PlatformMetadata.check`,
`CrashUser.check`, `TypedBreadcrumb.check`, `NativeCrashInfo.check`), and
the `PrivacyPatterns` a client redacts by. Reading an event, grouping it
into an issue and the privacy firewall are the platform's. It intentionally
has no Flutter, HTTP, Supabase, storage, or UI dependency.

The crash event's schema 5 supports allowlisted scalar tags, typed
breadcrumbs, bounded free-form `extra` context, a bounded explicit `user`
object, an optional, fully enumerated `native` block for crashes the
operating system reported about an earlier run (frames as image offsets,
never absolute addresses), and an optional `groupingKey`, the app's own
grouping of an event. A client writes schema 5 only. The project,
environment, and privacy profile are not accepted from event payloads; the
service derives them from the credential.

The feedback report, schema version 1, has a version line of its own and a
library of its own, `package:noticebird_protocol/feedback.dart`, so its names
never meet an app's own feedback types through the main import. It holds
what a client needs to build a report: the model, the named limits and
patterns of its fields, a writer that validates the report before it returns
it (`toJson`, `toJsonString`, at most 64 KiB), the checks of a single value
(`FeedbackReport.checkContactEmail`, `checkLocale`, `checkRouteTemplate`,
`checkTrailItem`), and the checks of a host's own values,
`FeedbackUserContext.check` and `FeedbackDiagnostics.build`. Reading a report
is the platform's.

The report's contract for any language is the conformance kit next to it:
the JSON Schema in `schema/`, the valid fixtures and the HTTP pairs of its
three requests in `test/fixtures/feedback/v1/`. `schema/README.md` says how an
SDK in another language uses it.
