# Feedback report v1: the conformance kit

A feedback report is what an app sends when its user reports a bug, an idea
or anything else, optionally with one screenshot. This kit is the contract of
version 1 for an SDK in any language: you build a client from it without the
Dart package.

```
schema/feedback-report.v1.schema.json          the report (JSON Schema 2020-12)
test/fixtures/feedback/v1/valid/*.json         reports a client may send
test/fixtures/feedback/v1/http/*.json          the requests and their answers
test/fixtures/feedback/v1/http/screenshot.png  the bytes the HTTP flow uploads
test/fixtures/feedback/v1/http/other.png       other bytes, for a conflict
```

A client builds only valid reports, so the kit holds no invalid ones: the
corpus of reports the server refuses, with the violation and path of each,
is the platform's, which reads reports. The Dart model,
`package:noticebird_protocol/feedback.dart`, builds reports; it is tested
against the kit (`test/feedback_kit_test.dart`), and so is the schema.

The schema's `$id` (`https://api.noticebird.com/schema/...`) is an
identifier only, not a download URL: nothing is served there. Take the schema
from this kit.

## What an SDK runs in its tests

- **Every valid fixture** validates against the schema. Built from its
  values, a report encodes to the same JSON: compare the decoded JSON, and
  the numbers of `userContext`, `diagnostics` and a trail item's `data` by
  value, where `5`, `5.0` and `5e0` are one number. The other numbers are
  integers, written without a fraction or exponent (rule 8). The fixtures
  write `createdAt` and the trail's `occurredAt` with three fraction digits;
  a writer that writes another number of them compares those timestamps as
  instants.
- **Every report it builds** validates against the schema, and passes the
  rules below. A writer that refuses a report it would build against a rule
  names the rule as the server does.
- **Every HTTP pair**: the client sends the request, and does with the answer
  what the table below says.

A path is a JSON path from the report's root: `$.userContext.plan.tier`,
`$.trail[1].occurredAt`. A violation is one of `invalidJson`,
`unsupportedSchemaVersion`, `unknownField`, `missingField`, `invalidType`,
`invalidValue` and `oversized`; the server returns the same two in its
`400 invalid_report` answer.

## The rules the schema cannot express

The schema is normative for the shape and the limits. These rules are checked
too, and a report that breaks one is refused:

1. No value is `null`: an optional field is left out (`invalidType` at its
   path).
2. Objects and arrays nest at most 8 levels deep (`oversized`).
3. Every number is finite: `1e400` is refused (`invalidValue`).
4. No string, value or key, holds U+0000 (`invalidValue`).
5. `createdAt` and a trail item's `occurredAt` name a moment that exists: no
   13th month, no 25th hour (`invalidValue`).
6. The encoded report is at most 65,536 bytes (`oversized` at `$`), its
   `diagnostics` at most 16,384 bytes (`oversized` at `$.diagnostics`), and its
   `userContext` at most 8,192 bytes in its compact UTF-8 encoding, with every
   number read as a double and written as an integer where that double is
   integral and up to 2^53, so an integer past 2^53 counts as the double it
   reads as (`oversized` at `$.userContext`).
7. A string's length is counted in code points, as JSON Schema counts it,
   except in the fields a report shares with a crash event: `app`,
   `platform.osVersion`, `platform.deviceClass` and the trail count UTF-16
   code units.
8. `schemaVersion`, `attachments[].index` and `attachments[].byteLength`,
   and a slot body's `byteLength`, are written as JSON integers, without a
   fraction or exponent: `68.0` and `6.8e1` are refused (`invalidType`, or
   `unsupportedSchemaVersion` for `schemaVersion`), although the schema's
   `integer` takes them.

And at submission, which is why no fixture depends on the clock:

9. `createdAt` is at most 7 days old and at most 5 minutes in the future.
10. No trail item is later than `createdAt` plus 5 minutes.
11. A project with the `regulatedStrict` privacy profile refuses `user`
    (`$.user`), and then `userContext` (`$.userContext`). A client configured
    for that profile leaves both out.

A client checks `userContext` for its shape and limits only, and sends it as
the host gave it: the platform, not the client, drops the values it may not
keep, such as a credential or a health value, before it stores the report.

To stay within 64 KiB, a client leaves the oldest trail items out first. It
never shortens the message or the diagnostics silently.

## The HTTP pairs

A report goes in at most three requests, each of which can be repeated:

1. `POST /v1/feedback/{reportId}/attachments/0` with `{contentType,
   byteLength, sha256}`, only for a report with a screenshot: the slot. The
   answer says where the bytes go (`uploadUrl`, `uploadMethod`,
   `uploadHeaders`), or that they are stored already (`{"uploaded": true}`).
2. The upload of the bytes, as the slot's answer says.
3. `POST /v1/feedback` with the report: `202` accepted, or `200` for a replay
   of the same report, with the ticket. Show `ticket.display` as it is.

`uploadUrl` is a URI reference, absolute or relative: resolve it against the
URL the slot request was sent to (RFC 3986, section 5), never against the
API's base URL alone, and apply the upload's rules to the result. The platform
answers its own upload route as the relative `0`, the index segment, which
resolves to the slot request's own URL: the upload path is the slot path, so
it keeps the host, port and scheme the client sent to, and a proxy's path
prefix: behind `https://proxy.example.com/noticebird`, the upload goes to
`https://proxy.example.com/noticebird/v1/feedback/{reportId}/attachments/0`.
A server may also answer an absolute URL, such as a signed upload URL of its
storage. The client uploads with `PUT` only, to an `https` URL, or an `http`
one only on the API's own origin when the API itself is `http`, as a local
development server is.

Every request carries the project's publishable key as `Authorization:
Bearer <key>`, and so does the upload when its resolved `uploadUrl` has the
API's own origin: the same scheme, host and port as the API the client sends
to, as it has today. To any other origin the upload goes without it.

A body over its request's limit is answered `413 payload_too_large` before it
is parsed: on its declared `content-length`, or as soon as the bytes read pass
the limit. For a report the limit is 65,536 bytes, so the report of
`http/submit_payload_too_large.json` gets `413` over HTTP; its `oversized` at
`$` (rule 6) is what a writer answers before it would send it. A slot body's
limit is 1,024 bytes, an upload's 5 MiB.

Each file is one request and its answer:

```json
{
  "description": "what the pair shows",
  "given": ["the pairs whose requests came before, in order"],
  "request": {"method": "POST", "path": "/v1/feedback", "headers": {}, "body": {}},
  "response": {"status": 202, "headers": {}, "body": {}}
}
```

`given`, `headers` and `body` are optional. A request names its body inline
(`body`, sent as JSON) or as a file of the kit (`bodyFile`, relative to
`v1/`, sent as its bytes). Every pair assumes a server whose clock reads
`2026-10-29T14:05:00.000Z`, a project with feedback and screenshots switched
on and another privacy profile than `regulatedStrict`, whose first report gets
the ticket `FB-1`; a pair whose `description` names another condition (a
project with feedback off, a spent rate limit, a server without screenshot
storage) assumes that one.

What a client does with each answer:

| Answer | Client |
|---|---|
| `2xx` | delivered |
| `400 invalid_report` + `violation` + `path` | final: drop the report |
| `401 invalid_key`, `origin_not_allowed` | final |
| `401 invalid_reporter_assertion` + `reason` | send the report again once, without its assertion, as unverified; never ask the host for a new assertion. Final instead when the host requires verification |
| `403 feedback_disabled`, `attachments_disabled` | final |
| `404` | final: the path is not canonical; read no body |
| `409 report_conflict`, `attachment_conflict` | final; but `report_conflict` to a slot request says a report is stored under this id already: submit the report (step 3). That answers a replay with its ticket, or `report_conflict` again: a `reportId` is the client's own UUID v4 from a secure random source, so the stored report is its own earlier delivery of this one, which the platform can no longer compare once retention deleted its attachment. The report is delivered then, without a ticket. To a first submit, `report_conflict` stays final |
| `409 attachment_missing` | back to step 1 |
| `411 length_required` | final |
| `413 payload_too_large` | final |
| `415 unsupported_attachment` | final |
| `429 rate_limited` + `Retry-After` | keep the report, retry after `Retry-After` seconds |
| `503 attachments_unavailable`, other `5xx`, no answer | keep the report and back off |
| anything else that is no `2xx` | keep the report and back off |

Final is only what this table names: an `error` code at its own status, and a
`404`, `411`, `413` or `415` with or without one. A `404`'s body is not part
of the contract: the platform may answer one, in plain text, and a client
neither reads nor relies on it. Any other answer did not come from the API as
the table describes it, and a later try may reach it: a `3xx`; a `408`,
`421`, `425` or any other `4xx` the table does not name; a known code at
another status; a gateway's or firewall's page without an `error`, such as a
`403` in HTML. A `Retry-After` that is no whole number of
seconds, or a negative one, counts as missing, and the client waits a
default of its own; `0` means at once.
