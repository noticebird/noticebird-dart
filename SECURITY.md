# Security Policy

This repository contains the Noticebird client packages: the pure-Dart
`noticebird_protocol`, the Flutter `noticebird` SDK and the
`noticebird_native` add-on.

## Supported versions

| Version | Status |
|---|---|
| `noticebird` 0.1.x | Actively supported; receives security and privacy fixes. |

Immutable tags are never moved. Fixes ship as new patch tags.

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

- Preferred: use GitHub's private vulnerability reporting ("Report a
  vulnerability") on this repository, which opens a private security advisory.
- If that is unavailable, contact the maintainers through the private security
  channel listed on the repository profile. (A dedicated security alias is being
  finalized before public publication; until then use private advisories.)

Include the affected package and version, a description, and a minimal
reproduction. Please do not include real end-user data, secrets, or tokens in a
report — a redacted reproduction is sufficient and preferred.

We aim to acknowledge a report within three business days and to agree on a
disclosure timeline once the issue is confirmed.

## Scope and design guarantees

The SDK is built so that reports about the following are expected findings, not
by-design behavior:

- any path by which capture, transport, the offline queue, or flush could crash
  or hang the host application (the SDK guarantees zero-crash behavior);
- any leakage of secrets, tokens, credentials, or regulated/health data through
  a captured event, breadcrumb, tag, or stack frame;
- acceptance of anything other than a publishable ingest key (`<prefix>_pk_...`,
  today `noticebird_pk_...`) by the client transport.

The Noticebird service itself is out of scope for this repository; report a
finding there through the same private channel.

By design, the SDK holds no server credentials and never talks to a database:
the project, environment and privacy profile of an event follow on the server
from its publishable key, never from the event payload.
