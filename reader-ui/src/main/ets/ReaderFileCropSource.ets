import { taskpool } from '@kit.ArkTS'
import { image } from '@kit.ImageKit'
import { ReaderImageCropBounds, ReaderImageCropDetector, ReaderImageCropSource } from '@reader-kit/core'

const READER_FILE_CROP_CACHE_LIMIT: number = 256

@Concurrent
async function detectReaderFileCrop(path: string): Promise<string> {
  let source: image.ImageSource | undefined = undefined
  let pixelMap: image.PixelMap | undefined = undefined
  try {
    source = image.createImageSource(path)
    const sourceInfo = await source.getImageInfo()
    const sourceWidth = Math.floor(sourceInfo.size.width)
    const sourceHeight = Math.floor(sourceInfo.size.height)
    if (sourceWidth <= 0 || sourceHeight <= 0) return '0,0,0,0'
    const scale = Math.max(sourceWidth, sourceHeight) > 256 ? 256 / Math.max(sourceWidth, sourceHeight) : 1
    const options: image.DecodingOptions = { editable: false, desiredPixelFormat: image.PixelMapFormat.RGBA_8888 }
    if (scale < 1) options.desiredSize = {
      width: Math.max(1, Math.round(sourceWidth * scale)),
      height: Math.max(1, Math.round(sourceHeight * scale)),
    }
    pixelMap = await source.createPixelMap(options)
    const info = await pixelMap.getImageInfo()
    const width = Math.floor(info.size.width), height = Math.floor(info.size.height)
    const stride = Math.max(Math.floor(info.stride), width * 4)
    const buffer = new ArrayBuffer(pixelMap.getPixelBytesNumber())
    await pixelMap.readPixelsToBuffer(buffer)
    const result = ReaderImageCropDetector.detect(width, height, stride, new Uint8Array(buffer))
    return `${result.left},${result.top},${result.right},${result.bottom}`
  } catch (_error) {
    return '0,0,0,0'
  } finally {
    if (pixelMap !== undefined) await pixelMap.release()
    if (source !== undefined) await source.release()
  }
}

/** File-backed crop detection with shared in-flight work and bounded LRU caching. */
export class ReaderFileCropSource implements ReaderImageCropSource {
  private static cache: Map<string, ReaderImageCropBounds> = new Map()
  private static inFlight: Map<string, Promise<ReaderImageCropBounds>> = new Map()
  private path: string
  private identity: string

  constructor(uri: string, identity: string = uri) {
    this.path = uri.startsWith('file://') ? uri.substring('file://'.length) : uri
    this.identity = identity
  }

  read(): Promise<ReaderImageCropBounds> {
    if (this.path.length === 0 || this.identity.length === 0) return Promise.resolve(new ReaderImageCropBounds())
    const key = `${this.path}|${this.identity}`
    const cached = ReaderFileCropSource.cache.get(key)
    if (cached !== undefined) {
      ReaderFileCropSource.cache.delete(key)
      ReaderFileCropSource.cache.set(key, cached)
      return Promise.resolve(cached.copy())
    }
    const active = ReaderFileCropSource.inFlight.get(key)
    if (active !== undefined) return active.then((bounds: ReaderImageCropBounds): ReaderImageCropBounds => bounds.copy())
    const task = ReaderFileCropSource.detect(this.path)
    ReaderFileCropSource.inFlight.set(key, task)
    task.then((bounds: ReaderImageCropBounds): void => {
      if (ReaderFileCropSource.inFlight.get(key) === task) ReaderFileCropSource.inFlight.delete(key)
      ReaderFileCropSource.cache.set(key, bounds.copy())
      while (ReaderFileCropSource.cache.size > READER_FILE_CROP_CACHE_LIMIT) {
        const oldest = ReaderFileCropSource.cache.keys().next().value as string | undefined
        if (oldest === undefined) break
        ReaderFileCropSource.cache.delete(oldest)
      }
    })
    return task.then((bounds: ReaderImageCropBounds): ReaderImageCropBounds => bounds.copy())
  }

  private static async detect(path: string): Promise<ReaderImageCropBounds> {
    try {
      const serialized = await taskpool.execute<[string], string>(detectReaderFileCrop, path)
      const values = serialized.split(',').map((value: string): number => Number(value))
      return values.length === 4 ? new ReaderImageCropBounds(values[0], values[1], values[2], values[3]) :
        new ReaderImageCropBounds()
    } catch (_error) {
      return new ReaderImageCropBounds()
    }
  }
}
