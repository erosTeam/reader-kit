import { abilityAccessCtrl, common } from '@kit.AbilityKit'
import { display } from '@kit.ArkUI'
import { uiEffect } from '@kit.ArkGraphics2D'
import { deviceInfo } from '@kit.BasicServicesKit'
import { image } from '@kit.ImageKit'

const HDR_BRIGHTNESS_PERMISSION = 'ohos.permission.HDR_BRIGHTNESS'
const READER_HDR_BRIGHTNESS_RATIO = 2.0
const MAX_HDR_PAGE_PIXELS = 12 * 1024 * 1024

export function readerHdrBrightnessAvailable(context?: common.Context): boolean {
  if (deviceInfo.sdkApiVersion < 24 || context === undefined) return false
  try {
    const granted = abilityAccessCtrl.createAtManager().checkAccessTokenSync(
      context.applicationInfo.accessTokenId, HDR_BRIGHTNESS_PERMISSION
    ) === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED
    if (!granted) return false
    const screen = display.getDefaultDisplaySync()
    return screen.hdrFormats.length > 0 || display.getBrightnessInfo(screen.id).maxHeadroom > 1
  } catch (_) {
    return false
  }
}

// A long continuous viewport can expose several originals at once. Decode
// only one HDR page at a time, and discard queued work once its leaf goes away.
let hdrDecodeTail: Promise<void> = Promise.resolve()

async function releaseHdrPage(page: image.PixelMap): Promise<void> {
  try { await page.release() } catch (_) {}
}

async function decodeReaderHdrPage(path: string, current: () => boolean): Promise<image.PixelMap | undefined> {
  let source: image.ImageSource | undefined
  let page: image.PixelMap | undefined
  try {
    source = image.createImageSource(path)
    const info = await source.getImageInfo()
    const size = info.size
    // Keep native-resolution pixels for zoom. Existing HDR, oversized and animated pages
    // continue through ArkUI's original image path.
    if (!current() || info.isHdr || size.width <= 0 || size.height <= 0 ||
      size.width * size.height > MAX_HDR_PAGE_PIXELS || await source.getFrameCount() !== 1 || !current()) return
    page = await source.createPixelMap({ desiredDynamicRange: image.DecodingDynamicRange.HDR })
    if (!page.getImageInfoSync().isHdr || !current()) return
    const result = page
    page = undefined
    return result
  } catch (_) {
    return undefined
  } finally {
    if (page !== undefined) await releaseHdrPage(page)
    try { await source?.release() } catch (_) {}
  }
}

/** A display-only replacement over one already loaded native original. */
@ComponentV2
export struct ReaderHdrImage {
  @Require @Param uri: string
  @Require @Param identity: string
  @Param imageFit: ImageFit = ImageFit.Contain
  @Param imageInterpolation: ImageInterpolation = ImageInterpolation.Low
  @Event onReady: (identity: string) => void = () => {}
  @Event onClear: (identity: string) => void = () => {}
  @Local private page?: image.PixelMap = undefined
  private pageIdentity: string = ''
  private generation: number = 0
  private mounted: boolean = false
  private filter?: uiEffect.Filter = undefined

  aboutToAppear(): void {
    this.mounted = true
    this.prepare()
  }

  aboutToDisappear(): void {
    this.mounted = false
    this.generation++
    this.clear()
  }

  @Monitor('identity')
  onOriginalChanged(): void { this.prepare() }

  private clear(): void {
    const previous = this.page
    const identity = this.pageIdentity
    this.page = undefined
    this.pageIdentity = ''
    if (identity.length > 0) this.onClear(identity)
    if (previous !== undefined) void releaseHdrPage(previous)
  }

  private prepare(): void {
    const generation = ++this.generation
    this.clear()
    if (!this.mounted || !this.uri.startsWith('file:///')) return
    const path = this.uri.slice('file://'.length)
    const identity = this.identity
    const current = (): boolean => this.mounted && this.generation === generation && this.identity === identity
    try {
      if (this.filter === undefined) {
        this.filter = uiEffect.createFilter().hdrBrightnessRatio(READER_HDR_BRIGHTNESS_RATIO)
      }
    } catch (_) {
      return
    }
    hdrDecodeTail = hdrDecodeTail.then(async (): Promise<void> => {
      if (!current()) return
      const result = await decodeReaderHdrPage(path, current)
      if (result === undefined) return
      if (!current()) {
        await releaseHdrPage(result)
        return
      }
      this.pageIdentity = identity
      this.page = result
    })
  }

  build() {
    if (this.page !== undefined && this.pageIdentity === this.identity && this.filter !== undefined) {
      Image(this.page)
        .width('100%').height('100%')
        .objectFit(this.imageFit)
        .interpolation(this.imageInterpolation)
        .hdrBrightness(1)
        .foregroundFilter(this.filter)
        .hitTestBehavior(HitTestMode.None)
        .onComplete((event): void => {
          if (event?.loadingStatus === 1 && this.mounted && this.pageIdentity === this.identity) {
            this.onReady(this.pageIdentity)
          }
        })
        .onError((): void => { this.clear() })
    }
  }
}
