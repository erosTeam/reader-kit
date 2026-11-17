import { abilityAccessCtrl, common } from '@kit.AbilityKit'
import { AnimatorResult, display } from '@kit.ArkUI'
import { uiEffect } from '@kit.ArkGraphics2D'
import { deviceInfo } from '@kit.BasicServicesKit'
import { image } from '@kit.ImageKit'

const HDR_BRIGHTNESS_PERMISSION = 'ohos.permission.HDR_BRIGHTNESS'
const READER_HDR_BRIGHTNESS_RATIO = 1.5
const HDR_RAMP_DURATION_MS = 280
const HDR_RATIO_STEPS = 64
const MAX_HDR_PAGE_PIXELS = 12 * 1024 * 1024

let hdrRampFilters: uiEffect.Filter[] | undefined

function readerHdrRampFilters(): uiEffect.Filter[] {
  if (hdrRampFilters !== undefined) return hdrRampFilters
  const filters: uiEffect.Filter[] = []
  for (let step = 0; step <= HDR_RATIO_STEPS; step++) {
    filters.push(uiEffect.createFilter().hdrBrightnessRatio(1 + (READER_HDR_BRIGHTNESS_RATIO - 1) * step / HDR_RATIO_STEPS))
  }
  hdrRampFilters = filters
  return filters
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
}

async function decodeReaderHdrPage(path: string, preserveSourceResolution: boolean,
  current: () => boolean): Promise<ReaderHdrPage | undefined> {
  let source: image.ImageSource | undefined
  let page: image.PixelMap | undefined
  try {
    source = image.createImageSource(path)
    const info = await source.getImageInfo()
    const size = info.size
    if (!current() || info.isHdr || size.width <= 0 || size.height <= 0) return
    const pixels = size.width * size.height
    const reduced = pixels > MAX_HDR_PAGE_PIXELS
    // A super-resolution result can exceed the HDR budget even for a normal
    // page. Use a bounded HDR preview at reading scale and keep the native
    // full-resolution image when the reader requests original pixels for zoom.
    if ((reduced && preserveSourceResolution) || await source.getFrameCount() !== 1 || !current()) return
    const options: image.DecodingOptions = { desiredDynamicRange: image.DecodingDynamicRange.HDR }
    if (reduced) {
      const scale = Math.sqrt(MAX_HDR_PAGE_PIXELS / pixels)
      options.desiredSize = {
        width: Math.max(1, Math.floor(size.width * scale)),
        height: Math.max(1, Math.floor(size.height * scale)),
      }
    }
    page = await source.createPixelMap(options)
    const decoded = page.getImageInfoSync()
    if (!decoded.isHdr || decoded.size.width * decoded.size.height > MAX_HDR_PAGE_PIXELS || !current()) return
    const result: ReaderHdrPage = { pixels: page, reduced }
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
  @Param imageFit: ImageFit = ImageFit.Contain
  @Param imageInterpolation: ImageInterpolation = ImageInterpolation.Low
  @Event onReady: (identity: string) => void = () => {}
  @Event onClear: (identity: string) => void = () => {}
  @Local private page?: image.PixelMap = undefined
  private displayedPageKey: string = ''
  private acceptedAssetIdentity: string = ''
  private retiredPixels?: image.PixelMap = undefined
  private pageReduced: boolean = false
  private generation: number = 0
  private mounted: boolean = false
  @Local private rampProgress: number = 0
  private rampStarted: boolean = false
  private rampAnimator?: AnimatorResult = undefined
  private filters?: uiEffect.Filter[] = undefined

  aboutToAppear(): void {
    this.mounted = true
    this.prepare()
  }

  aboutToDisappear(): void {
    this.mounted = false
    this.generation++
    this.clear()
  }

  @Monitor('logicalPageKey', 'identity', 'preserveSourceResolution')
  onOriginalChanged(): void {
    if (this.page !== undefined && this.displayedPageKey === this.logicalPageKey && this.acceptedAssetIdentity === this.identity &&
      (!this.preserveSourceResolution || !this.pageReduced)) return
    this.prepare()
  }

  private clear(): void {
    const previous = this.page
    const key = this.displayedPageKey
    this.page = undefined
    this.displayedPageKey = ''
    this.acceptedAssetIdentity = ''
    this.pageReduced = false
    this.stopRamp()
    this.rampStarted = false
    this.rampProgress = 0
    if (key.length > 0) this.onClear(key)
    if (previous !== undefined) void releaseHdrPage(previous)
    this.releaseRetiredPixels()
  }

  private releaseRetiredPixels(): void {
    const previous = this.retiredPixels
    this.retiredPixels = undefined
    if (previous !== undefined) void releaseHdrPage(previous)
  }

  private stopRamp(): void {
    const animator = this.rampAnimator
    this.rampAnimator = undefined
    animator?.cancel()
  }

  private imageReady(): void {
    if (!this.mounted || this.displayedPageKey !== this.logicalPageKey) return
    this.releaseRetiredPixels()
    if (this.rampStarted) return
    this.rampStarted = true
    this.onReady(this.displayedPageKey)
    // A single display-paced ramp belongs to this logical page; changing its
    // file (for example when super-resolution finishes) keeps the same ramp.
    const animator = this.getUIContext().createAnimator({
      duration: HDR_RAMP_DURATION_MS, easing: 'ease-in-out', delay: 0,
      fill: 'forwards', direction: 'normal', iterations: 1, begin: 0, end: 1,
    })
    this.rampAnimator = animator
    animator.onFrame = (progress: number): void => {
      if (this.rampAnimator === animator) this.rampProgress = Math.max(0, Math.min(1, progress))
    }
    animator.onFinish = (): void => {
      if (this.rampAnimator !== animator) return
      this.rampAnimator = undefined
      this.rampProgress = 1
    }
    animator.play()
  }

  private prepare(): void {
    const generation = ++this.generation
    const key = this.logicalPageKey
    const preserveSourceResolution = this.preserveSourceResolution
    if (key !== this.displayedPageKey || (preserveSourceResolution && this.pageReduced)) this.clear()
    if (!this.mounted || !this.uri.startsWith('file:///')) {
      this.clear()
      return
    }
    const path = this.uri.slice('file://'.length)
    const identity = this.identity
    const current = (): boolean => this.mounted && this.generation === generation && this.identity === identity &&
      this.logicalPageKey === key && this.preserveSourceResolution === preserveSourceResolution
    try {
      this.filters = readerHdrRampFilters()
    } catch (_) {
      return
    }
    hdrDecodeTail = hdrDecodeTail.then(async (): Promise<void> => {
      if (!current()) return
      const result = await decodeReaderHdrPage(path, preserveSourceResolution, current)
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
      this.page = result.pixels
    })
  }

  build() {
    if (this.page !== undefined && this.displayedPageKey === this.logicalPageKey && this.filters !== undefined) {
      Image(this.page)
        .width('100%').height('100%')
        .objectFit(this.imageFit)
        .interpolation(this.imageInterpolation)
        .id('rkit-auto-hdr-image')
        .hdrBrightness(this.rampProgress)
        .foregroundFilter(this.filters[Math.round(this.rampProgress * HDR_RATIO_STEPS)])
        .hitTestBehavior(HitTestMode.None)
        .onComplete((event): void => {
          if (event?.loadingStatus === 1) this.imageReady()
        })
        .onError((): void => { this.clear() })
    }
  }
}
