import { ReaderImageCropBounds, ReaderImageCropSource } from '@reader-kit/core'
import { ReaderFileCropService } from './ReaderFileCropService'

/** File-backed crop port. The shared service owns decoding/cache; the caller owns its file lease. */
export class ReaderFileCropSource implements ReaderImageCropSource {
  private path: string
  private identity: string

  constructor(uri: string, identity: string = uri) {
    this.path = uri.startsWith('file://') ? uri.substring('file://'.length) : uri
    this.identity = identity
  }

  read(): Promise<ReaderImageCropBounds> {
    return ReaderFileCropService.detectLegacy(this.path, this.identity)
  }
}
