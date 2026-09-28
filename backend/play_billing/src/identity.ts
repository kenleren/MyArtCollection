/** Only pass claims from Admin verifyIdToken(token, true), never request data. */
export function isPaidGoogleIdentity(
  decoded: { uid: string; firebase?: { sign_in_provider?: string } },
  callableUid: string,
): boolean {
  return decoded.uid.length > 0 && decoded.uid === callableUid &&
    decoded.firebase?.sign_in_provider === 'google.com';
}
