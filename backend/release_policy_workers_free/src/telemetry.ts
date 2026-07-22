const forbidden = /(?:authorization|cookie|secret|token|private.?key|x-hub-signature|body|headers?|stack)/i;
export type Telemetry = Record<string, string | number | boolean | null>;
export function sanitizeTelemetry(input: Telemetry): Telemetry { for (const [key, value] of Object.entries(input)) { if (forbidden.test(key) || (typeof value === "string" && forbidden.test(value))) throw new Error("telemetry field is forbidden"); } return Object.freeze({ ...input }); }
/** 0=healthy, 1=near a configured bound, 2=at/over bound or unmeasurable. */
export function boundedBucket(value: unknown, warning: number, limit: number): 0 | 1 | 2 {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || !Number.isSafeInteger(value) || !Number.isSafeInteger(warning) || !Number.isSafeInteger(limit) || warning < 0 || limit <= warning) return 2;
  return value < warning ? 0 : value < limit ? 1 : 2;
}
export type EgressMetric = "duplicate_check" | "exceeded_resource" | "forbidden_egress" | "provider_error" | "request_high_water" | "status_egress";
export interface EgressMeasurement { metric: EgressMetric; value: number }
