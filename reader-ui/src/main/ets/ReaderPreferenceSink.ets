import { ReaderDisplayPolicy } from '@reader-kit/core'
import { ReaderRuntimePolicyIntent } from './ReaderChrome'

/** Host-owned destination for adopted reader display preference changes. */
export class ReaderPreferenceSink {
  private readonly onPolicy: ((policy: ReaderDisplayPolicy, intent: ReaderRuntimePolicyIntent) => void) | null
  private readonly onCrop: ((enabled: boolean, policy: ReaderDisplayPolicy) => void) | null

  constructor(onPolicy: ((policy: ReaderDisplayPolicy, intent: ReaderRuntimePolicyIntent) => void) | null = null,
    onCrop: ((enabled: boolean, policy: ReaderDisplayPolicy) => void) | null = null) {
    this.onPolicy = onPolicy
    this.onCrop = onCrop
  }

  policyChanged(policy: ReaderDisplayPolicy, intent: ReaderRuntimePolicyIntent): void {
    this.onPolicy?.(policy.copy(), intent)
  }

  cropChanged(enabled: boolean, policy: ReaderDisplayPolicy): void {
    this.onCrop?.(enabled, policy.copy())
  }
}
