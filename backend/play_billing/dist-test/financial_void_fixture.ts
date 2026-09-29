/** Synthetic provider I/O behind the actual runtime, transports, custody and dispatch gate. */
import { randomUUID } from 'node:crypto';
import { createBillingRuntime } from '../src/billing_runtime.js';
import { BillingDeadline } from '../src/deadline.js';
import { EventProcessor } from '../src/event_processor.js';
import { BOUNDED_EVENT_LIMITS, EVENT_SOURCE, EVENT_TYPE, type EventWorkRecord } from '../src/event_records.js';
import { GoogleKmsTransport, GoogleKmsTokenCustody } from '../src/kms_token_custody.js';
import { KmsEventTokenCustody } from '../src/event_token_custody.js';
import { AndroidPublisherSubscriptionsAdapter, GoogleAndroidPublisherTransport } from '../src/play_adapter.js';
import { PlayBillingService } from '../src/verifier.js';
import { COLLECTIONS } from '../src/constants.js';
import type { BillingDatabase, BillingCollection } from '../src/store.js';
import { initialDispatchControls } from '../src/dispatch_budget.js';
import { createHarness, FakeClock, DeterministicNonceSource, acceptDisclosure, eligiblePurchase, purchaseToken, verifyRequest, type PurchaseOptions } from './test_helpers.js';
import { FakeKmsTransport, TEST_KEY } from './fake_custody.js';
import { testDispatchConfig, legacyControls } from './dispatch_fixtures.js';
export function voidNotification(token: string, order = 'synthetic-order-' + randomUUID(), options: {id?:string;productType?:number;refundType?:number;eventTime?:string} = {}) {
  const id = options.id ?? randomUUID();
  const body = {version:'1.0',packageName:'app.archivale',eventTimeMillis:options.eventTime??String(Date.now()),
    voidedPurchaseNotification:{purchaseToken:token,orderId:order,productType:options.productType??1,refundType:options.refundType??1}};
  return {id,type:EVENT_TYPE,source:EVENT_SOURCE,data:{message:{messageId:id,data:Buffer.from(JSON.stringify(body)).toString('base64')}}};
}
export async function financialFixture(options: {database?:BillingDatabase;enabled?:boolean;config?:ReturnType<typeof testDispatchConfig>} = {}) {
  const h = createHarness();
  h.clock = new FakeClock(new Date());
  const database = options.database ?? h.database;
  const config = options.config ?? testDispatchConfig();
  await database.runTransaction(async tx => {
    for (const [id,value] of Object.entries(initialDispatchControls(config,h.clock.now(),'e'.repeat(64),{kind:'verified_new'}))) tx.set(COLLECTIONS.dispatchControl,id,value);
    for (const [id,value] of Object.entries(legacyControls())) tx.set(COLLECTIONS.eventControl,id,value);
  });
  const kms = new FakeKmsTransport();
  const counts = {get:0,ack:0,kms:0};
  const requestedTokens: string[] = [];
  const hooks: {beforePlayHeaders?:()=>Promise<void>;ackStatus?:number} = {};
  const auth = {getClient:async()=>({getRequestHeaders:async()=>new Headers()})};
  const makeRuntime = async (enabled: boolean) => createBillingRuntime({database,identifiers:h.identifiers,
    nonces:new DeterministicNonceSource(),clock:h.clock,deadline:new BillingDeadline(),providersNeeded:true,
    configuration:JSON.stringify(config),publisherEnabled:true,
    events:{limits:BOUNDED_EVENT_LIMITS,encryptionVersion:TEST_KEY,retainedVersions:[TEST_KEY],fullVoidsEnabled:enabled},
    accountCustody:{enabled:true,encryptionVersion:TEST_KEY,retainedVersions:[TEST_KEY]},
    providerFactories:{
      play:gate=>new AndroidPublisherSubscriptionsAdapter(new GoogleAndroidPublisherTransport({gate,
        auth:{getClient:async()=>({getRequestHeaders:async()=>{await hooks.beforePlayHeaders?.();return new Headers();}})},
        fetch:async(url,init)=>{
          if(init.method==='GET') {
            counts.get++;
            const token=decodeURIComponent(url.split('/').pop()!);requestedTokens.push(token);
            return new Response(JSON.stringify(await h.play.getSubscription({packageName:'app.archivale',token,timeoutMs:10_000})));
          }
          counts.ack++;return new Response('',{status:hooks.ackStatus??200});
        }})),
      custody:gate=>new GoogleKmsTokenCustody(TEST_KEY,[TEST_KEY],new GoogleKmsTransport({gate,auth,fetch:async(url,init)=>{
        counts.kms++;
        return new Response(JSON.stringify(await kms.request(url.slice('https://cloudkms.googleapis.com/v1/'.length,url.lastIndexOf(':')),
          url.endsWith(':encrypt')?'encrypt':'decrypt',JSON.parse(init.body as string))));
      }})),
      eventCustody:gate=>new KmsEventTokenCustody(TEST_KEY,[TEST_KEY],new GoogleKmsTransport({gate,auth,fetch:async(url,init)=>{
        counts.kms++;
        return new Response(JSON.stringify(await kms.request(url.slice('https://cloudkms.googleapis.com/v1/'.length,url.lastIndexOf(':')),
          url.endsWith(':encrypt')?'encrypt':'decrypt',JSON.parse(init.body as string))));
      }})),
    }});
  const runtime = await makeRuntime(options.enabled??true);
  h.repository=runtime.repository;h.custody=runtime.custody;
  h.service=new PlayBillingService({...h,play:runtime.play});
  const processorFor=(r:typeof runtime)=>new EventProcessor({work:r.events!,repository:r.repository,identifiers:h.identifiers,
    eventCustody:r.eventCustody!,accountCustody:r.custody,play:r.play,clock:h.clock});
  const read = <T=any>(collection:BillingCollection,id:string):Promise<T|undefined> =>
    database.runTransaction(tx=>tx.get<T>(collection,id));
  const eventId=(event:ReturnType<typeof voidNotification>)=>h.identifiers.eventFingerprint('projects/my-art-collections/topics/archivale-play-rtdn',event.id);
  const job=(event:ReturnType<typeof voidNotification>)=>read<EventWorkRecord>(COLLECTIONS.eventWork,eventId(event));
  const purchase = async (options:PurchaseOptions = {}) => {
    const result=eligiblePurchase(h,options);
    const root=await read(COLLECTIONS.lifecycles,h.identifiers.accountSubject((options.accountIdentity??h.identity).uid));
    result.externalAccountIdentifiers={obfuscatedExternalAccountId:root?.obfuscatedAccountId??'synthetic-unregistered-account'};
    return result;
  };
  const paid = async () => {
    await acceptDisclosure(h);
    const token=purchaseToken();h.play.setPurchase(token,await purchase());
    const result=await h.service.verifySubscription(h.identity,verifyRequest(token));
    if(result.status!=='paid')throw new Error('synthetic financial purchase setup failed');
    return token;
  };
  return {...h,memoryDatabase:h.database,database,requestedTokens,runtime,processor:processorFor(runtime),processorFor,makeRuntime,kms,counts,hooks,read,job,eventId,paid,purchase};
}
