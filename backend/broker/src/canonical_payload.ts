import { createHash } from 'node:crypto';

import {
  APPROVED_PAYLOAD_CLASS,
  CURRENT_CANONICAL_PAYLOAD_VERSION,
  CURRENT_PAYLOAD_CONTRACT_VERSION,
  type BrokerRequest,
} from './contracts.js';
import type { BrokerErrorCondition } from './error_contract.js';

export interface CanonicalPayloadResult {
  document: Record<string, unknown>;
  json: string;
  bytes: Buffer;
  sha256: string;
}

export function canonicalPayloadV1(request: BrokerRequest): CanonicalPayloadResult {
  const document = canonicalPayloadDocument(request);
  const json = canonicalizeRfc8785(document);
  const bytes = Buffer.from(json, 'utf8');
  return {
    document,
    json,
    bytes,
    sha256: createHash('sha256').update(bytes).digest('hex'),
  };
}

export function validateCanonicalPayloadV1(request: BrokerRequest): BrokerErrorCondition | undefined {
  if (!isUuid(request.request_id)) {
    return 'invalid_request_id';
  }
  if (request.payload_contract_version !== CURRENT_PAYLOAD_CONTRACT_VERSION) {
    return 'payload_contract_mismatch';
  }
  if (request.approved_payload_class !== APPROVED_PAYLOAD_CLASS) {
    return 'payload_class_mismatch';
  }
  if (!/^[a-f0-9]{64}$/.test(request.payload_hash)) {
    return 'invalid_payload_hash';
  }
  if (request.image.mime_type !== 'image/jpeg' && request.image.mime_type !== 'image/webp') {
    return 'unsupported_image_mime_type';
  }
  if (
    !Number.isSafeInteger(request.image.byte_size) ||
    request.image.byte_size <= 0 ||
    request.image.byte_size > 1_500_000
  ) {
    return 'invalid_image_size';
  }
  if (
    !Number.isSafeInteger(request.image.long_edge_px) ||
    request.image.long_edge_px <= 0 ||
    request.image.long_edge_px > 1600
  ) {
    return 'invalid_image_dimensions';
  }
  if (!isCanonicalBase64(request.image.content_base64, request.image.byte_size)) {
    return 'invalid_image_encoding';
  }
  if (request.consent_scope === 'image_only' && request.draft_hints !== undefined) {
    return 'invalid_request_payload';
  }
  if (containsLoneSurrogate(request)) {
    return 'invalid_unicode';
  }

  try {
    return canonicalPayloadV1(request).sha256 === request.payload_hash
      ? undefined
      : 'payload_hash_mismatch';
  } catch {
    return 'invalid_request_payload';
  }
}

export function canonicalizeRfc8785(value: unknown): string {
  if (value === null) {
    return 'null';
  }
  switch (typeof value) {
    case 'boolean':
      return value ? 'true' : 'false';
    case 'number': {
      if (!Number.isFinite(value)) {
        throw new TypeError('RFC 8785 does not permit non-finite numbers.');
      }
      return JSON.stringify(value);
    }
    case 'string':
      if (hasLoneSurrogate(value)) {
        throw new TypeError('RFC 8785 requires valid Unicode scalar values.');
      }
      return JSON.stringify(value);
    case 'object':
      if (Array.isArray(value)) {
        return `[${value.map(canonicalizeRfc8785).join(',')}]`;
      }
      return `{${Object.keys(value as Record<string, unknown>)
        .sort()
        .map((key) => {
          if (hasLoneSurrogate(key)) {
            throw new TypeError('RFC 8785 requires valid Unicode object keys.');
          }
          const child = (value as Record<string, unknown>)[key];
          if (child === undefined) {
            throw new TypeError('RFC 8785 input must not contain undefined values.');
          }
          return `${JSON.stringify(key)}:${canonicalizeRfc8785(child)}`;
        })
        .join(',')}}`;
    default:
      throw new TypeError('RFC 8785 input must be JSON-compatible.');
  }
}

function canonicalPayloadDocument(request: BrokerRequest): Record<string, unknown> {
  const document: Record<string, unknown> = {
    approved_payload_class: request.approved_payload_class,
    canonical_payload_version: CURRENT_CANONICAL_PAYLOAD_VERSION,
    consent_copy_version: request.consent_copy_version,
    consent_scope: request.consent_scope,
    consent_status: request.consent_status,
    image: {
      byte_size: request.image.byte_size,
      content_base64: request.image.content_base64,
      long_edge_px: request.image.long_edge_px,
      mime_type: request.image.mime_type,
    },
    payload_contract_version: request.payload_contract_version,
  };
  if (request.draft_hints !== undefined) {
    const hints: Record<string, unknown> = {};
    if (request.draft_hints.title_hint !== undefined) {
      hints.title_hint = request.draft_hints.title_hint;
    }
    if (request.draft_hints.artist_hint !== undefined) {
      hints.artist_hint = request.draft_hints.artist_hint;
    }
    if (request.draft_hints.search_terms !== undefined) {
      hints.search_terms = [...request.draft_hints.search_terms];
    }
    document.draft_hints = hints;
  }
  return document;
}

function isCanonicalBase64(value: string, expectedByteSize: number): boolean {
  if (value.length === 0 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) {
    return false;
  }
  const decoded = Buffer.from(value, 'base64');
  return decoded.byteLength === expectedByteSize && decoded.toString('base64') === value;
}

function containsLoneSurrogate(value: unknown): boolean {
  if (typeof value === 'string') {
    return hasLoneSurrogate(value);
  }
  if (Array.isArray(value)) {
    return value.some(containsLoneSurrogate);
  }
  if (typeof value === 'object' && value !== null) {
    return Object.entries(value).some(([key, child]) => hasLoneSurrogate(key) || containsLoneSurrogate(child));
  }
  return false;
}

function hasLoneSurrogate(value: string): boolean {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) {
        return true;
      }
      index += 1;
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      return true;
    }
  }
  return false;
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value);
}
