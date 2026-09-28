/** One wall-time budget starts before authentication; no external call retries. */
export class BillingDeadline {
  private invalidated = false;
  cancel(): void { this.invalidated = true; }
  constructor(readonly expiresAt = Date.now() + 55_000) {}
  check(): void {
    if (this.invalidated || Date.now() >= this.expiresAt) throw new Error('billing deadline elapsed');
  }
  async run<T>(operation: () => Promise<T>, maximumMs = 10_000): Promise<T> {
    this.check();
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const result = await Promise.race([
        operation(),
        new Promise<never>((_, reject) => {
          timer = setTimeout(() => { this.cancel(); reject(new Error('billing deadline elapsed')); },
            Math.min(maximumMs, this.expiresAt - Date.now()));
        }),
      ]);
      this.check();
      return result;
    } finally {
      clearTimeout(timer);
    }
  }
}
