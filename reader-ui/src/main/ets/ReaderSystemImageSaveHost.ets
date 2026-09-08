import { common } from '@kit.AbilityKit'
import { fileIo, fileUri } from '@kit.CoreFileKit'
import { image } from '@kit.ImageKit'
import { photoAccessHelper } from '@kit.MediaLibraryKit'
import { ReaderCancellation, ReaderImageSaveHost, ReaderImageSaveTarget,
  ReaderImageSavePresentation, ReaderImageSaveItemResult } from '@reader-kit/core'

function closeFile(file: fileIo.File | null): void {
  if (file === null) return
  try { fileIo.closeSync(file) } catch (_) { console.warn('[ReaderImageSave] file close failed') }
}

class SaveFile {
  sourceIndex: number
  directory: string
  path: string
  extension: string = ''
  title: string
  constructor(sourceIndex: number, directory: string, title: string) {
    this.sourceIndex = sourceIndex
    this.directory = directory
    this.path = directory + '/image'
    this.title = title
  }
  release(): void {
    try { fileIo.unlinkSync(this.path) } catch (_) { /* A failed copy may not create a file. */ }
    try { fileIo.rmdirSync(this.directory) } catch (_) {
      console.warn('[ReaderImageSave] temporary cleanup failed')
    }
  }
}

function extensionFor(mime: string): string {
  switch (mime.toLowerCase()) {
    case 'image/jpeg': return 'jpg'
    case 'image/png': return 'png'
    case 'image/gif': return 'gif'
    case 'image/webp': return 'webp'
    case 'image/bmp': return 'bmp'
    case 'image/heic': return 'heic'
    case 'image/heif': return 'heif'
    default: throw new Error('reader_save_unsupported_image_format')
  }
}

class SystemSavePresentation implements ReaderImageSavePresentation {
  private context: common.UIAbilityContext
  private files: SaveFile[]
  private started: boolean = false
  private running: boolean = false
  private released: boolean = false
  constructor(context: common.UIAbilityContext, files: SaveFile[]) {
    this.context = context
    this.files = files
  }
  async present(): Promise<ReaderImageSaveItemResult[]> {
    if (this.started || this.released) throw new Error('reader_save_unavailable')
    this.started = true
    this.running = true
    let helper: photoAccessHelper.PhotoAccessHelper | null = null
    try {
      helper = photoAccessHelper.getPhotoAccessHelper(this.context)
      const uris = this.files.map((item: SaveFile): string => fileUri.getUriFromPath(item.path))
      const configs: photoAccessHelper.PhotoCreationConfig[] = this.files.map((item: SaveFile): photoAccessHelper.PhotoCreationConfig => ({
        title: item.title, fileNameExtension: item.extension, photoType: photoAccessHelper.PhotoType.IMAGE
      }))
      const destinations = await helper.showAssetsCreationDialog(uris, configs)
      if (destinations.length === 0) {
        return this.files.map((item: SaveFile) => new ReaderImageSaveItemResult(item.sourceIndex, 'cancelled'))
      }
      const results: ReaderImageSaveItemResult[] = []
      for (let i = 0; i < this.files.length; i++) {
        const item = this.files[i]
        let source: fileIo.File | null = null
        let destination: fileIo.File | null = null
        try {
          const uri = destinations[i]
          if (!uri || !uri.startsWith('file://')) throw new Error('reader_save_invalid_destination')
          source = fileIo.openSync(item.path, fileIo.OpenMode.READ_ONLY)
          destination = fileIo.openSync(uri, fileIo.OpenMode.WRITE_ONLY)
          await fileIo.copyFile(source.fd, destination.fd)
          results.push(new ReaderImageSaveItemResult(item.sourceIndex, 'saved'))
        } catch (_) {
          results.push(new ReaderImageSaveItemResult(item.sourceIndex, 'failed'))
        } finally {
          closeFile(source)
          closeFile(destination)
        }
      }
      return results
    } finally {
      if (helper !== null) {
        try { await helper.release() } catch (_) { console.warn('[ReaderImageSave] helper release failed') }
      }
      this.running = false
      if (this.released) this.cleanup()
    }
  }
  private cleanup(): void {
    this.files.forEach((item: SaveFile): void => item.release())
    this.files = []
  }
  release(): void {
    if (this.released) return
    this.released = true
    // A system dialog or copy can still be reading our independent files.
    if (!this.running) this.cleanup()
  }
}

/** Owns only per-operation copies, never reader cache/download files. */
export class ReaderSystemImageSaveHost implements ReaderImageSaveHost {
  private context: common.UIAbilityContext
  private download: ((uri: string, path: string) => Promise<void>) | null
  constructor(context: common.UIAbilityContext,
    download: ((uri: string, path: string) => Promise<void>) | null = null) {
    this.context = context
    this.download = download
  }
  async prepare(target: ReaderImageSaveTarget, cancellation: ReaderCancellation): Promise<ReaderImageSavePresentation> {
    const captured = target.copy()
    const sources: (fileIo.File | null)[] = []
    const files: SaveFile[] = []
    try {
      cancellation.check()
      if (captured.items.length === 0 || captured.items.length > 100) throw new Error('reader_save_invalid_count')
      // Capture every local FD before yielding: releasing a reader can unlink its asset path.
      for (const item of captured.items) {
        const localPath = item.uri.startsWith('file://') ? new fileUri.FileUri(item.uri).path : item.uri
        sources.push(item.uri.startsWith('file://') || item.uri.startsWith('/') ?
          fileIo.openSync(localPath, fileIo.OpenMode.READ_ONLY) : null)
      }
      for (let i = 0; i < captured.items.length; i++) {
        cancellation.check()
        const item = captured.items[i]
        const work = captured.unit.key.work.replace(/[^a-zA-Z0-9_-]/g, '_').slice(0, 80) || 'reader'
        const owned = new SaveFile(item.sourceIndex,
          fileIo.mkdtempSync(this.context.cacheDir + '/reader-save-XXXXXX'),
          `${work}-${item.sourceIndex + 1}`.slice(0, 96))
        files.push(owned)
        const source = sources[i]
        if (source !== null) await fileIo.copyFile(source.fd, owned.path)
        else if (this.download !== null && (item.uri.startsWith('https://') || item.uri.startsWith('http://'))) {
          await this.download(item.uri, owned.path)
        } else throw new Error('reader_save_source_unavailable')
        cancellation.check()
        const decoder = image.createImageSource(owned.path)
        try { owned.extension = extensionFor((await decoder.getImageInfo()).mimeType) }
        finally { await decoder.release() }
        cancellation.check()
        const finalPath = owned.path + '.' + owned.extension
        fileIo.renameSync(owned.path, finalPath)
        owned.path = finalPath
      }
      return new SystemSavePresentation(this.context, files)
    } catch (_) {
      files.forEach((item: SaveFile): void => item.release())
      throw new Error('reader_save_prepare_failed')
    } finally {
      sources.forEach((source: fileIo.File | null): void => {
        closeFile(source)
      })
    }
  }
}
