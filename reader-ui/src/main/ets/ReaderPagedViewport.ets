import { ReaderPagedSnapshot, ReaderPagedFrame, ReaderDisplayPart, ReaderSnapshot, ReaderUnitKey, ReaderFragment } from '@reader-kit/core'

function partRatio(frame: ReaderPagedFrame): number {
  const page = frame.asset.page
  const width = frame.asset.kind === 'thumbnail' ? page?.thumbnail.width ?? 0 : page?.width ?? 0
  const height = frame.asset.kind === 'thumbnail' ? page?.thumbnail.height ?? 0 : page?.height ?? 0
  const fraction = frame.asset.kind === 'original' ? frame.part.width() : 1
  return width > 0 && height > 0 ? width / height * fraction : 0.75
}

/** Selected display-item rendering only; no app navigation, settings or progress owner. */
@ComponentV2
export struct ReaderPagedViewport {
  @Require @Param snapshot: ReaderPagedSnapshot
  @Require @Param active: boolean
  @Event onPresented: (slotId: number, requestId: number, success: boolean, width: number, height: number) => void = () => {}
  @Event onVisible: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Event onFailed: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Local private viewportWidth: number = 1
  @Local private viewportHeight: number = 1

  private totalRatio(): number {
    return Math.max(0.01, this.snapshot.frames.reduce((sum: number, frame: ReaderPagedFrame) => sum + partRatio(frame), 0))
  }

  private frameHeight(): number { return Math.min(this.viewportHeight, this.viewportWidth / this.totalRatio()) }

  build() {
    Stack() {
      Row() {
        ForEach(this.snapshot.frames, (frame: ReaderPagedFrame) => {
          // Only stable identity comes from the ForEach closure. Cell state is
          // resolved from the current snapshot so same-key updates are not lost.
          ReaderPagedCell({
            snapshot: this.snapshot, slotId: frame.slotId,
            assetRequestId: frame.asset.assetRequestId,
            renderedFragment: frame.part.fragment,
            frameHeight: this.frameHeight(), active: this.active,
            onPresented: this.onPresented, onVisible: this.onVisible, onFailed: this.onFailed,
          })
        }, (frame: ReaderPagedFrame): string => `${frame.slotId}:${frame.asset.assetRequestId}:${frame.part.fragment}`)
      }
      .direction(Direction.Ltr)
      .width(this.frameHeight() * this.totalRatio())
      .height(this.frameHeight())
      if (this.snapshot.phase === 'catalog') {
        LoadingProgress().width(32).height(32)
      }
    }
    .alignContent(Alignment.Center)
    .width('100%').height('100%')
    .clip(true)
    .id('rkit-image-viewport')
    .onAreaChange((_old: Area, area: Area): void => {
      this.viewportWidth = Math.max(1, Number(area.width))
      this.viewportHeight = Math.max(1, Number(area.height))
    })
  }
}

@ComponentV2
struct ReaderPagedCell {
  @Require @Param snapshot: ReaderPagedSnapshot
  @Require @Param slotId: number
  @Require @Param assetRequestId: number
  @Require @Param renderedFragment: ReaderFragment
  @Require @Param frameHeight: number
  @Require @Param active: boolean
  @Event onPresented: (slotId: number, requestId: number, success: boolean, width: number, height: number) => void = () => {}
  @Event onVisible: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Event onFailed: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}

  private frame(): ReaderPagedFrame {
    return this.snapshot.frames.find((frame: ReaderPagedFrame) => frame.slotId === this.slotId &&
      frame.asset.assetRequestId === this.assetRequestId && frame.part.fragment === this.renderedFragment) ??
      new ReaderPagedFrame(0, new ReaderDisplayPart(new ReaderUnitKey('', '', ''), null, 0), new ReaderSnapshot())
  }

  build() {
    Stack() {
      if (this.frame().asset.uri.length > 0) {
        ReaderPagedImage({
          frame: this.frame(), selectionId: this.snapshot.selectionId,
          slotId: this.slotId, assetRequestId: this.assetRequestId,
          renderedFragment: this.renderedFragment,
          active: this.active && this.snapshot.phase === 'ready',
          onPresented: this.onPresented, onVisible: this.onVisible, onFailed: this.onFailed,
        })
      }
      if (this.frame().asset.phase === 'idle' || this.frame().asset.phase === 'asset' || this.frame().asset.phase === 'decoding') {
        LoadingProgress().width(32).height(32)
      }
    }
    .width(this.frameHeight * partRatio(this.frame()))
    .height(this.frameHeight).clip(true)
    .id(`rkit-part-${this.frame().part.sourceIndex}-${this.frame().part.fragment}`)
  }
}

@ComponentV2
struct ReaderPagedImage {
  @Require @Param frame: ReaderPagedFrame
  @Require @Param slotId: number
  @Require @Param assetRequestId: number
  @Require @Param selectionId: number
  @Require @Param renderedFragment: ReaderFragment
  @Require @Param active: boolean
  @Event onPresented: (slotId: number, requestId: number, success: boolean, width: number, height: number) => void = () => {}
  @Event onVisible: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Event onFailed: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Local private viewportWidth: number = 1
  @Local private viewportHeight: number = 1
  private fullyVisible: boolean = false
  private decoded: boolean = false

  @Monitor('active', 'selectionId')
  onSelectionChanged(): void { this.reportVisible() }

  private reportVisible(): void {
    if (this.active && this.fullyVisible && this.decoded && this.frame.asset.kind === 'original') {
      this.onVisible(this.selectionId, this.slotId, this.assetRequestId, this.renderedFragment)
    }
  }

  private completed(width: number, height: number): void {
    this.decoded = true
    this.onPresented(this.slotId, this.assetRequestId, true, width, height)
    this.reportVisible()
  }

  private failed(): void {
    this.decoded = false
    this.onFailed(this.selectionId, this.slotId, this.assetRequestId, this.renderedFragment)
  }

  private spriteScale(): number {
    const thumbnail = this.frame.asset.page?.thumbnail
    if (thumbnail === undefined || thumbnail.width <= 0 || thumbnail.height <= 0) return 1
    return Math.min(this.viewportWidth / thumbnail.width, this.viewportHeight / thumbnail.height)
  }

  build() {
    Stack() {
      if (this.frame.asset.kind === 'thumbnail' && this.frame.asset.page?.thumbnail.kind === 'sprite') {
        Stack({ alignContent: Alignment.TopStart }) {
          Image(this.frame.asset.uri)
            .width(this.frame.asset.page.thumbnail.spriteWidth * this.spriteScale())
            .height(this.frame.asset.page.thumbnail.spriteHeight * this.spriteScale())
            .objectFit(ImageFit.Fill)
            .position({
              x: -this.frame.asset.page.thumbnail.offsetX * this.spriteScale(),
              y: -this.frame.asset.page.thumbnail.offsetY * this.spriteScale(),
            })
            .onComplete((event): void => {
              if (event?.loadingStatus === 1) this.completed(event.width, event.height)
            })
            .onError((): void => { this.failed() })
        }
        .width(this.frame.asset.page.thumbnail.width * this.spriteScale())
        .height(this.frame.asset.page.thumbnail.height * this.spriteScale())
        .clip(true)
      } else if (this.frame.asset.kind === 'original' && this.frame.part.fragment !== 'whole') {
        Stack({ alignContent: Alignment.TopStart }) {
          Image(this.frame.asset.uri)
            .width(this.viewportWidth * 2).height(this.viewportHeight)
            .objectFit(ImageFit.Fill)
            .position({ x: this.frame.part.fragment === 'right' ? -this.viewportWidth : 0, y: 0 })
            .onComplete((event): void => {
              if (event?.loadingStatus === 1) this.completed(event.width, event.height)
            })
            .onError((): void => { this.failed() })
        }
        .width('100%').height('100%').clip(true)
      } else {
        Image(this.frame.asset.uri)
          .width('100%').height('100%')
          .objectFit(ImageFit.Contain)
          .onComplete((event): void => {
            if (event?.loadingStatus === 1) this.completed(event.width, event.height)
          })
          .onError((): void => { this.failed() })
      }
    }
    .width('100%').height('100%')
    .onVisibleAreaChange([0, 1], (_expanding: boolean, ratio: number): void => {
      this.fullyVisible = ratio >= 1
      this.reportVisible()
    })
    .onAreaChange((_old: Area, area: Area): void => {
      this.viewportWidth = Math.max(1, Number(area.width))
      this.viewportHeight = Math.max(1, Number(area.height))
    })
  }
}
