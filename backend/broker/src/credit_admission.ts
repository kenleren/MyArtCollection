/** Shared current owner-admission decision; billing authority never replaces it. */
export function admittedOwner(allowlist: ReadonlySet<string>, uid: string): boolean { return allowlist.has(uid); }
