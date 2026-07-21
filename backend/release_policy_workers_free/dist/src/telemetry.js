const forbidden = /(?:authorization|cookie|secret|token|private.?key|x-hub-signature|body|headers?|stack)/i;
export function sanitizeTelemetry(input) { for (const [key, value] of Object.entries(input)) {
    if (forbidden.test(key) || (typeof value === "string" && forbidden.test(value)))
        throw new Error("telemetry field is forbidden");
} return Object.freeze({ ...input }); }
/** 0=healthy, 1=near a configured bound, 2=at/over bound or unmeasurable. */
export function boundedBucket(value, warning, limit) {
    if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || !Number.isSafeInteger(value) || !Number.isSafeInteger(warning) || !Number.isSafeInteger(limit) || warning < 0 || limit <= warning)
        return 2;
    return value < warning ? 0 : value < limit ? 1 : 2;
}
