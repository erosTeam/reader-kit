import { ReaderImageInformation, ReaderImageSaveHost, ReaderImageShareHost, ReaderPagedFrame } from '@reader-kit/core'

/**
 * Host-provided operations for the currently displayed image.
 *
 * This is deliberately narrower than a reader host adapter: route, settings,
 * chapters, persistence, and lifecycle remain separate capabilities.
 */
export class ReaderMediaActions {
  readonly imageShare: ReaderImageShareHost | null
  readonly imageSave: ReaderImageSaveHost | null
  readonly informationSupplement: ((frame: ReaderPagedFrame, value: ReaderImageInformation) => string[]) | null

  constructor(imageShare: ReaderImageShareHost | null = null,
    imageSave: ReaderImageSaveHost | null = null,
    informationSupplement: ((frame: ReaderPagedFrame, value: ReaderImageInformation) => string[]) | null = null) {
    this.imageShare = imageShare
    this.imageSave = imageSave
    this.informationSupplement = informationSupplement
  }
}
