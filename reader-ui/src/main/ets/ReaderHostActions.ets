import { ReaderUnitKey } from '@reader-kit/core'
import { ReaderHostAction } from './ReaderHostAction'

/** Host-authored overflow actions with one identity-preserving dispatcher. */
export class ReaderHostActions {
  private readonly values: ReaderHostAction[]
  private readonly onRequest: (id: string, source: ReaderUnitKey, navigation: number, sourceIndex: number) => void

  constructor(values: ReaderHostAction[],
    onRequest: (id: string, source: ReaderUnitKey, navigation: number, sourceIndex: number) => void) {
    this.values = values.map((value: ReaderHostAction): ReaderHostAction =>
      new ReaderHostAction(value.id, value.label, value.enabled, value.checked, value.busy))
    this.onRequest = onRequest
  }

  items(): ReaderHostAction[] {
    return this.values.map((value: ReaderHostAction): ReaderHostAction =>
      new ReaderHostAction(value.id, value.label, value.enabled, value.checked, value.busy))
  }

  request(id: string, source: ReaderUnitKey, navigation: number, sourceIndex: number): void {
    this.onRequest(id, source.copy(), navigation, sourceIndex)
  }
}
