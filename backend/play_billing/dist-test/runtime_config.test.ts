import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import {
  matchesApprovedAppId,
  resolveApprovedAppId,
  type StringParameter,
} from '../src/runtime_config.js';

class FakeStringParameter implements StringParameter {
  constructor(private readonly configuredValue: unknown, private readonly shouldThrow = false) {}

  value(): unknown {
    if (this.shouldThrow) {
      throw new Error('parameter unavailable');
    }
    return this.configuredValue;
  }
}

describe('Play Billing runtime configuration', () => {
  test('fails closed when the approved App Check application parameter is missing', () => {
    const approvedAppId = resolveApprovedAppId(new FakeStringParameter(undefined));

    assert.equal(approvedAppId, undefined);
    assert.equal(matchesApprovedAppId(approvedAppId, 'configured-app'), false);
  });

  test('fails closed when the approved App Check application parameter cannot resolve', () => {
    const approvedAppId = resolveApprovedAppId(new FakeStringParameter(undefined, true));

    assert.equal(approvedAppId, undefined);
    assert.equal(matchesApprovedAppId(approvedAppId, 'configured-app'), false);
  });

  test('fails closed for a mismatched App Check application and accepts only an exact match', () => {
    const approvedAppId = resolveApprovedAppId(new FakeStringParameter('configured-app'));

    assert.equal(matchesApprovedAppId(approvedAppId, 'other-app'), false);
    assert.equal(matchesApprovedAppId(approvedAppId, 'configured-app'), true);
  });
});
