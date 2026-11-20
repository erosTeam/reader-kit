import { abilityAccessCtrl, common } from '@kit.AbilityKit'
import { display } from '@kit.ArkUI'
import { uiEffect } from '@kit.ArkGraphics2D'
import { deviceInfo } from '@kit.BasicServicesKit'
import { image } from '@kit.ImageKit'

const HDR_BRIGHTNESS_PERMISSION = 'ohos.permission.HDR_BRIGHTNESS'
const READER_HDR_BRIGHTNESS_RATIO = 1.5
const HDR_RAMP_DURATION_MS = 280
const MAX_HDR_PAGE_PIXELS = 12 * 1024 * 1024

let hdrBrightnessFilter: uiEffect.Filter | undefined

function readerHdrBrightnessFilter(): uiEffect.Filter {
  if (hdrBrightnessFilter === undefined) {
    hdrBrightnessFilter = uiEffect.createFilter().hdrBrightnessRatio(READER_HDR_BRIGHTNESS_RATIO)
  }
  return hdrBrightnessFilter
}

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

interface ReaderHdrPage {
  readonly pixels: image.PixelMap
  readonly reduced: boolean
  readonly overBudget: boolean
}

async function decodeReaderHdrPage(path: string, preserveSourceResolution: boolean,
  continuousPreviewScale: number, current: () => boolean): Promise<ReaderHdrPage | undefined> {
  let source: image.ImageSource | undefined
  let page: image.PixelMap | undefined
  try {
    source = image.createImageSource(path)
    const info = await source.getImageInfo()
    const size = info.size
    if (!current() || info.isHdr || size.width <= 0 || size.height <= 0) return
    const pixels = size.width * size.height
    const overBudget = pixels > MAX_HDR_PAGE_PIXELS
    if ((overBudget && preserveSourceResolution) || await source.getFrameCount() !== 1 || !current()) return
    const options: image.DecodingOptions = { desiredDynamicRange: image.DecodingDynamicRange.HDR }
    // A fitted enhanced webtoon row already has a decode tier for its visible
    // pixels. Use the same tier for the HDR overlay to bound both buffers.
    // Zoom keeps the original resolution or uses the existing native fallback.
    const budgetScale = overBudget ? Math.sqrt(MAX_HDR_PAGE_PIXELS / pixels) : 1
    const scale = preserveSourceResolution ? 1 : Math.min(budgetScale, continuousPreviewScale)
    const reduced = scale < 1
    if (reduced) {
      options.desiredSize = {
        width: Math.max(1, Math.floor(size.width * scale)),
        height: Math.max(1, Math.floor(size.height * scale)),
      }
    }
    page = await source.createPixelMap(options)
    const decoded = page.getImageInfoSync()
    if (!decoded.isHdr || decoded.size.width * decoded.size.height > MAX_HDR_PAGE_PIXELS || !current()) return
    const result: ReaderHdrPage = { pixels: page, reduced, overBudget }
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
  @Require @Param logicalPageKey: string
  @Param preserveSourceResolution: boolean = false
  @Param continuousPreviewScale: number = 1
  @Param imageFit: ImageFit = ImageFit.Contain
  @Param imageInterpolation: ImageInterpolation = ImageInterpolation.Low
  @Event onReady: (identity: string) => void = () => {}
  @Event onOpaque: (identity: string) => void = () => {}
  @Event onClear: (identity: string) => void = () => {}
  @Local private page?: image.PixelMap = undefined
  private displayedPageKey: string = ''
  private acceptedAssetIdentity: string = ''
  private retiredPixels?: image.PixelMap = undefined
  private pageReduced: boolean = false
  private pageOverBudget: boolean = false
  private acceptedPreviewScale: number = 1
  private generation: number = 0
  private mounted: boolean = false
  @Local private blendOpacity: number = 0
  private rampStarted: boolean = false
  private rampEpoch: number = 0
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

  @Monitor('logicalPageKey', 'identity', 'preserveSourceResolution', 'continuousPreviewScale')
  onOriginalChanged(): void {
    if (this.page !== undefined && this.displayedPageKey === this.logicalPageKey && this.acceptedAssetIdentity === this.identity &&
      (!this.pageReduced || (!this.preserveSourceResolution && this.continuousPreviewScale <= this.acceptedPreviewScale))) return
    this.prepare()
  }

  private clear(): void {
    const previous = this.page
    const key = this.displayedPageKey
    this.page = undefined
    this.displayedPageKey = ''
    this.acceptedAssetIdentity = ''
    this.pageReduced = false
    this.pageOverBudget = false
    this.rampEpoch++
    this.rampStarted = false
    this.blendOpacity = 0
    if (key.length > 0) this.onClear(key)
    if (previous !== undefined) void releaseHdrPage(previous)
    this.releaseRetiredPixels()
  }

  private releaseRetiredPixels(): void {
    const previous = this.retiredPixels
    this.retiredPixels = undefined
    if (previous !== undefined) void releaseHdrPage(previous)
  }

  private imageReady(): void {
    if (!this.mounted || this.displayedPageKey !== this.logicalPageKey) return
    this.releaseRetiredPixels()
    if (this.rampStarted) return
    this.rampStarted = true
    const key = this.displayedPageKey
    const epoch = this.rampEpoch
    this.onReady(key)
    // Keep one fixed HDR filter and blend over the displayed SDR original.
    // The compositor advances opacity without a per-frame ArkTS filter update.
    // A same-page super-resolution replacement keeps the current blend.
    this.getUIContext().animateTo({
      duration: HDR_RAMP_DURATION_MS,
      curve: Curve.EaseInOut,
      onFinish: (): void => {
        if (this.mounted && this.rampEpoch === epoch && this.logicalPageKey === key) this.onOpaque(key)
      },
    }, (): void => {
      this.blendOpacity = 1
    })
  }

  private prepare(): void {
    const generation = ++this.generation
    const key = this.logicalPageKey
    const preserveSourceResolution = this.preserveSourceResolution
    const previewScale = this.continuousPreviewScale
    // Keep the current HDR blend while a fitted page requests full pixels.
    // Oversized sources still hand zoom back to the full-resolution native image.
    if (key !== this.displayedPageKey || (preserveSourceResolution && this.pageOverBudget)) this.clear()
    if (!this.mounted || !this.uri.startsWith('file:///')) {
      this.clear()
      return
    }
    const path = this.uri.slice('file://'.length)
    const identity = this.identity
    const current = (): boolean => this.mounted && this.generation === generation && this.identity === identity &&
      this.logicalPageKey === key && this.preserveSourceResolution === preserveSourceResolution &&
      this.continuousPreviewScale === previewScale
    try {
      this.filter = readerHdrBrightnessFilter()
    } catch (_) {
      return
    }
    hdrDecodeTail = hdrDecodeTail.then(async (): Promise<void> => {
      if (!current()) return
      const result = await decodeReaderHdrPage(path, preserveSourceResolution, previewScale, current)
      if (result === undefined) {
        if (current()) this.clear()
        return
      }
      if (!current()) {
        await releaseHdrPage(result.pixels)
        return
      }
      this.releaseRetiredPixels()
      this.retiredPixels = this.page
      this.displayedPageKey = key
      this.acceptedAssetIdentity = identity
      this.pageReduced = result.reduced
      this.pageOverBudget = result.overBudget
      this.acceptedPreviewScale = previewScale
      this.page = result.pixels
    })
  }

  build() {
    if (this.page !== undefined && this.displayedPageKey === this.logicalPageKey && this.filter !== undefined) {
      Image(this.page)
        .width('100%').height('100%')
        .objectFit(this.imageFit)
        .interpolation(this.imageInterpolation)
        .id('rkit-auto-hdr-image')
        .hdrBrightness(1)
        .foregroundFilter(this.filter)
        .opacity(this.blendOpacity)
        .hitTestBehavior(HitTestMode.None)
        .onComplete((event): void => {
          if (event?.loadingStatus === 1) this.imageReady()
        })
        .onError((): void => { this.clear() })
    }
  }
}
