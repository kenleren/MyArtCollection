# AI Broker Payload And Telemetry Spec

Status: implemented contract; deployment and collector-content use remain gated
Issues: #51, #177, #187

## Request Boundary

The mobile app may call only the Archivale broker. It must never contain a
provider SDK, provider host, provider key, admin key, or paid-provider request.

The broker request allows only:

- `request_id`: UUID used for idempotency, excluded from canonical hash bytes;
- `consent_status`: `approved`, `declined`, or `missing`;
- `consent_scope`: `image_only` or `image_plus_draft_hints`;
- `consent_copy_version`;
- `payload_contract_version=art-research-payload-v1`;
- `payload_hash`: 64 lowercase SHA-256 hexadecimal characters;
- `approved_payload_class=image_only_or_image_plus_draft_hints`;
- `image.mime_type`: JPEG or WebP;
- `image.byte_size`: 1 through 1,500,000 bytes;
- `image.long_edge_px`: 1 through 1600 pixels;
- `image.content_base64`: canonical padded RFC 4648 base64 without whitespace
  or a data URL prefix;
- optional `draft_hints.title_hint`, `artist_hint`, and ordered
  `search_terms[]`, only under `image_plus_draft_hints` consent.

The decoded base64 byte count must equal `image.byte_size`. Unknown keys, null
optionals, absent image content, non-finite/non-integer dimensions, unsupported
media, or hints under image-only consent fail closed.

The app-side derivative remains responsible for removing EXIF and unrelated
metadata. No local artwork ID, notes, provenance, documents, OCR dump, values,
location, contact details, filenames, paths, device identifiers, tokens, raw
UID, collection context, or local summaries may enter this envelope.

## canonical-payload-v1

`canonical-payload-v1` uses RFC 8785 JSON Canonicalization Scheme bytes.

The canonical document includes:

1. `canonical_payload_version=canonical-payload-v1`
2. consent status, scope, and copy version
3. payload contract version and approved payload class
4. all four image fields, including exact base64 text
5. only present draft-hint members

It excludes `request_id` and `payload_hash`. Object properties are sorted by
RFC 8785 rules. Array order is preserved. Absent optionals are omitted; null is
not accepted. Strings are encoded as UTF-8 without Unicode normalization, so
canonically equivalent composed and decomposed text remains byte-distinct. Lone
surrogates are rejected.

The digest is SHA-256 over the canonical UTF-8 bytes, encoded as exactly 64
lowercase hexadecimal characters. The server recomputes and compares this
digest before reading idempotency state, reserving credit, or configuring a
provider.

Shared cross-language vectors are in
`backend/broker/fixtures/canonical-payload-v1.json`. That fixture is the mobile
#188 integration boundary and must change version if canonical semantics change.

## Provider Boundary

Only after all broker gates pass may the server construct a provider request.
The OpenAI adapter remains service-private and requires one-time broker
authorization tied to the exact request object. It uses:

- Responses API;
- `store=false`;
- hosted `web_search` with required tool use;
- explicit allowlisted professional domains;
- strict JSON Schema output;
- no previous response, background mode, remote MCP, file search, or stateful
  continuation.

The provider receives only the approved image derivative and approved hints.
Provider output is accepted only when its sources are HTTPS, allowlisted,
grounded in returned citations, and referenced consistently by candidates.
Invalid output is terminal and counts as spent because dispatch occurred.

## Success Response

Success returns a normalized completed result containing:

- request ID;
- provider/model/reasoning metadata;
- completion timestamp;
- validated sources;
- cautious candidate attributions;
- comparable-value signals with caveats;
- warnings;
- optional `replayed=true` on durable replay.

The result is a research suggestion, not authenticity proof, attribution
certainty, appraisal, market value, insurance approval, or provenance proof.
User-confirmed facts remain authoritative.

## broker-error-v1

Every protocol, Auth/App Check, consent, entitlement, credit, idempotency,
breaker, durable-state, provider, and output failure uses one body:

```json
{
  "ok": false,
  "error_contract_version": "broker-error-v1",
  "request_id": "optional UUID",
  "status": "rejected",
  "error": {
    "code": "fixed_public_code",
    "message": "fixed safe message",
    "retryable": false,
    "retry_after_seconds": 30
  }
}
```

`request_id` and `retry_after_seconds` are optional. Idempotency conflict uses
`status=conflict`. The exhaustive HTTP/code/message/retry mapping is versioned
in `backend/broker/fixtures/broker-error-v1.json` and checked against source.

Public codes distinguish `not_entitled`, `credits_exhausted`, `rate_limited`,
`request_in_flight`, `request_outcome_unknown`, upstream timeout/refusal/failure,
and invalid output. Token/project details, provider configuration, stack traces,
stage names, and durable internals are never returned.

## Retention And Telemetry

Broker-owned content retention is not permitted. Image bytes, assembled prompt
buffers, and raw provider response bodies must be dropped after the request.
No broker payload, source URL, prompt, response, image, hint, or token may enter
Firebase Analytics, Crashlytics custom data, Performance, logs, screenshots, or
issue evidence.

Allowed durable state is content-minimized:

- one-way quota subject;
- request ID and canonical payload hash;
- versioned lifecycle and credit state;
- fixed terminal error condition or normalized completed response required for
  replay;
- 24-hour `retention_expires_at` cleanup signal;
- aggregate credit and content-free operational counters.

The 24-hour field does not authorize execution changes or automatic redrive.
Operational telemetry, if later approved, may retain only fixed event codes,
coarse latency/status buckets, one-way identifiers, and aggregate counts for at
most 30 days.

`store=false` does not itself establish Zero Data Retention. Collector-content
provider traffic remains blocked until the exact provider org/project and data
handling are accepted under #52 and deployment is approved under #155.

## Evidence

Tests use injected fakes only and cover golden canonical bytes, Unicode and
array ordering, image encoding/size mismatch, hash mismatch, fixed safe errors,
rate-limit default/clamp, no provider setup on prechecks, response grounding,
terminal failure persistence, and secret-safe source boundaries.
