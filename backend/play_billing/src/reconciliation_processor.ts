import { randomUUID } from 'node:crypto';
import { BillingDeadline } from './deadline.js';
import { CONTRACT_VERSION, DISCLOSURE_VERSION } from './constants.js';
import type { Clock, PlaySubscriptionsAdapter, VerifyResponse } from './contracts.js';
import type { BillingIdentifiers } from './crypto.js';
import type { TokenCustody } from './token_custody.js';
import { BillingRepository } from './store.js';
import { PlayBillingService } from './verifier.js';
import type { InternalWork } from './reconciliation_work.js';
/** Injected, one-job source integration only. No runtime export, credentials or
 * automatic pump. Production must remain closed until the shared budget layer. */
export class ReconciliationProcessor {
  constructor(private readonly d:{repository:BillingRepository;identifiers:BillingIdentifiers;clock:Clock;play:PlaySubscriptionsAdapter;custody:TokenCustody}){}
  async processOne(subject:string,deadline=new BillingDeadline(Date.now()+50_000)):Promise<VerifyResponse|undefined>{
    const claimed=await deadline.run(()=>this.d.repository.claimReconciliation(subject,this.d.clock.now(),deadline));
    if(!claimed)return undefined;
    const work:Extract<InternalWork,{kind:'reconciliation'}>={kind:'reconciliation',fence:claimed};
    const selected=claimed.selectedDemand;
    const requestFingerprint=this.d.identifiers.reconciliationFingerprint(subject,claimed.lifecycleEpoch,claimed.ownerGeneration,claimed.nonce,
      JSON.stringify([claimed.lifecycleGeneration,claimed.assertionId,selected.kind,selected.tokenFingerprint,selected.demandRevision,selected.indexRevision]));
    try{
      const service=new PlayBillingService({repository:this.d.repository,identifiers:this.d.identifiers,clock:this.d.clock,play:this.d.play,custody:this.d.custody});
      return await deadline.run(()=>service.processAccountObservation({accountSubject:subject,requestFingerprint,source:'background',work},
        {kind:'restore',input:{version:CONTRACT_VERSION,requestId:randomUUID(),billingDisclosureVersion:DISCLOSURE_VERSION}},deadline),Math.max(1,deadline.expiresAt-Date.now()));
    } finally {
      // Terminal completion has removed the live lease: this read is a no-op.
      // A crash/cancel leaves the existing lease reclaimable; no deadline renewal.
      if (!deadline.signal.aborted && Date.now() < deadline.expiresAt) {
        await deadline.run(()=>this.d.repository.retryReconciliation(work.fence,this.d.clock.now(),deadline),
          Math.max(1,deadline.expiresAt-Date.now())).catch(()=>false);
      }
    }
  }
}
