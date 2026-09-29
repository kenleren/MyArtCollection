import { BillingDeadline } from './deadline.js';
import type { Clock } from './contracts.js';
import { UnsafeBillingRecordError, type BillingDatabase, type ReconciliationDue } from './store.js';
import type { ReconciliationProcessor } from './reconciliation_processor.js';

export type ReconciliationOutcome = 'disabled'|'configuration_unavailable'|'batch_finished'|'partial_deadline'|'partial_failure'|'unsafe_state';
export type ReconciliationLag = 'under_minute'|'under_hour'|'under_day'|'day_or_more'|'unknown';
export interface ReconciliationSummary {
  readonly version:'play-billing-reconciliation-summary-v1';
  readonly outcome:ReconciliationOutcome;
  readonly selectedCount:number; readonly startedCount:number; readonly notStartedCount:number;
  readonly unclaimedCount:number; readonly paidCount:number; readonly inactiveCount:number; readonly noneCount:number;
  readonly pendingCount:number; readonly unavailableCount:number; readonly rejectedCount:number; readonly errorCount:number;
  readonly elapsedBucket:ReconciliationLag; readonly selectedOldestDueLagBucket:ReconciliationLag;
  readonly selectedOldestKnownVerificationLagBucket:ReconciliationLag; readonly selectedMissingSuccessCount:number;
}
type MutableSummary = {-readonly [K in keyof ReconciliationSummary]:ReconciliationSummary[K]};
export function emptyReconciliationSummary(outcome:ReconciliationOutcome):ReconciliationSummary {
  return Object.freeze({version:'play-billing-reconciliation-summary-v1',outcome,selectedCount:0,startedCount:0,notStartedCount:0,
    unclaimedCount:0,paidCount:0,inactiveCount:0,noneCount:0,pendingCount:0,unavailableCount:0,rejectedCount:0,errorCount:0,
    elapsedBucket:'unknown',selectedOldestDueLagBucket:'unknown',selectedOldestKnownVerificationLagBucket:'unknown',selectedMissingSuccessCount:0});
}
export function reconciliationDeadlineElapsed(d:BillingDeadline):boolean {return d.signal.aborted||Date.now()>=d.expiresAt;}
function bucket(ms:number):ReconciliationLag {return !Number.isFinite(ms)||ms<0?'unknown':ms<60_000?'under_minute':ms<3_600_000?'under_hour':ms<86_400_000?'under_day':'day_or_more';}
function validCohort(rows:ReconciliationDue[],now:Date):boolean {
  if(!Array.isArray(rows)||rows.length>10||!Number.isFinite(+now))return false;
  const seen=new Set<string>();let previous:ReconciliationDue|undefined;
  for(const row of rows){
    if(!row||typeof row!=='object'||Object.keys(row).some(k=>!['accountSubject','dueAt','lastSuccessfulVerificationAt'].includes(k))||
      typeof row.accountSubject!=='string'||!/^[a-f0-9]{64}$/.test(row.accountSubject)||seen.has(row.accountSubject)||
      !(row.dueAt instanceof Date)||!Number.isFinite(+row.dueAt)||row.dueAt>now||
      (row.lastSuccessfulVerificationAt!==undefined&&(!(row.lastSuccessfulVerificationAt instanceof Date)||!Number.isFinite(+row.lastSuccessfulVerificationAt))))return false;
    if(previous&&(+previous.dueAt>+row.dueAt||(+previous.dueAt===+row.dueAt&&previous.accountSubject>=row.accountSubject)))return false;
    seen.add(row.accountSubject);previous=row;
  }
  return true;
}
/** One advisory query, then serial authoritative claims. No global freshness claim. */
export class ReconciliationPump {
  constructor(private readonly d:{database:Pick<BillingDatabase,'dueReconciliationWork'>;processor:Pick<ReconciliationProcessor,'processOne'>;clock:Clock}){}
  async run(deadline:BillingDeadline):Promise<ReconciliationSummary>{
    const began=Date.now(),summary:MutableSummary={...emptyReconciliationSummary('batch_finished')};
    try{
      deadline.check();
      if(!this.d.database.dueReconciliationWork)throw new UnsafeBillingRecordError();
      const now=this.d.clock.now();
      const result=await deadline.run(()=>this.d.database.dueReconciliationWork!(now,10));
      deadline.check();
      if(!validCohort(result,now))throw new UnsafeBillingRecordError();
      // Query-owned objects cannot change selection or reported metadata across awaits.
      const rows=result.map(r=>({accountSubject:r.accountSubject,dueAt:+r.dueAt,lastSuccessfulVerificationAt:r.lastSuccessfulVerificationAt===undefined?undefined:+r.lastSuccessfulVerificationAt}));
      summary.selectedCount=rows.length;
      summary.selectedOldestDueLagBucket=rows.length?bucket(+now-rows[0].dueAt):'unknown';
      const known=rows.flatMap(r=>r.lastSuccessfulVerificationAt===undefined?[]:[r.lastSuccessfulVerificationAt]);
      summary.selectedMissingSuccessCount=rows.length-known.length;
      summary.selectedOldestKnownVerificationLagBucket=known.length?bucket(+now-Math.min(...known)):'unknown';
      for(const row of rows){
        if(reconciliationDeadlineElapsed(deadline)||deadline.expiresAt-Date.now()<5_000){summary.outcome='partial_deadline';break;}
        summary.startedCount++;
        const response=await deadline.run(()=>this.d.processor.processOne(row.accountSubject,deadline),Math.max(1,deadline.expiresAt-Date.now()));
        deadline.check();
        if(response===undefined){summary.unclaimedCount++;continue;}
        if('reason'in response&&response.reason==='unsafe_record'){summary.errorCount++;summary.outcome='unsafe_state';break;}
        switch(response.status){
          case 'paid':summary.paidCount++;break;
          case 'none':if(['expired','on_hold','paused','revoked'].includes(response.reason))summary.inactiveCount++;else summary.noneCount++;break;
          case 'pending':summary.pendingCount++;break;
          case 'unavailable':summary.unavailableCount++;break;
          case 'rejected':summary.rejectedCount++;break;
          default:throw new Error('billing reconciliation response unavailable');
        }
      }
    }catch(error){
      if(reconciliationDeadlineElapsed(deadline))summary.outcome='partial_deadline';
      else {summary.errorCount++;summary.outcome=error instanceof UnsafeBillingRecordError?'unsafe_state':'partial_failure';}
    }
    if(reconciliationDeadlineElapsed(deadline))summary.outcome='partial_deadline';
    summary.notStartedCount=summary.selectedCount-summary.startedCount;
    summary.elapsedBucket=bucket(Date.now()-began);
    return Object.freeze(summary);
  }
}
