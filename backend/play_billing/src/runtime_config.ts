export interface StringParameter {
  value(): unknown;
}

export function resolveApprovedAppId(parameter: StringParameter): string | undefined {
  try {
    const value = parameter.value();
    return typeof value === 'string' && value.length > 0 ? value : undefined;
  } catch {
    return undefined;
  }
}

export function matchesApprovedAppId(approvedAppId: string | undefined, appId: unknown): boolean {
  return typeof appId === 'string' && approvedAppId !== undefined && appId === approvedAppId;
}
