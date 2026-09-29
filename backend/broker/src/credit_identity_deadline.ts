/** One invocation budget; a retry may not extend its persisted registration owner. */
export class CreditIdentityDeadline {
    readonly signal: AbortSignal;
    constructor(readonly expiresAt = Date.now() + 50000, private readonly now: () => number = Date.now, private readonly controller = new AbortController()) { this.signal = controller.signal; }
    bounded(maximumMs: number, cap = this.expiresAt): CreditIdentityDeadline { return new CreditIdentityDeadline(Math.min(this.expiresAt, cap, this.now() + maximumMs), this.now, this.controller); }
    cancel(): void { this.controller.abort(); }
    check(cap = this.expiresAt): void {
        if (this.signal.aborted || this.now() >= Math.min(cap, this.expiresAt)) {
            this.cancel();
            throw new Error('credit identity unavailable');
        }
    }
    async run<T>(operation: () => Promise<T>, maximumMs = 50000, cap = this.expiresAt): Promise<T> {
        const expiry = Math.min(this.expiresAt, cap, this.now() + maximumMs);
        this.check(expiry);
        let timer: ReturnType<typeof setTimeout> | undefined;
        let abort!: () => void;
        try {
            return await Promise.race([Promise.resolve().then(() => { this.check(expiry); return operation(); }).then(result => { this.check(expiry); return result; }), new Promise<never>((_, reject) => {
                    abort = () => reject(new Error('credit identity unavailable'));
                    this.signal.addEventListener('abort', abort, {
                        once: true
                    });
                    timer = setTimeout(() => { this.cancel(); }, expiry - this.now());
                })]);
        }
        finally {
            clearTimeout(timer);
            this.signal.removeEventListener('abort', abort);
        }
    }
}
