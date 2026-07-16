export type FailureCode =
  | "ambiguous_api"
  | "cas_lost"
  | "conflict"
  | "identity"
  | "invalid_input"
  | "overflow"
  | "protected_path"
  | "snapshot_race"
  | "store_failure";

export class FailClosedError extends Error {
  constructor(readonly code: FailureCode, message: string) {
    super(message);
    this.name = "FailClosedError";
  }
}

export function fail(code: FailureCode, message: string): never {
  throw new FailClosedError(code, message);
}
