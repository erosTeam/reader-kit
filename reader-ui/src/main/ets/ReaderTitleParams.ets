import { ReaderUnitKey } from '@reader-kit/core'

/** Read-only current-position projection for a host-owned title leaf. */
export interface ReaderTitleParams {
  unitKey: ReaderUnitKey | null
  pageIndex: number
  pageCount: number
}
