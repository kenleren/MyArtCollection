import { fingerprint } from './account_authority.js';
import { sameLifecycle, validLifecycleFields, type LifecycleFields } from './lifecycle.js';
import { shape } from './event_records.js';
export const OWNERSHIP_PROOF_VERSION = 'play-ownership-proof-v1';
export interface OwnershipProof extends LifecycleFields {
  version:typeof OWNERSHIP_PROOF_VERSION;
  accountSubject:string;
  tokenFingerprint:string;
  kind:'direct_route'|'linked_binding'|'expired_context';
  predecessorFingerprint?:string;
}
export function validOwnershipProof(value:OwnershipProof, context:LifecycleFields & {accountSubject:string;tokenFingerprint:string}):boolean {
  return shape(value,['version','accountSubject','tokenFingerprint','kind','lifecycleEpoch','lifecycleGeneration'],['predecessorFingerprint']) &&
    value.version===OWNERSHIP_PROOF_VERSION && validLifecycleFields(value) && sameLifecycle(value,context) &&
    value.accountSubject===context.accountSubject && value.tokenFingerprint===context.tokenFingerprint &&
    ['direct_route','linked_binding','expired_context'].includes(value.kind) &&
    (value.predecessorFingerprint===undefined || fingerprint(value.predecessorFingerprint)) &&
    (value.kind!=='linked_binding' || value.predecessorFingerprint!==undefined);
}
