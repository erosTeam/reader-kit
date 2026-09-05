import { AppStorageV2 } from '@kit.ArkUI'
import { Want } from '@kit.AbilityKit'

export class ReaderLabRequest {
  work: string
  unit: string
  pageIndex: number

  constructor(work: string, unit: string, pageIndex: number) {
    this.work = work
    this.unit = unit
    this.pageIndex = pageIndex
  }
}

@ObservedV2
export class ReaderLabLaunchState {
  @Trace version: number = 0
  private pending: ReaderLabRequest | null = null

  publish(request: ReaderLabRequest): void {
    this.pending = request
    this.version += 1
  }

  consume(): ReaderLabRequest | null {
    const request = this.pending
    this.pending = null
    return request
  }
}

export function connectReaderLabLaunch(): ReaderLabLaunchState {
  return AppStorageV2.connect(ReaderLabLaunchState, () => new ReaderLabLaunchState())!
}

/** No URL interception, persisted preference or release entry. Explicit debug Want only. */
export function captureReaderLabWant(want: Want, debugBuild: boolean): void {
  if (!debugBuild || want.parameters === undefined) return
  const work = want.parameters['readerLabWork']
  const unit = want.parameters['readerLabUnit']
  const page = want.parameters['readerLabPage']
  if (typeof work !== 'string' || work.length === 0) return
  const index = typeof page === 'string' ? Number(page) : (typeof page === 'number' ? page : 0)
  connectReaderLabLaunch().publish(new ReaderLabRequest(
    work, typeof unit === 'string' ? unit : '',
    Number.isFinite(index) ? Math.max(0, Math.floor(index)) : 0,
  ))
}
