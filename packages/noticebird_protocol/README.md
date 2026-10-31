# noticebird_protocol

Pure-Dart protocol package for Noticebird's crash events and feedback
reports: what a client needs to build and send one. `noticebird` writes them
with it, and re-exports it. It intentionally has no Flutter, HTTP, storage,
or UI dependency.

It provides typed metadata, the named limits and patterns of the fields a
client writes, canonical JSON, a writer that checks an event before it
returns it (`toJson`, `toCanonicalJson`, at most 64 KiB), the checks of a
single value (`AppMetadata.check`, `PlatformMetadata.check`,
`CrashUser.check`, `TypedBreadcrumb.check`, `NativeCrashInfo.check`), and
the `PrivacyPatterns` a client redacts by.

A crash event carries allowlisted scalar tags, typed breadcrumbs, bounded
free-form `extra` context, a bounded explicit `user` object, an optional,
fully enumerated `native` block for crashes the operating system reported
about an earlier run (frames as image offsets, never absolute addresses),
and an optional `groupingKey`, the app's own grouping of an event. A client
writes the current schema version. The project, environment, and privacy
profile are not accepted from event payloads; they come from the key.

The feedback report has a library of its own,
`package:noticebird_protocol/feedback.dart`, so its names never meet an
app's own feedback types through the main import. It holds the model, the
named limits and patterns of its fields, a writer that checks the report
before it returns it (`toJson`, `toJsonString`, at most 64 KiB), the checks
of a single value (`FeedbackReport.checkContactEmail`, `checkLocale`,
`checkRouteTemplate`, `checkTrailItem`), and the checks of a host's own
values, `FeedbackUserContext.check` and `FeedbackDiagnostics.build`.

The platform checks every event and report again when it arrives.
