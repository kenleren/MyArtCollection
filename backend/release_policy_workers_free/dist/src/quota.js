export const QUOTA_HARD = 10_000;
export const QUOTA_SENTINEL = 10_001;
const day = 86_400_000;
const names = ["worker_events", "do_fetches", "alarms", "outbound_attempts"];
const empty = (start) => ({ window_start_utc_ms: start, worker_events: 0, do_fetches: 0, alarms: 0, outbound_attempts: 0, total_units: 0, stopped: false });
const valid = (value, start) => {
    if (!value || typeof value !== "object" || Array.isArray(value))
        return false;
    const row = value;
    if (JSON.stringify(Object.keys(row)) !== JSON.stringify(["window_start_utc_ms", ...names, "total_units", "stopped"]) || row.window_start_utc_ms !== start || typeof row.stopped !== "boolean")
        return false;
    if (names.some((key) => !Number.isSafeInteger(row[key]) || row[key] < 0 || row[key] > QUOTA_SENTINEL) || !Number.isSafeInteger(row.total_units) || row.total_units < 0 || row.total_units > QUOTA_SENTINEL)
        return false;
    const sum = names.reduce((total, key) => total + row[key], 0);
    return row.total_units === (sum > QUOTA_HARD ? QUOTA_SENTINEL : sum) && row.stopped === (row.total_units >= QUOTA_HARD);
};
/** Atomic accounting; the operation reaching 10,000 is recorded and denied. */
export function reserveQuota(storage, now, vector) {
    if (!Number.isSafeInteger(now) || now < 0 || names.some((name) => vector[name] !== undefined && (!Number.isSafeInteger(vector[name]) || vector[name] < 0)))
        return { admitted: false, rolloverAt: now + day, record: { ...empty(0), stopped: true } };
    const start = Math.floor(now / day) * day;
    const rollout = start + day + 100;
    return storage.transactionSync(() => {
        const raw = storage.sql.exec("SELECT value_json FROM meta WHERE key='quota/v1'").toArray()[0];
        let record;
        try {
            record = raw === undefined ? empty(start) : JSON.parse(raw.value_json);
        }
        catch {
            return { admitted: false, rolloverAt: rollout, record: { ...empty(start), stopped: true } };
        }
        if (raw !== undefined && record.window_start_utc_ms > start)
            return { admitted: false, rolloverAt: rollout, record: { ...record, stopped: true } };
        if (record.window_start_utc_ms < start)
            record = empty(start);
        else if (!valid(record, start))
            return { admitted: false, rolloverAt: rollout, record: { ...empty(start), stopped: true } };
        const increment = names.reduce((total, name) => total + (vector[name] ?? 0), 0);
        const attempted = Math.min(QUOTA_SENTINEL, record.total_units + increment);
        const next = { ...record };
        for (const name of names)
            next[name] = Math.min(QUOTA_SENTINEL, next[name] + (vector[name] ?? 0));
        next.total_units = attempted > QUOTA_HARD ? QUOTA_SENTINEL : attempted;
        next.stopped = attempted >= QUOTA_HARD;
        storage.sql.exec("INSERT INTO meta(key,value_json) VALUES('quota/v1',?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json", JSON.stringify(next));
        return { admitted: attempted < QUOTA_HARD, rolloverAt: rollout, record: next };
    });
}
