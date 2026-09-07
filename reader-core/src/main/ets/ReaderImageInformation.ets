/** Facts about the retained loaded file, never catalog or thumbnail geometry. */
export class ReaderImageInformation {
  mimeType: string = ''
  bytes: number = 0
  width: number = 0
  height: number = 0
  variant: 'unknown' | 'source' | 'resampled' | 'original' | 'enhanced' | 'translated' = 'unknown'
  originalAvailable: boolean | null = null

  copy(): ReaderImageInformation {
    const value = new ReaderImageInformation()
    value.mimeType = this.mimeType
    value.bytes = this.bytes
    value.width = this.width
    value.height = this.height
    value.variant = this.variant
    value.originalAvailable = this.originalAvailable
    return value
  }
}

/** Optional, asset-bound read-only capability. Reading it must not fetch another image. */
export interface ReaderImageInformationSource {
  read(): Promise<ReaderImageInformation>
}
