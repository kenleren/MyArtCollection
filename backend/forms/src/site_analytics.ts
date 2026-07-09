import type { MinimalRequest, MinimalResponse } from "./beta_signup.js";

const ALLOWED_FIELDS = new Set(["path", "referrerCategory", "screenBucket"]);
const REFERRER_CATEGORIES = new Set(["direct", "internal", "external"]);
const SCREEN_BUCKETS = new Set(["small", "medium", "large", "unknown"]);

export type SiteReferrerCategory = "direct" | "internal" | "external";
export type SiteScreenBucket = "small" | "medium" | "large" | "unknown";

export type SitePageviewAggregate = {
  date: string;
  path: string;
  referrerCategory: SiteReferrerCategory;
  screenBucket: SiteScreenBucket;
};

export type SitePageviewAggregateStore = {
  incrementPageview(record: SitePageviewAggregate, nowMs: number): Promise<void>;
};

export type SitePageviewHandlerOptions = {
  store: SitePageviewAggregateStore;
  allowedOrigins?: readonly string[];
  nowMs?: () => number;
};

type ValidationResult =
  | { ok: true; record: SitePageviewAggregate }
  | { ok: false; status: number; error: string };

export function createSitePageviewHttpHandler(options: SitePageviewHandlerOptions) {
  const allowedOrigins = new Set(options.allowedOrigins ?? []);
  const nowMs = options.nowMs ?? (() => Date.now());

  return async function sitePageviewHandler(
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
    const forwardedProto = header(request, "x-forwarded-proto");
    if (!isAllowedOrigin(origin, host, forwardedProto, allowedOrigins)) {
      sendJson(response, 403, { ok: false, error: "forbidden" });
      return;
    }

    const validation = validatePayload(await readJsonBody(request), nowMs());
    if (!validation.ok) {
      sendJson(response, validation.status, { ok: false, error: validation.error });
      return;
    }

    await options.store.incrementPageview(validation.record, nowMs());
    sendJson(response, 202, { ok: true });
  };
}

function validatePayload(body: unknown, nowMs: number): ValidationResult {
  const payload = unwrapCallableData(body);
  if (!isRecord(payload)) {
    return { ok: false, status: 400, error: "invalid_request" };
  }

  for (const field of Object.keys(payload)) {
    if (!ALLOWED_FIELDS.has(field)) {
      return { ok: false, status: 400, error: "unknown_field" };
    }
  }

  const path = normalizePath(payload.path);
  if (!path) {
    return { ok: false, status: 400, error: "invalid_path" };
  }

  const referrerCategory = payload.referrerCategory;
  if (
    typeof referrerCategory !== "string" ||
    !REFERRER_CATEGORIES.has(referrerCategory)
  ) {
    return { ok: false, status: 400, error: "invalid_referrer_category" };
  }

  const screenBucket = payload.screenBucket;
  if (typeof screenBucket !== "string" || !SCREEN_BUCKETS.has(screenBucket)) {
    return { ok: false, status: 400, error: "invalid_screen_bucket" };
  }

  return {
    ok: true,
    record: {
      date: new Date(nowMs).toISOString().slice(0, 10),
      path,
      referrerCategory: referrerCategory as SiteReferrerCategory,
      screenBucket: screenBucket as SiteScreenBucket,
    },
  };
}

function normalizePath(value: unknown): string | null {
  if (typeof value !== "string") {
    return null;
  }
  const trimmed = value.trim();
  if (
    trimmed.length === 0 ||
    trimmed.length > 160 ||
    !trimmed.startsWith("/") ||
    trimmed.startsWith("//") ||
    trimmed.includes("?") ||
    trimmed.includes("#") ||
    trimmed.includes("\\") ||
    /[\u0000-\u001f\u007f]/.test(trimmed)
  ) {
    return null;
  }
  if (trimmed === "/") {
    return "/";
  }
  return trimmed.endsWith("/") ? trimmed : `${trimmed}/`;
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

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isJsonContentType(value: string | undefined): boolean {
  return value?.split(";")[0]?.trim().toLowerCase() === "application/json";
}

function isAllowedOrigin(
  origin: string | undefined,
  host: string | undefined,
  forwardedProto: string | undefined,
  allowedOrigins: Set<string>,
): boolean {
  if (!origin) {
    return false;
  }
  if (allowedOrigins.has(origin)) {
    return true;
  }
  if (!host) {
    return false;
  }
  try {
    const originUrl = new URL(origin);
    const protocols = allowedHostProtocols(host, forwardedProto);
    return protocols.some((protocol) => originUrl.origin === `${protocol}://${host}`);
  } catch {
    return false;
  }
}

function allowedHostProtocols(host: string, forwardedProto: string | undefined): string[] {
  const forwarded = forwardedProto?.split(",")[0]?.trim().toLowerCase();
  if (forwarded === "http" || forwarded === "https") {
    return [forwarded];
  }
  if (
    host.startsWith("localhost:") ||
    host === "localhost" ||
    host.startsWith("127.0.0.1:") ||
    host === "127.0.0.1"
  ) {
    return ["http"];
  }
  return ["https"];
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
