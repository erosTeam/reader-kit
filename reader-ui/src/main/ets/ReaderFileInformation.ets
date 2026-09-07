import { image } from '@kit.ImageKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { ReaderImageInformation, ReaderImageInformationSource } from '@reader-kit/core'

/** Platform read-only adapter for the host-owned retained file. No second network request. */
export class ReaderFileInformation implements ReaderImageInformationSource {
  private path: string
  private facts: ReaderImageInformation

  constructor(path: string, facts: ReaderImageInformation) {
    this.path = path
    this.facts = facts.copy()
  }

  async read(): Promise<ReaderImageInformation> {
    let source: image.ImageSource | null = null
    try {
      source = image.createImageSource(this.path)
      const decoded = await source.getImageInfo()
      const value = this.facts.copy()
      value.mimeType = decoded.mimeType
      value.width = decoded.size.width
      value.height = decoded.size.height
      return value
    } catch (error) {
      console.warn(`[ReaderFileInformation] header_read_failed code=${(error as BusinessError).code ?? 0}`)
      throw new Error('reader_metadata_header_read_failed')
    } finally {
      if (source !== null) await source.release()
    }
  }
}
