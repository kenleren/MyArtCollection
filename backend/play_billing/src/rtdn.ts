import { createHash } from 'node:crypto';
import { PACKAGE_NAME } from './constants.js';
import { EVENT_SOURCE, EVENT_TYPE, EventWorkError, record, type EventWorkRecord } from './event_records.js';
import { validBase64, validToken } from './token_custody.js';

export interface ParsedNotification { messageId:string; payloadDigest:string; category:EventWorkRecord['category']; token?:string }
/** The Functions SDK has already decoded the CloudEvent envelope. These bounds
 * cover our application parsing/allocation, not the platform's initial allocation. */
export function parseRtdn(event:unknown):ParsedNotification {
  const fail = ():never => { throw new EventWorkError('unsafe'); };
  if (!record(event) || Object.keys(event).length>16 || event.type !== EVENT_TYPE || event.source !== EVENT_SOURCE ||
      typeof event.id !== 'string' || Buffer.byteLength(event.id)>256 || !record(event.data) || Object.keys(event.data).length>8 || !record(event.data.message)) return fail();
  const message=event.data.message;
  if(Object.keys(message).length>8 || ['specversion','subject','time','datacontenttype'].some(key=>event[key]!==undefined &&
      (typeof event[key]!=='string'||Buffer.byteLength(event[key] as string)>256)) ||
      ['publishTime','orderingKey'].some(key=>message[key]!==undefined && (typeof message[key]!=='string'||Buffer.byteLength(message[key] as string)>256))) return fail();
  if (typeof message.messageId !=='string' || !message.messageId || Buffer.byteLength(message.messageId)>256 || event.id!==message.messageId ||
      typeof message.data !=='string' || !validBase64(message.data,10924)) return fail();
  if (message.attributes !== undefined && (!record(message.attributes) || Object.keys(message.attributes).length>8 ||
      Object.entries(message.attributes).some(([key,value])=>Buffer.byteLength(key)>128 || typeof value!=='string' || Buffer.byteLength(value)>512))) return fail();
  const bytes=Buffer.from(message.data,'base64');
  if(bytes.length>8192) return fail();
  let value:unknown;
  try { value=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes)); } catch { return fail(); }
  let properties=0;
  const bounded=(v:unknown,depth:number):boolean=>{
    if(depth>8) return false;
    if(typeof v==='string') return Buffer.byteLength(v)<=4096;
    if(Array.isArray(v)) return v.length<=16 && v.every(child=>bounded(child,depth+1));
    if(record(v)) { properties+=Object.keys(v).length; return properties<=64 && Object.entries(v).every(([key,child])=>Buffer.byteLength(key)<=4096 && bounded(child,depth+1)); }
    return v===null || typeof v==='boolean' || (typeof v==='number' && Number.isFinite(v));
  };
  if(!bounded(value,0) || !record(value) || value.version!=='1.0' || value.packageName!==PACKAGE_NAME ||
      typeof value.eventTimeMillis!=='string' || !/^[0-9]{1,16}$/.test(value.eventTimeMillis)) return fail();
  const types=['subscriptionNotification','oneTimeProductNotification','voidedPurchaseNotification','pendingRefundReviewNotification','testNotification'];
  const present=types.filter(key=>value[key]!==undefined);
  if(present.length!==1 || Object.keys(value).some(key=>!['version','packageName','eventTimeMillis',...types].includes(key))) return fail();
  const kind=present[0], body=value[kind]; if(!record(body)) return fail();
  let token:string|undefined;
  if(kind==='testNotification') { if(body.version!=='1.0' || Object.keys(body).length!==1) return fail(); }
  else if(kind==='pendingRefundReviewNotification') {
    if(body.version!=='1.0'||!validToken(body.pendingRefundToken)||typeof body.orderId!=='string'||!Number.isSafeInteger(body.refundReason)||
       Object.keys(body).some(key=>!['version','pendingRefundToken','orderId','refundReason','obfuscatedAccountId','obfuscatedProfileId'].includes(key))) return fail();
    // Refund-review credentials/order IDs are deliberately not returned or retained.
  } else {
    if(!validToken(body.purchaseToken)) return fail(); token=body.purchaseToken;
    if(kind==='oneTimeProductNotification' && (body.version!=='1.0'||!Number.isSafeInteger(body.notificationType)||typeof body.sku!=='string'||
        Object.keys(body).some(key=>!['version','notificationType','purchaseToken','sku'].includes(key)))) return fail();
    if(kind==='voidedPurchaseNotification' && (typeof body.orderId!=='string'||!Number.isSafeInteger(body.productType)||!Number.isSafeInteger(body.refundType)||
        Object.keys(body).some(key=>!['purchaseToken','orderId','productType','refundType'].includes(key)))) return fail();
    if(kind==='subscriptionNotification' && (body.version!=='1.0' || !Number.isSafeInteger(body.notificationType) ||
      Number(body.notificationType)<1 ||
      Object.keys(body).some(key=>!['version','notificationType','purchaseToken','subscriptionId'].includes(key)) ||
      (body.subscriptionId!==undefined && (typeof body.subscriptionId!=='string' || body.subscriptionId.length>128)))) return fail();
  }
  const supported=[1,2,3,4,5,6,7,8,9,10,11,12,13,17,18,19,20,22];
  const category:EventWorkRecord['category']=kind==='subscriptionNotification'?(supported.includes(Number(body.notificationType))?'subscription':'unsupported'):
    kind==='testNotification'?'test':kind==='pendingRefundReviewNotification'?'refund_review':kind==='voidedPurchaseNotification'?'void':'one_time';
  return {messageId:message.messageId,payloadDigest:createHash('sha256').update(bytes).digest('hex'),
    category,...(token===undefined?{}:{token})};
}
