import {
  BETA_SIGNUP_CONSENT_VERSION,
  BETA_SIGNUP_RETENTION_VERSION,
  type BetaSignupPayload,
  type BetaSignupQueue,
  type BetaSignupQueueRecord,
  type PlatformInterest,
} from "./contracts.js";

const ALLOWED_FIELDS = new Set([
  "email",
  "name",
  "platform",
  "country",
  "notes",
  "consent",
  "consentVersion",
  "retentionVersion",
  "sourceRoute",
  "submittedAtClientMs",
  "website",
]);

const PLATFORMS = new Set<PlatformInterest>(["android", "ios", "both"]);
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export type BetaSignupHandlerOptions = {
  queue: BetaSignupQueue;
  allowedOrigins?: readonly string[];
  minSubmitDelayMs?: number;
  nowMs?: () => number;
};

export type MinimalRequest = AsyncIterable<Buffer | string> & {
  method?: string;
  headers: Record<string, string | string[] | undefined>;
  body?: unknown;
  socket?: {
    remoteAddress?: string;
  };
};

export type MinimalResponse = {
  status(code: number): MinimalResponse;
  setHeader(name: string, value: string): void;
  end(body: string): void;
};

type ValidationResult =
  | { ok: true; payload: BetaSignupPayload; normalizedEmail: string }
  | { ok: false; status: number; error: string; spam?: boolean };

export function createBetaSignupHttpHandler(options: BetaSignupHandlerOptions) {
  const minSubmitDelayMs = options.minSubmitDelayMs ?? 2500;
  const allowedOrigins = new Set(options.allowedOrigins ?? []);
  const nowMs = options.nowMs ?? (() => Date.now());

  return async function betaSignupHandler(
    request: MinimalRequest,
    response: MinimalResponse,
  ): Promise<void> {
    setSecurityHeaders(response);

    if (request.method !== "POST") {
      sendJson(response, 405, { ok: false, error: "method_not_allowed" });
      return;
    }

    if (!isJsonContentType(header(request, "content-type"))) {
      sendJson(response, 415, { ok: false, error: "unsupported_media_type" });
      return;
    }

    const origin = header(request, "origin");
    const host = header(request, "x-forwarded-host") ?? header(request, "host");
    if (!isAllowedOrigin(origin, host, allowedOrigins)) {
      sendJson(response, 403, { ok: false, error: "forbidden" });
      return;
    }

    const body = await readJsonBody(request);
    const validation = validatePayload(body, nowMs(), minSubmitDelayMs);
    if (!validation.ok) {
      const status = validation.spam ? 202 : validation.status;
      sendJson(response, status, {
        ok: validation.spam,
        error: validation.spam ? undefined : validation.error,
      });
      return;
    }

    const submitterKey = submitterKeyFor(request);
    if (await options.queue.hasDuplicate(validation.normalizedEmail, nowMs())) {
      sendJson(response, 202, { ok: true, status: "queued" });
      return;
    }

    if (await options.queue.isRateLimited(submitterKey, nowMs())) {
      sendJson(response, 429, { ok: false, error: "try_later" });
      return;
    }

    await options.queue.enqueue(
      toQueueRecord(validation.payload, validation.normalizedEmail, {
        origin,
        userAgent: header(request, "user-agent"),
        submitterKey,
        nowMs: nowMs(),
      }),
      nowMs(),
    );

    sendJson(response, 201, { ok: true, status: "queued" });
  };
}

function validatePayload(body: unknown, nowMs: number, minSubmitDelayMs: number): ValidationResult {
  const payload = unwrapCallableData(body);
  if (!isRecord(payload)) {
    return { ok: false, status: 400, error: "invalid_request" };
  }

  for (const field of Object.keys(payload)) {
    if (!ALLOWED_FIELDS.has(field)) {
      return { ok: false, status: 400, error: "unknown_field" };
    }
  }

  const honeypot = optionalString(payload.website, 120);
  if (honeypot.invalid) {
    return { ok: false, status: 400, error: "invalid_request" };
  }
  if (honeypot.value) {
    return { ok: false, status: 400, error: "invalid_request", spam: true };
  }

  const submittedAtClientMs = payload.submittedAtClientMs;
  if (
    typeof submittedAtClientMs !== "number" ||
    !Number.isFinite(submittedAtClientMs) ||
    submittedAtClientMs > nowMs + 60_000 ||
    nowMs - submittedAtClientMs < minSubmitDelayMs
  ) {
    return { ok: false, status: 400, error: "invalid_request" };
  }

  const email = requiredString(payload.email, 254);
  if (email.invalid || !EMAIL_PATTERN.test(email.value)) {
    return { ok: false, status: 400, error: "invalid_email" };
  }
  const normalizedEmail = email.value.toLowerCase();

  const name = optionalString(payload.name, 80);
  const country = optionalString(payload.country, 80);
  const notes = optionalString(payload.notes, 500);
  if (name.invalid || country.invalid || notes.invalid) {
    return { ok: false, status: 400, error: "invalid_request" };
  }

  if (typeof payload.platform !== "string" || !PLATFORMS.has(payload.platform as PlatformInterest)) {
    return { ok: false, status: 400, error: "invalid_platform" };
  }
  if (payload.consent !== true) {
    return { ok: false, status: 400, error: "consent_required" };
  }
  if (payload.consentVersion !== BETA_SIGNUP_CONSENT_VERSION) {
    return { ok: false, status: 400, error: "invalid_request" };
  }
  if (payload.retentionVersion !== BETA_SIGNUP_RETENTION_VERSION) {
    return { ok: false, status: 400, error: "invalid_request" };
  }
  if (payload.sourceRoute !== "/beta/") {
    return { ok: false, status: 400, error: "invalid_request" };
  }

  return {
    ok: true,
    normalizedEmail,
    payload: {
      email: email.value,
      ...(name.value ? { name: name.value } : {}),
      platform: payload.platform as PlatformInterest,
      ...(country.value ? { country: country.value } : {}),
      ...(notes.value ? { notes: notes.value } : {}),
      consent: true,
      consentVersion: BETA_SIGNUP_CONSENT_VERSION,
      retentionVersion: BETA_SIGNUP_RETENTION_VERSION,
      sourceRoute: "/beta/",
      submittedAtClientMs,
      website: honeypot.value,
    },
  };
}

function toQueueRecord(
  payload: BetaSignupPayload,
  normalizedEmail: string,
  meta: {
    origin?: string;
    userAgent?: string;
    submitterKey?: string;
    nowMs: number;
  },
): BetaSignupQueueRecord {
  return {
    formType: "beta_signup",
    normalizedEmail,
    email: payload.email,
    ...(payload.name ? { name: payload.name } : {}),
    platform: payload.platform,
    ...(payload.country ? { country: payload.country } : {}),
    ...(payload.notes ? { notes: payload.notes } : {}),
    consentVersion: payload.consentVersion,
    retentionVersion: payload.retentionVersion,
    sourceRoute: payload.sourceRoute,
    status: "pending",
    submittedAtIso: new Date(meta.nowMs).toISOString(),
    requestMeta: {
      ...(meta.origin ? { origin: meta.origin } : {}),
      ...(meta.userAgent ? { userAgent: meta.userAgent } : {}),
      ...(meta.submitterKey ? { submitterKey: meta.submitterKey } : {}),
    },
  };
}

async function readJsonBody(request: MinimalRequest): Promise<unknown> {
  if (request.body !== undefined) {
    return parseBodyValue(request.body);
  }

  let raw = "";
  for await (const chunk of request) {
    raw += typeof chunk === "string" ? chunk : chunk.toString("utf8");
  }
  return parseBodyValue(raw);
}

function parseBodyValue(value: unknown): unknown {
  if (Buffer.isBuffer(value)) {
    return parseBodyValue(value.toString("utf8"));
  }
  if (typeof value === "string") {
    try {
      return JSON.parse(value);
    } catch {
      return undefined;
    }
  }
  return value;
}

function unwrapCallableData(body: unknown): unknown {
  if (!isRecord(body)) {
    return body;
  }
  const keys = Object.keys(body);
  if (keys.length === 1 && keys[0] === "data") {
    return body.data;
  }
  return body;
}

function requiredString(value: unknown, maxLength: number): { value: string; invalid: boolean } {
  if (typeof value !== "string") {
    return { value: "", invalid: true };
  }
  const trimmed = value.trim();
  return {
    value: trimmed,
    invalid: trimmed.length === 0 || trimmed.length > maxLength,
  };
}

function optionalString(value: unknown, maxLength: number): { value?: string; invalid: boolean } {
  if (value === undefined) {
    return { invalid: false };
  }
  if (typeof value !== "string") {
    return { invalid: true };
  }
  const trimmed = value.trim();
  return {
    ...(trimmed ? { value: trimmed } : {}),
    invalid: trimmed.length > maxLength,
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isJsonContentType(value: string | undefined): boolean {
  return value?.split(";")[0]?.trim().toLowerCase() === "application/json";
}

function isAllowedOrigin(
  origin: string | undefined,
  host: string | undefined,
  allowedOrigins: Set<string>,
): boolean {
  if (!origin) {
    return true;
  }
  if (allowedOrigins.has(origin)) {
    return true;
  }
  if (!host) {
    return false;
  }
  try {
    return new URL(origin).host === host;
  } catch {
    return false;
  }
}

function submitterKeyFor(request: MinimalRequest): string | undefined {
  const forwardedFor = header(request, "x-forwarded-for")?.split(",")[0]?.trim();
  return forwardedFor || request.socket?.remoteAddress;
}

function header(request: MinimalRequest, name: string): string | undefined {
  const value = request.headers[name] ?? request.headers[name.toLowerCase()];
  if (Array.isArray(value)) {
    return value[0];
  }
  return value;
}

function setSecurityHeaders(response: MinimalResponse): void {
  response.setHeader("Content-Type", "application/json; charset=utf-8");
  response.setHeader("X-Content-Type-Options", "nosniff");
  response.setHeader("Cache-Control", "no-store");
}

function sendJson(
  response: MinimalResponse,
  status: number,
  body: Record<string, unknown>,
): void {
  response.status(status);
  response.end(JSON.stringify(body));
}
