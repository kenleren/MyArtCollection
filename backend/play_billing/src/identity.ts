import type { Auth } from 'firebase-admin/auth';
import type { BillingIdentity } from './contracts.js';
import { matchesApprovedAppId } from './runtime_config.js';

/** Only pass claims from Admin verifyIdToken(token, true), never request data. */
export function isPaidGoogleIdentity(
  decoded: { uid: string; firebase?: { sign_in_provider?: string } },
  callableUid: string,
): boolean {
  return decoded.uid.length > 0 && decoded.uid === callableUid &&
    decoded.firebase?.sign_in_provider === 'google.com';
}

/** SDK-verified callable context only; never populate this from request.data. */
export interface BillingCallableContext {
  auth?: { uid: string };
  app?: { appId: unknown; alreadyConsumed?: unknown };
  rawRequest: { headers: { authorization?: unknown } };
}

/** The SDK accepts valid-but-already-consumed tokens; the paid boundary must not. */
export async function verifyCallableIdentity(
  request: BillingCallableContext,
  auth: Pick<Auth, 'verifyIdToken'>,
  approvedAppId: string | undefined,
): Promise<BillingIdentity | undefined> {
  if (request.auth == null || request.app == null ||
      request.app.alreadyConsumed !== false ||
      !matchesApprovedAppId(approvedAppId, request.app.appId)) return undefined;
  const authorization = request.rawRequest.headers.authorization;
  if (typeof authorization !== 'string' || !authorization.startsWith('Bearer ')) return undefined;
  try {
    const decoded = await auth.verifyIdToken(authorization.slice('Bearer '.length), true);
    return isPaidGoogleIdentity(decoded, request.auth.uid) ? { uid: decoded.uid } : undefined;
  } catch {
    return undefined;
  }
}
