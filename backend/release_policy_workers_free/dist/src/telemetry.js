const forbidden = /(?:authorization|cookie|secret|token|private.?key|x-hub-signature|body|headers?|stack)/i;
export function sanitizeTelemetry(input) { for (const [key, value] of Object.entries(input)) {
    if (forbidden.test(key) || (typeof value === "string" && forbidden.test(value)))
        throw new Error("telemetry field is forbidden");
} return Object.freeze({ ...input }); }
