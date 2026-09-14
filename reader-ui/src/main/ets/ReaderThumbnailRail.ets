import { ReaderPagedSession, ReaderPagedSnapshot, ReaderThumbnailWindow, ReaderThumbnailFrame,
  ReaderPagedFrame, ReaderDisplayPart, ReaderUnitKey, ReaderFragment } from '@reader-kit/core'
import { ReaderPagedImage } from './ReaderPagedViewport'
import { readerElementKey } from './ReaderElementKey'

class ThumbnailIndexSource implements IDataSource {
  private count: number
  constructor(count: number) { this.count = count }
  totalCount(): number { return this.count }
  getData(index: number): number { return index }
  registerDataChangeListener(_listener: DataChangeListener): void {}
  unregisterDataChangeListener(_listener: DataChangeListener): void {}
}

/** Auxiliary chrome list. Only a tile selection emits a reading intention. */
@ComponentV2
export struct ReaderThumbnailRail {
  @Require @Param session: ReaderPagedSession
  @Require @Param snapshot: ReaderPagedSnapshot
  @Param accent: ResourceColor = '#D93646'
  @Param previewIndex: number = -1
  @Event onSeek: (index: number, unit: ReaderUnitKey, navigation: number) => void = () => {}
  @Local private frames: ReaderThumbnailFrame[] = []
  private source: ThumbnailIndexSource = new ThumbnailIndexSource(0)
  private resources: ReaderThumbnailWindow | null = null
  private scroller: ListScroller = new ListScroller()
  private navigation: number = -1
  private alive: boolean = false

  aboutToAppear(): void {
    this.alive = true
    this.source = new ThumbnailIndexSource(this.snapshot.unit?.pageCount ?? 0)
    this.navigation = this.snapshot.navigationRevision
    this.resources = this.session.createThumbnailWindow()
    this.resources.subscribe((frames: ReaderThumbnailFrame[]): void => { this.frames = frames })
    this.range(this.current(), this.current())
  }
  aboutToDisappear(): void { this.alive = false; this.resources?.close(); this.resources = null }

  @Monitor('snapshot')
  onSnapshotChanged(): void {
    if (this.alive && this.navigation !== this.snapshot.navigationRevision) {
      this.navigation = this.snapshot.navigationRevision
      this.scroller.scrollToIndex(this.current(), false, ScrollAlign.START)
    }
  }

  @Monitor('previewIndex')
  onPreviewChanged(): void {
    if (!this.alive) return
    const previewing = this.previewIndex >= 0 && this.previewIndex < this.source.totalCount()
    // The gesture supplies the moving target. Retargeted scroll animations can lag until
    // release on long lists; position this preview directly and keep native range ownership.
    this.scroller.scrollToIndex(previewing ? this.previewIndex : this.current(), false)
  }

  private current(): number { return this.snapshot.anchor?.sourceIndexHint ?? 0 }
  private frame(index: number): ReaderThumbnailFrame | null {
    return this.frames.find((frame: ReaderThumbnailFrame) => frame.index === index) ?? null
  }
  private selected(index: number): boolean {
    return this.snapshot.frames.some((frame: ReaderPagedFrame) => frame.part.sourceIndex === index)
  }
  private range(start: number, end: number): void {
    if (this.alive && this.snapshot.unit !== null) {
      this.resources?.setRange(this.snapshot.unit, Math.min(start, end), Math.max(start, end))
    }
  }

  build() {
    List({ space: 8, initialIndex: this.current(), scroller: this.scroller }) {
      LazyForEach(this.source, (index: number) => {
        ListItem() {
          ReaderThumbnailRailTile({
            index: index, frame: this.frame(index), selected: this.selected(index), accent: this.accent,
            onSelect: (): void => {
              if (this.alive && this.snapshot.unit !== null) {
                this.onSeek(index, this.snapshot.unit.key.copy(), this.snapshot.navigationRevision)
              }
            },
            onPresented: (slot: number, request: number, success: boolean, width: number, height: number): void => {
              this.resources?.reportPresentation(slot, request, success, width, height)
            },
            onRetry: (slot: number, request: number): void => { void this.resources?.retry(slot, request) },
          })
        }.margin({
          left: (this.snapshot.policy.direction === 'rtl' ? index === this.source.totalCount() - 1 : index === 0) ? 16 : 0,
          right: (this.snapshot.policy.direction === 'rtl' ? index === 0 : index === this.source.totalCount() - 1) ? 16 : 0,
        })
      }, (index: number): string => `${index}`)
    }.listDirection(Axis.Horizontal)
      .direction(this.snapshot.policy.direction === 'rtl' ? Direction.Rtl : Direction.Ltr)
      .cachedCount(1).scrollBar(BarState.Off).width('100%').height(140)
      .onScrollIndex((start: number, end: number): void => { this.range(start, end) })
      .id('rkit-thumbnail-rail')
  }
}

@ComponentV2
struct ReaderThumbnailRailTile {
  @Require @Param index: number
  @Param frame: ReaderThumbnailFrame | null = null
  @Param selected: boolean = false
  @Param accent: ResourceColor = '#D93646'
  @Event onSelect: () => void = () => {}
  @Event onPresented: (slot: number, request: number, success: boolean, width: number, height: number) => void = () => {}
  @Event onRetry: (slot: number, request: number) => void = () => {}

  private widthValue(): number {
    const thumb = this.frame?.asset.page?.thumbnail
    // Match the production reader's bounded rail slots, without changing source metadata.
    const aspect = thumb !== undefined && thumb.width > 0 && thumb.height > 0 ? thumb.width / thumb.height : 0.7
    return 118 * Math.min(1.4, Math.max(0.45, aspect))
  }
  private imageFrame(): ReaderPagedFrame {
    const frame = this.frame!
    const page = frame.asset.page!
    return new ReaderPagedFrame(frame.slotId, new ReaderDisplayPart(page.unit, page.key, this.index), frame.asset)
  }
  private imageIdentity(): string { return `${this.frame?.slotId}:${this.frame?.asset.assetRequestId}` }

  build() {
    Column({ space: 4 }) {
      Stack({ alignContent: Alignment.Center }) {
        if (this.frame?.asset.page?.thumbnail.available === false) {
          Text($r('app.string.rkit_thumbnail_unavailable')).fontSize(12).fontColor('#99FFFFFF').textAlign(TextAlign.Center)
        } else if (this.frame?.asset.phase === 'failed') {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(22).fontColor([Color.White])
          }.width(44).height(44).backgroundColor(Color.Transparent)
            .accessibilityText($r('app.string.rkit_retry')).id(`rkit-thumb-retry-${this.index}`)
            .onClick((): void => {
              if (this.frame !== null) this.onRetry(this.frame.slotId, this.frame.asset.requestId)
            })
        } else if (this.frame !== null && this.frame.asset.page !== null && this.frame.asset.uri.length > 0) {
          ForEach([this.imageIdentity()], (_identity: string) => {
            ReaderPagedImage({ frame: this.imageFrame(), slotId: this.frame!.slotId,
              assetRequestId: this.frame!.asset.assetRequestId, selectionId: 0, renderedFragment: 'whole', active: false,
              thumbnailCover: true,
              onPresented: this.onPresented,
              onFailed: (_selection: number, slot: number, request: number, _fragment: ReaderFragment): void => {
                this.onPresented(slot, request, false, 0, 0)
              },
            })
          }, (identity: string): string => readerElementKey(identity))
        } else {
          LoadingProgress().width(22).height(22).color(Color.White)
        }
      }.width(this.widthValue()).height(118).backgroundColor('#26FFFFFF')
        .border({ width: this.selected ? 2 : 0, color: this.selected ? this.accent : Color.Transparent })
        .borderRadius(8).clip(true).id(`rkit-thumb-image-${this.index}`)
      Text(`${this.index + 1}`).fontSize(12).fontColor(this.selected ? this.accent : Color.White)
        .fontWeight(FontWeight.Medium).maxLines(1).height(18).width(this.widthValue()).textAlign(TextAlign.Center)
        .id(`rkit-thumb-state-${this.index}-${this.frame?.asset.phase ?? 'pending'}`)
    }.width(this.widthValue()).height(140).alignItems(HorizontalAlign.Center)
      .id(`rkit-thumbnail-${this.index}`).onClick(this.onSelect)
  }
}
