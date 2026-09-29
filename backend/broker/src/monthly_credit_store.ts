import { validateCanonicalPayloadV1 } from './canonical_payload.js';
import { randomBytes } from 'node:crypto';
import type { BrokerRequest, BrokerTerminalOutcome, ProviderClient, ProviderResearchResult, BrokerResult } from './contracts.js';
import type { MonthlyDispatchOutcome } from './broker.js';
import type { AcquireRequestInput, AcquireRequestResult, DispatchStartResult, RequestLifecycleStore, SettlementIntent } from './request_lifecycle.js';
import { CreditIdentityService, accountId, validAccount, type AccountingIdentity, type CreditAccount } from './credit_identity.js';
import { CreditIdentityDeadline } from './credit_identity_deadline.js';
import { CREDIT_COLLECTIONS as C, type CreditIdentityDatabase, type CreditTransaction } from './credit_identity_store.js';
import { controlRecordFromSnapshot, type DurableFirestoreDocumentSnapshot } from './durable_protection.js';
import { M, MAX_MONTHS, MAX_ENTRIES, MAX_STARTS, MonthlyUnsafeError, unsafe, keys, digest, bounded, fingerprint, utcMonth, zero, change, parsePolicy, parseControlPair, initialMonthlyControls, initializationFor, parseAccount, markerFor, headFor, replayHead, parseMonth, parseGlobalMonth, parseShard, parseRequest, parseLedger, type MonthlyPolicy, type MonthlyControl, type MonthlyAccount, type MonthlyMonth, type GlobalMonth, type ReplayShard, type MonthlyRequest, type MonthlyLedger, type AuthorityBinding } from './monthly_credit_protocol.js';
export interface MonthlyStoreOptions {
    database: CreditIdentityDatabase;
    identityService: CreditIdentityService;
    identity: Readonly<AccountingIdentity>;
    policy: MonthlyPolicy;
    accountKey: string;
    deadline: CreditIdentityDeadline;
    now: () => number;
    /** Must match the actual v1 FirestoreDurableBrokerStore instance. */
    collectionPrefix: string;
    newNonce?: () => string;
}
interface Book {
    credit: CreditAccount;
    account: MonthlyAccount;
    control: MonthlyControl;
    shard: ReplayShard;
    month: MonthlyMonth;
    global: GlobalMonth;
    request?: MonthlyRequest;
    ledger?: MonthlyLedger;
}
interface Handle {
    ownerNonce: string;
    attempted: boolean;
    consumed: boolean;
    mayWriteOutcome: boolean;
    cleanup?: CreditIdentityDeadline;
    readbackUsed: boolean;
}
const monthId = (subject: string, month: string) => `${subject}_${month}`;
const shardId = (subject: string, shard: string) => `${subject}_${shard}`;
function liveData(value: unknown) {
    const parsed = controlRecordFromSnapshot({ exists: value !== undefined, data: () => value } as DurableFirestoreDocumentSnapshot);
    if (!parsed)
        unsafe();
    return { ...(value as Record<string, unknown>) };
}
/** Internal explicit new-state procedure; never called by acquire or an exported trigger. */
export async function initializeMonthlyCutover(database: CreditIdentityDatabase, collectionPrefix: string, policy: MonthlyPolicy, evidenceDigest: string, d: CreditIdentityDeadline): Promise<void> {
    if (database.collectionPrefix !== collectionPrefix)
        unsafe();
    const proposed = initialMonthlyControls(policy, evidenceDigest);
    await d.run(() => database.transaction(async (tx) => {
        d.check();
        const live = liveData(await tx.get(`${collectionPrefix}Control`, 'live'));
        const usage = await tx.get(`${collectionPrefix}Control`, 'globalUsage');
        const a = await tx.get(M.control, 'control'), b = await tx.get(M.control, 'initialization');
        if (Object.hasOwn(live, 'monthlyCutover') || a !== undefined || b !== undefined || !tx.findFirst)
            unsafe();
        if (usage !== undefined && (!keys(usage, ['record_version', 'exposed_credits']) || usage.record_version !== 'broker-credit-global-v1' || usage.exposed_credits !== 0))
            unsafe();
        for (const suffix of ['Idempotency', 'Ledger', 'QuotaSubjects'])
            if (await tx.findFirst(collectionPrefix + suffix) !== undefined)
                unsafe();
        d.check();
        tx.set(`${collectionPrefix}Control`, 'live', { ...live, monthlyCutover: proposed.witness });
        tx.set(M.control, 'control', proposed.control);
        tx.set(M.control, 'initialization', proposed.initialization);
    }));
}
/** One request-bound, injected v2 lifecycle. Never selected by the live v1 factory. */
export class MonthlyCreditStore implements RequestLifecycleStore<MonthlyRequest> {
    private readonly policy: Readonly<MonthlyPolicy>;
    private readonly handles = new WeakMap<MonthlyRequest, Handle>();
    private readonly d: CreditIdentityDeadline;
    private readonly o: MonthlyStoreOptions;
    constructor(o: MonthlyStoreOptions) {
        this.o = Object.freeze({ ...o });
        this.policy = parsePolicy(o.policy);
        this.d = o.deadline.bounded(50000);
        if (o.database.collectionPrefix !== o.collectionPrefix || !/^[a-zA-Z][a-zA-Z0-9_-]{0,80}$/.test(o.collectionPrefix))
            unsafe();
    }
    private async control(tx: CreditTransaction, cleanup = false): Promise<MonthlyControl> {
        const live = liveData(await tx.get(`${this.o.collectionPrefix}Control`, 'live'));
        const { control } = parseControlPair(await tx.get(M.control, 'control'), await tx.get(M.control, 'initialization'), live.monthlyCutover, cleanup ? undefined : this.policy);
        if (control.witness.cutoverId !== this.policy.cutoverId || control.witness.policyId !== this.policy.policyId)
            unsafe();
        return control;
    }
    private async credit(tx: CreditTransaction, cleanup: boolean, d: CreditIdentityDeadline): Promise<CreditAccount> {
        if (!cleanup)
            return this.o.identityService.readAccountingIdentity(tx, this.o.identity, d);
        const a = await tx.get(C.accounts, accountId(this.o.identity.accountSubject));
        if (!validAccount(a) || a.accountSubject !== this.o.identity.accountSubject || a.route !== this.o.identity.route)
            unsafe();
        return a;
    }
    async enroll(): Promise<void> {
        await this.d.run(() => this.o.database.transaction(async (tx) => {
            this.d.check();
            const credit = await this.credit(tx, false, this.d), control = await this.control(tx);
            const subject = this.o.identity.accountSubject;
            const old = await tx.get(M.accounts, subject);
            if (credit.monthly !== undefined || old !== undefined) {
                parseAccount(old, credit.monthly, subject, this.policy.cutoverId);
                this.d.check();
                return;
            }
            if (!tx.findFirst)
                unsafe();
            for (const c of [M.months, M.requests, M.ledger, M.replay])
                if (await tx.findFirst(c, 'accountSubject', subject) !== undefined)
                    unsafe();
            const a: MonthlyAccount = {
                version: 'broker-monthly-account-v1', accountSubject: subject, cutoverId: this.policy.cutoverId, revision: 1, latestMonth: null, totals: zero(), months: {}, replay: {}, inFlight: null
            };
            const shards: ReplayShard[] = [];
            for (const shard of '0123456789abcdef') {
                const row: ReplayShard = {
                    version: 'broker-monthly-replay-v1', accountSubject: subject, cutoverId: this.policy.cutoverId, shard, revision: 0, entries: {}
                };
                shards.push(row);
                a.replay[shard] = replayHead(row);
            }
            control.enrolledAccounts++;
            control.revision++;
            if (!Number.isSafeInteger(control.enrolledAccounts) || !Number.isSafeInteger(control.revision))
                unsafe();
            this.d.check();
            tx.set(M.accounts, subject, bounded(a));
            tx.set(C.accounts, accountId(subject), { ...credit, monthly: markerFor(a) });
            for (const s of shards)
                tx.set(M.replay, shardId(subject, s.shard), s);
            this.writeControl(tx, control);
        }));
    }
    private writeControl(tx: CreditTransaction, c: MonthlyControl): void {
        // Validate the complete proposed pair before any transaction can commit it.
        const i = initializationFor(c);
        parseControlPair(c, i, c.witness);
        tx.set(M.control, 'control', bounded(c));
        tx.set(M.control, 'initialization', bounded(i));
    }
    private async validateFlight(tx: CreditTransaction, a: MonthlyAccount): Promise<void> {
        if (!a.inFlight)
            return;
        const f = a.inFlight;
        const r = parseRequest(await tx.get(M.requests, f.requestFingerprint));
        const l = parseLedger(await tx.get(M.ledger, f.requestFingerprint), r);
        const m = parseMonth(await tx.get(M.months, monthId(a.accountSubject, f.originalMonth)), a.months[f.originalMonth], a.accountSubject, f.originalMonth, a.cutoverId);
        const shard = parseShard(await tx.get(M.replay, shardId(a.accountSubject, f.requestFingerprint[0])), a.replay[f.requestFingerprint[0]], a.accountSubject, f.requestFingerprint[0], a.cutoverId);
        const receipt = shard.entries[f.requestFingerprint];
        if (r.requestFingerprint !== fingerprint(this.o.accountKey, a.accountSubject, r.request_id) || r.accountSubject !== a.accountSubject || r.requestFingerprint !== f.requestFingerprint || r.originalMonth !== f.originalMonth || r.reservationOrdinal !== f.reservationOrdinal || r.ownerNonce !== f.ownerNonce || r.leaseExpiresAtMs !== f.leaseExpiresAtMs ||
            (r.state === 'terminal' ? 'terminal_pending_settlement' : r.state) !== f.phase || l.state !== 'reserved' || m.totals.reserved !== 1 || !receipt || receipt.originalMonth !== r.originalMonth || receipt.reservationOrdinal !== r.reservationOrdinal || receipt.payloadHash !== r.payload_hash)
            unsafe();
    }
    private async book(tx: CreditTransaction, fp: string, targetMonth: string, d: CreditIdentityDeadline, cleanup = false): Promise<Book> {
        d.check();
        const credit = await this.credit(tx, cleanup, d), control = await this.control(tx, cleanup), subject = this.o.identity.accountSubject;
        const account = parseAccount(await tx.get(M.accounts, subject), credit.monthly, subject, this.policy.cutoverId);
        await this.validateFlight(tx, account);
        const shard = parseShard(await tx.get(M.replay, shardId(subject, fp[0])), account.replay[fp[0]], subject, fp[0], this.policy.cutoverId);
        const rawRequest = await tx.get(M.requests, fp), rawLedger = await tx.get(M.ledger, fp), receipt = shard.entries[fp];
        let request: MonthlyRequest | undefined, ledger: MonthlyLedger | undefined;
        if (receipt || rawRequest !== undefined || rawLedger !== undefined) {
            request = parseRequest(rawRequest);
            ledger = parseLedger(rawLedger, request);
            if (!receipt || request.requestFingerprint !== fp || request.accountSubject !== subject || request.cutoverId !== this.policy.cutoverId || receipt.originalMonth !== request.originalMonth || receipt.reservationOrdinal !== request.reservationOrdinal || receipt.payloadHash !== request.payload_hash)
                unsafe();
            if (ledger.state === 'reserved' && account.inFlight?.requestFingerprint !== fp)
                unsafe();
            targetMonth = request.originalMonth;
        }
        const rawMonth = await tx.get(M.months, monthId(subject, targetMonth));
        let m: MonthlyMonth;
        if (rawMonth === undefined && account.months[targetMonth] === undefined) {
            if (request || cleanup || account.latestMonth !== null && targetMonth <= account.latestMonth || Object.keys(account.months).length >= MAX_MONTHS)
                unsafe();
            if (account.latestMonth)
                parseMonth(await tx.get(M.months, monthId(subject, account.latestMonth)), account.months[account.latestMonth], subject, account.latestMonth, this.policy.cutoverId);
            m = {
                version: 'broker-monthly-month-v1', accountSubject: subject, month: targetMonth, cutoverId: this.policy.cutoverId, revision: 1, allowanceCeiling: 0, highestEligiblePlanSeen: 'starter', totals: zero()
            };
        }
        else
            m = parseMonth(rawMonth, account.months[targetMonth], subject, targetMonth, this.policy.cutoverId);
        const rawGlobal = await tx.get(M.globalMonths, targetMonth);
        let global: GlobalMonth;
        if (rawGlobal === undefined && control.months[targetMonth] === undefined) {
            const latest = Object.keys(control.months).sort().at(-1);
            if (request || cleanup || latest !== undefined && targetMonth <= latest || Object.keys(control.months).length >= MAX_MONTHS)
                unsafe();
            if (latest)
                parseGlobalMonth(await tx.get(M.globalMonths, latest), control.months[latest], latest, this.policy.cutoverId);
            global = {
                version: 'broker-monthly-global-month-v1', month: targetMonth, cutoverId: this.policy.cutoverId, revision: 1, totals: zero()
            };
        }
        else
            global = parseGlobalMonth(rawGlobal, control.months[targetMonth], targetMonth, this.policy.cutoverId);
        if (control.enrolledAccounts < 1 || (Object.keys(account.totals) as (keyof typeof account.totals)[]).some(k => control.totals[k] < account.totals[k] || global.totals[k] < m.totals[k]))
            unsafe();
        if (request && request.reservationOrdinal > m.totals.reservationStarts)
            unsafe();
        return {
            credit, control, account, shard, month: m, global, request, ledger
        };
    }
    private writeBook(tx: CreditTransaction, b: Book): void {
        const { account: a, control: c, month: m, global: g, shard: s } = b;
        a.revision++;
        c.revision++;
        m.revision++;
        g.revision++;
        a.months[m.month] = headFor(m);
        a.latestMonth = Object.keys(a.months).sort().at(-1)!;
        a.replay[s.shard] = replayHead(s);
        c.months[g.month] = headFor(g);
        parseAccount(a, markerFor(a), a.accountSubject, a.cutoverId);
        bounded(m);
        bounded(g);
        bounded(s);
        if (b.request && b.ledger) {
            parseRequest(b.request);
            parseLedger(b.ledger, b.request);
            tx.set(M.requests, b.request.requestFingerprint, bounded(b.request));
            tx.set(M.ledger, b.request.requestFingerprint, b.ledger);
        }
        tx.set(M.months, monthId(a.accountSubject, m.month), m);
        tx.set(M.globalMonths, g.month, g);
        tx.set(M.replay, shardId(a.accountSubject, s.shard), s);
        tx.set(M.accounts, a.accountSubject, bounded(a));
        tx.set(C.accounts, accountId(a.accountSubject), { ...b.credit, monthly: markerFor(a) });
        this.writeControl(tx, c);
    }
    private totals(b: Book, kind: 'reserve' | 'dispatch' | 'refund' | 'finalize'): void {
        b.account.totals = change(b.account.totals, kind);
        b.control.totals = change(b.control.totals, kind);
        b.month.totals = change(b.month.totals, kind);
        b.global.totals = change(b.global.totals, kind);
    }
    private bind(r: MonthlyRequest, owned: boolean): MonthlyRequest {
        this.handles.set(r, {
            ownerNonce: r.ownerNonce, attempted: false, consumed: false, mayWriteOutcome: owned, readbackUsed: false
        });
        return r;
    }
    async acquire(input: AcquireRequestInput): Promise<AcquireRequestResult<MonthlyRequest>> {
        try { return await this.acquireOwned(input); }
        catch (error) {
            if (error instanceof MonthlyUnsafeError) return {kind:'unsafe_record'};
            throw error;
        }
    }
    private async acquireOwned(input: AcquireRequestInput): Promise<AcquireRequestResult<MonthlyRequest>> {
        const fp = fingerprint(this.o.accountKey, this.o.identity.accountSubject, input.request_id);
        if (input.credit_cost !== 1 || !/^[a-f0-9]{64}$/.test(input.payload_hash))
            unsafe();
        const nonce = (this.o.newNonce ?? (() => randomBytes(16).toString('hex')))();
        const result = await this.d.run(() => this.o.database.transaction(async (tx) => {
            const b = await this.book(tx, fp, utcMonth(this.o.now()), this.d);
            if (b.request) {
                if (b.request.request_id !== input.request_id)
                    unsafe();
                if (b.request.payload_hash !== input.payload_hash)
                    return { kind: 'conflict' as const };
                if (b.request.state === 'terminal')
                    return {
                        kind: 'replay' as const, record: b.request, outcome: b.request.terminal_outcome!
                    };
                if (b.request.state === 'dispatch_intent')
                    return { kind: 'outcome_unknown' as const };
                if (this.o.now() < b.request.leaseExpiresAtMs)
                    return { kind: 'in_flight' as const };
                const outcome: BrokerTerminalOutcome = { kind: 'error', failure: { request_id: input.request_id, condition: 'reservation_lease_expired' } };
                b.request.state = 'terminal';
                b.request.settlement_state = 'pending_refund';
                b.request.terminal_outcome = outcome;
                b.account.inFlight!.phase = 'terminal_pending_settlement';
                this.d.check();
                this.writeBook(tx, b);
                return {
                    kind: 'replay' as const, record: b.request, outcome
                };
            }
            if (b.account.inFlight)
                return { kind: 'in_flight' as const };
            const e = await this.o.identityService.readAccountingEligibility(tx, this.o.identity, this.d);
            if (!e)
                unsafe();
            if (b.control.breakerOpen)
                unsafe();
            const allowance = this.policy.allowances[e.planId];
            b.month.allowanceCeiling = Math.max(b.month.allowanceCeiling, allowance);
            if (['starter', 'collector', 'archive'].indexOf(e.planId) > ['starter', 'collector', 'archive'].indexOf(b.month.highestEligiblePlanSeen))
                b.month.highestEligiblePlanSeen = e.planId;
            if (b.month.totals.exposed >= b.month.allowanceCeiling || b.month.totals.reservationStarts >= MAX_STARTS || Object.keys(b.shard.entries).length >= MAX_ENTRIES || b.global.totals.exposed >= this.policy.globalMonthlyExposure || b.control.totals.exposed >= this.policy.globalLifetimeExposure || b.global.totals.dispatchStarts >= this.policy.globalMonthlyDispatchStarts || b.control.totals.dispatchStarts >= this.policy.globalLifetimeDispatchStarts)
                return { kind: 'credits_exhausted' as const };
            const now = this.o.now(), lease = Math.min(now + 60000, this.d.expiresAt, e.fence.expiresAt);
            if (now < e.fence.verifiedAtMs || utcMonth(now) !== b.month.month)
                unsafe();
            this.d.check(lease);
            const { accountSubject: _, ...fence } = e.fence;
            const authority: AuthorityBinding = { ...fence, admissionPolicyId: this.o.identityService.accountingPolicyId() };
            const r: MonthlyRequest = {
                record_version: 'broker-request-lifecycle-v2', requestFingerprint: fp, accountSubject: this.o.identity.accountSubject, cutoverId: this.policy.cutoverId, request_id: input.request_id, payload_hash: input.payload_hash, originalMonth: b.month.month, reservationOrdinal: b.month.totals.reservationStarts + 1, credit_cost: 1, ownerNonce: nonce, reservedAtMs: now, leaseExpiresAtMs: lease, state: 'reserved', authority, settlement_state: 'reserved'
            };
            b.request = r;
            b.ledger = {
                version: 'broker-monthly-ledger-v1', requestFingerprint: fp, accountSubject: r.accountSubject, cutoverId: r.cutoverId, originalMonth: r.originalMonth, reservationOrdinal: r.reservationOrdinal, creditCost: 1, state: 'reserved'
            };
            b.account.inFlight = {
                requestFingerprint: fp, originalMonth: r.originalMonth, reservationOrdinal: r.reservationOrdinal, ownerNonce: nonce, leaseExpiresAtMs: lease, phase: 'reserved'
            };
            b.shard.entries[fp] = {
                originalMonth: r.originalMonth, reservationOrdinal: r.reservationOrdinal, payloadHash: r.payload_hash
            };
            b.shard.revision++;
            this.totals(b, 'reserve');
            this.d.check(lease);
            this.writeBook(tx, b);
            return { kind: 'reserved' as const, record: r };
        }));
        if (result.kind === 'reserved' || result.kind === 'replay') {
            if (result.kind === 'reserved') {
                if (this.o.now() < result.record.authority.verifiedAtMs)
                    unsafe();
                this.d.check(result.record.leaseExpiresAtMs);
            }
            this.bind(result.record, result.kind === 'reserved');
        }
        return result;
    }
    async markDispatchStarted(): Promise<DispatchStartResult<MonthlyRequest>> { return unsafe(); }
    private owned(r: MonthlyRequest): Handle {
        const h = this.handles.get(r);
        if (!h || h.ownerNonce !== r.ownerNonce)
            unsafe();
        return h;
    }
    private sameOwner(actual: MonthlyRequest, r: MonthlyRequest): void {
        if (actual.ownerNonce !== r.ownerNonce || actual.requestFingerprint !== r.requestFingerprint || actual.payload_hash !== r.payload_hash || actual.originalMonth !== r.originalMonth || actual.reservationOrdinal !== r.reservationOrdinal)
            unsafe();
    }
    private cleanup(r: MonthlyRequest): CreditIdentityDeadline {
        const h = this.owned(r);
        return h.cleanup ??= new CreditIdentityDeadline(this.o.now() + 20000, this.o.now);
    }
    private async cleanupTransaction(r: MonthlyRequest, operation: (tx: CreditTransaction, d: CreditIdentityDeadline) => Promise<MonthlyRequest>, confirm: (r: MonthlyRequest) => boolean): Promise<MonthlyRequest> {
        const d = this.cleanup(r);
        try {
            return await d.run(() => this.o.database.transaction(tx => { d.check(); return operation(tx, d); }));
        }
        catch {
            // Original cleanup cap is retained; this is readback, never a second write.
            d.check();
            const handle = this.owned(r);
            if (handle.readbackUsed)
                unsafe();
            handle.readbackUsed = true;
            return d.run(() => this.o.database.transaction(async (tx) => {
                const b = await this.book(tx, r.requestFingerprint, r.originalMonth, d, true);
                if (!b.request)
                    unsafe();
                this.sameOwner(b.request, r);
                if (!confirm(b.request))
                    unsafe();
                d.check();
                return b.request;
            }));
        }
    }
    async persistTerminal(r: MonthlyRequest, outcome: BrokerTerminalOutcome, settlement: SettlementIntent): Promise<void> {
        const h = this.owned(r), d = this.cleanup(r);
        if (!h.mayWriteOutcome && r.state !== 'terminal')
            unsafe();
        const saved = structuredClone(outcome);
        const next = await this.cleanupTransaction(r, async (tx, d) => {
            const b = await this.book(tx, r.requestFingerprint, r.originalMonth, d, true);
            if (!b.request || !b.ledger)
                unsafe();
            this.sameOwner(b.request, r);
            if (b.request.state === 'terminal') {
                if (digest(b.request.terminal_outcome) !== digest(saved) || (b.request.settlement_state.includes('refund') ? 'refund' : 'finalize') !== settlement)
                    unsafe();
                return b.request;
            }
            if (b.request.state === 'dispatch_intent' && !h.consumed && h.attempted === false)
                unsafe();
            b.request.state = 'terminal';
            b.request.terminal_outcome = saved;
            b.request.settlement_state = settlement === 'refund' ? 'pending_refund' : 'pending_finalize';
            b.account.inFlight!.phase = 'terminal_pending_settlement';
            d.check();
            this.writeBook(tx, b);
            return b.request;
        }, actual => actual.state === 'terminal' && digest(actual.terminal_outcome) === digest(saved) && (actual.settlement_state.includes('refund') ? 'refund' : 'finalize') === settlement);
        Object.assign(r, next);
    }
    async settle(r: MonthlyRequest): Promise<void> {
        const d = this.cleanup(r);
        const next = await this.cleanupTransaction(r, async (tx, d) => {
            const b = await this.book(tx, r.requestFingerprint, r.originalMonth, d, true);
            if (!b.request || !b.ledger)
                unsafe();
            this.sameOwner(b.request, r);
            if (['refunded', 'finalized'].includes(b.request.settlement_state))
                return b.request;
            if (b.request.state !== 'terminal' || !['pending_refund', 'pending_finalize'].includes(b.request.settlement_state))
                unsafe();
            const kind = b.request.settlement_state === 'pending_refund' ? 'refund' : 'finalize';
            this.totals(b, kind);
            b.request.settlement_state = kind === 'refund' ? 'refunded' : 'finalized';
            b.ledger.state = b.request.settlement_state;
            if (kind === 'refund')
                b.ledger.refundReason = b.request.terminal_outcome!.kind === 'error' ? b.request.terminal_outcome!.failure.condition : 'known_terminal';
            b.account.inFlight = null;
            d.check();
            this.writeBook(tx, b);
            return b.request;
        }, actual => ['refunded', 'finalized'].includes(actual.settlement_state) && digest(actual.terminal_outcome) === digest(r.terminal_outcome));
        Object.assign(r, next);
    }
    async dispatch(r: MonthlyRequest, request: BrokerRequest, provider: ProviderClient, completeLate: (result: ProviderResearchResult) => Promise<BrokerResult>): Promise<MonthlyDispatchOutcome> {
        const h = this.owned(r);
        if (h.attempted || !h.mayWriteOutcome)
            return { kind: 'outcome_unknown' };
        h.attempted = true;
        const frozenRequest = structuredClone(request);
        if (validateCanonicalPayloadV1(frozenRequest) !== undefined || frozenRequest.request_id !== r.request_id || frozenRequest.payload_hash !== r.payload_hash)
            return this.noDispatch(r);
        let cap: number, verifiedAt: number;
        try {
            const result = await this.d.run(() => this.o.database.transaction(async (tx) => {
                const b = await this.book(tx, r.requestFingerprint, r.originalMonth, this.d);
                if (!b.request || !b.ledger)
                    unsafe();
                this.sameOwner(b.request, r);
                if (b.request.state !== 'reserved' || this.o.now() < b.request.reservedAtMs)
                    unsafe();
                const e = await this.o.identityService.readAccountingEligibility(tx, this.o.identity, this.d);
                if (!e || b.control.breakerOpen || e.fence.assertionId !== r.authority.assertionId || e.fence.consentRevision !== r.authority.consentRevision || e.fence.registrationGeneration !== r.authority.registrationGeneration || e.fence.lifecycleEpoch !== r.authority.lifecycleEpoch || e.fence.lifecycleGeneration !== r.authority.lifecycleGeneration || this.o.identityService.accountingPolicyId() !== r.authority.admissionPolicyId)
                    unsafe();
                const cap = Math.min(this.d.expiresAt, r.leaseExpiresAtMs, e.fence.expiresAt);
                if (this.o.now() < e.fence.verifiedAtMs)
                    unsafe();
                this.d.check(cap);
                if (b.global.totals.dispatchStarts >= this.policy.globalMonthlyDispatchStarts || b.control.totals.dispatchStarts >= this.policy.globalLifetimeDispatchStarts)
                    unsafe();
                b.month.allowanceCeiling = Math.max(b.month.allowanceCeiling, this.policy.allowances[e.planId]);
                this.totals(b, 'dispatch');
                b.request.state = 'dispatch_intent';
                b.account.inFlight!.phase = 'dispatch_intent';
                this.d.check(cap);
                this.writeBook(tx, b);
                return {
                    cap, verifiedAt: e.fence.verifiedAtMs, record: b.request
                };
            }));
            cap = result.cap;
            verifiedAt = result.verifiedAt;
            if (this.o.now() < verifiedAt)
                unsafe();
            this.d.check(cap);
            Object.assign(r, result.record);
        }
        catch {
            return this.noDispatch(r);
        }
        // Nothing awaited between final validation, single consumption and invocation.
        if (request.request_id !== r.request_id || request.payload_hash !== r.payload_hash || digest(request) !== digest(frozenRequest))
            return this.noDispatch(r);
        try {
            this.d.check(cap);
            if (this.o.now() < verifiedAt)
                unsafe();
        }
        catch {
            return this.noDispatch(r);
        }
        h.consumed = true;
        let completion: Promise<ProviderResearchResult>;
        try {
            completion = Promise.resolve(provider.research(frozenRequest)).catch(() => ({ kind: 'failure' as const }));
        }
        catch {
            completion = Promise.resolve({ kind: 'failure' });
        }
        let unknown = false, observed: ProviderResearchResult | undefined;
        const late = (value: ProviderResearchResult) => { void completeLate(value).catch(() => undefined); };
        void completion.then(value => {
            observed = value;
            if (unknown)
                late(value);
        });
        try {
            return { kind: 'provider_result', result: await this.d.run(() => completion, 50000, cap) };
        }
        catch {
            unknown = true;
            if (observed)
                late(observed);
            return { kind: 'outcome_unknown' };
        }
    }
    private async noDispatch(r: MonthlyRequest): Promise<MonthlyDispatchOutcome> {
        const h = this.owned(r);
        if (h.consumed)
            return { kind: 'outcome_unknown' };
        const outcome: BrokerTerminalOutcome = { kind: 'error', failure: { request_id: r.request_id, condition: 'dispatch_persistence_failure' } };
        try {
            await this.persistTerminal(r, outcome, 'refund');
            await this.settle(r);
            return { kind: 'no_dispatch_terminal', outcome };
        }
        catch {
            return { kind: 'outcome_unknown' };
        }
    }
}
