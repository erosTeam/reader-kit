import { AppStorageV2 } from '@kit.ArkUI'
import { Want } from '@kit.AbilityKit'

export class ReaderLabRequest {
  work: string
  unit: string
  pageIndex: number
  failurePage: number
  delayedMetricsPage: number
  failureLayout: string
  readingChrome: boolean = false
  thumbnailFailurePage: number = -1
  volumeKeys: boolean = false

  constructor(work: string, unit: string, pageIndex: number, failurePage: number = -1,
    delayedMetricsPage: number = -1, failureLayout: string = 'continuous') {
    this.work = work
    this.unit = unit
    this.pageIndex = pageIndex
    this.failurePage = failurePage
    this.delayedMetricsPage = delayedMetricsPage
    this.failureLayout = failureLayout
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
  const failurePage = want.parameters['readerLabFailPage']
  const delayedPage = want.parameters['readerLabDelayMetricsPage']
  const failureLayout = want.parameters['readerLabFailureLayout']
  if (typeof work !== 'string' || work.length === 0) return
  const index = typeof page === 'string' ? Number(page) : (typeof page === 'number' ? page : 0)
  const failureIndex = typeof failurePage === 'string' ? Number(failurePage) :
    (typeof failurePage === 'number' ? failurePage : -1)
  const delayedIndex = typeof delayedPage === 'string' ? Number(delayedPage) :
    (typeof delayedPage === 'number' ? delayedPage : -1)
  const request = new ReaderLabRequest(
    work, typeof unit === 'string' ? unit : '',
    Number.isFinite(index) ? Math.max(0, Math.floor(index)) : 0,
    Number.isSafeInteger(failureIndex) && failureIndex >= 0 ? failureIndex : -1,
    Number.isSafeInteger(delayedIndex) && delayedIndex >= 0 ? delayedIndex : -1,
    failureLayout === 'single' ? 'single' : failureLayout === 'spread' ? 'spread' : 'continuous',
  )
  request.readingChrome = want.parameters['readerLabChrome'] === 'true' || want.parameters['readerLabChrome'] === true
  const thumbnailFailure = want.parameters['readerLabFailThumbnailPage']
  const thumbnailIndex = typeof thumbnailFailure === 'string' ? Number(thumbnailFailure) :
    (typeof thumbnailFailure === 'number' ? thumbnailFailure : -1)
  request.thumbnailFailurePage = Number.isSafeInteger(thumbnailIndex) && thumbnailIndex >= 0 ? thumbnailIndex : -1
  request.volumeKeys = want.parameters['readerLabVolumeKeys'] === 'true' || want.parameters['readerLabVolumeKeys'] === true
  connectReaderLabLaunch().publish(request)
}
