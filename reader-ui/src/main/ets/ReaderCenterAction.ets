import { ReaderUnitKey } from '@reader-kit/core'

/** Optional host-owned action rendered in the center of reader chrome. */
export class ReaderCenterAction {
  readonly label: ResourceStr
  private readonly onRequest: (source: ReaderUnitKey, navigation: number) => void

  constructor(label: ResourceStr, onRequest: (source: ReaderUnitKey, navigation: number) => void) {
    this.label = label
    this.onRequest = onRequest
  }

  request(source: ReaderUnitKey, navigation: number): void {
    this.onRequest(source.copy(), navigation)
  }
}
