export class PlaceholderCreditLedger {
  reserveCount = 0;
  finalizeCount = 0;
  releaseCount = 0;

  reserve(): void {
    this.reserveCount += 1;
  }

  finalize(): void {
    this.finalizeCount += 1;
  }

  release(): void {
    this.releaseCount += 1;
  }
}
