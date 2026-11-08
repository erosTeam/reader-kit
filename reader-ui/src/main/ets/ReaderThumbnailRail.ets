import { ReaderPagedSession, ReaderPagedSnapshot, ReaderThumbnailWindow, ReaderThumbnailFrame,
  ReaderPagedFrame, ReaderDisplayPart, ReaderUnitKey, ReaderFragment } from '@reader-kit/core'
import { ReaderPagedImage } from './ReaderPagedViewport'
import { readerElementKey } from './ReaderElementKey'

@ObservedV2
class ThumbnailCell {
  readonly index: number
  @Trace frame: ReaderThumbnailFrame | null = null
  constructor(index: number) { this.index = index }
}

class ThumbnailIndexSource implements IDataSource {
  private count: number
  private cells: Map<number, ThumbnailCell> = new Map<number, ThumbnailCell>()
  private framed: Set<number> = new Set<number>()
  constructor(count: number) { this.count = count }
  totalCount(): number { return this.count }
  getData(index: number): ThumbnailCell {
    let cell = this.cells.get(index)
    if (cell === undefined) {
      cell = new ThumbnailCell(index)
      this.cells.set(index, cell)
    }
    return cell
  }
  update(frames: ReaderThumbnailFrame[]): void {
    const next = new Set<number>()
    for (const frame of frames) {
      const cell = this.getData(frame.index)
      if (cell.frame?.slotId !== frame.slotId || cell.frame.revision !== frame.revision) cell.frame = frame
      next.add(frame.index)
    }
    for (const index of this.framed) {
      if (!next.has(index)) this.getData(index).frame = null
    }
    this.framed = next
  }
  registerDataChangeListener(_listener: DataChangeListener): void {}
  unregisterDataChangeListener(_listener: DataChangeListener): void {}
}

/** Auxiliary chrome list. Only a tile selection emits a reading intention. */
@ComponentV2
export struct ReaderThumbnailRail {
  @Require @Param session: ReaderPagedSession
  @Require @Param snapshot: ReaderPagedSnapshot
  @Param visible: boolean = true
  @Local private renderedSnapshot: ReaderPagedSnapshot = new ReaderPagedSnapshot()
  @Param accent: ResourceColor = '#D93646'
  @Param previewIndex: number = -1
  @Event onSeek: (index: number, unit: ReaderUnitKey, navigation: number) => void = () => {}
  private source: ThumbnailIndexSource = new ThumbnailIndexSource(0)
  private resources: ReaderThumbnailWindow | null = null
  private scroller: ListScroller = new ListScroller()
  private initialIndex: number = 0
  private scrollTarget: number = -1
  private alive: boolean = false
  private positionWasVisible: boolean = false

  aboutToAppear(): void {
    this.alive = true
    this.renderedSnapshot = this.snapshot
    this.positionWasVisible = this.visible
    this.source = new ThumbnailIndexSource(this.snapshot.unit?.pageCount ?? 0)
    this.initialIndex = this.current()
    this.scrollTarget = this.initialIndex
    this.resources = this.session.createThumbnailWindow()
    this.resources.subscribe((frames: ReaderThumbnailFrame[]): void => { this.source.update(frames) })
    this.range(this.current(), this.current())
  }
  aboutToDisappear(): void { this.alive = false; this.resources?.close(); this.resources = null }

  @Monitor('snapshot', 'previewIndex', 'visible')
  onPositionChanged(): void {
    if (!this.alive) return
    if (!this.visible) { this.positionWasVisible = false; return }
    this.renderedSnapshot = this.snapshot
    const previewing = this.previewIndex >= 0 && this.previewIndex < this.source.totalCount()
    const target = previewing ? this.previewIndex : this.current()
    const wasVisible = this.positionWasVisible
    this.positionWasVisible = true
    // Retain the hidden native List and decoded leases, without scrolling or
    // demanding each intervening page. Opening adopts the current target once.
    if (!wasVisible) this.range(target, target)
    if (target === this.scrollTarget) return
    this.scrollTarget = target
    // Visible page changes animate; opening and slider previews align directly.
    this.scroller.scrollToIndex(target, wasVisible && !previewing, ScrollAlign.START)
  }

  private current(): number { return this.snapshot.anchor?.sourceIndexHint ?? 0 }
  private selected(index: number): boolean {
    return this.renderedSnapshot.frames.some((frame: ReaderPagedFrame) => frame.part.sourceIndex === index)
  }
  private range(start: number, end: number): void {
    if (this.alive && this.visible && this.snapshot.unit !== null) {
      this.resources?.setRange(this.snapshot.unit, Math.min(start, end), Math.max(start, end))
    }
  }

  build() {
    List({ space: 8, initialIndex: this.initialIndex, scroller: this.scroller }) {
      LazyForEach(this.source, (cell: ThumbnailCell) => {
        ListItem() {
          ReaderThumbnailRailTile({
            cell: cell, selected: this.selected(cell.index), accent: this.accent,
            onSelect: (): void => {
              if (this.alive && this.snapshot.unit !== null) {
                this.onSeek(cell.index, this.snapshot.unit.key.copy(), this.snapshot.navigationRevision)
              }
            },
            onPresented: (slot: number, request: number, success: boolean, width: number, height: number): void => {
              this.resources?.reportPresentation(slot, request, success, width, height)
            },
            onRetry: (slot: number, request: number): void => { void this.resources?.retry(slot, request) },
          })
        }.margin({
          left: (this.renderedSnapshot.policy.direction === 'rtl' ? cell.index === this.source.totalCount() - 1 : cell.index === 0) ? 16 : 0,
          right: (this.renderedSnapshot.policy.direction === 'rtl' ? cell.index === 0 : cell.index === this.source.totalCount() - 1) ? 16 : 0,
        })
      }, (cell: ThumbnailCell): string => `${cell.index}`)
    }.listDirection(Axis.Horizontal)
      .direction(this.renderedSnapshot.policy.direction === 'rtl' ? Direction.Rtl : Direction.Ltr)
      .cachedCount(3).scrollBar(BarState.Off).width('100%').height(140)
      .onScrollIndex((start: number, end: number): void => { this.range(start, end) })
      .id('rkit-thumbnail-rail')
  }
}

@ComponentV2
struct ReaderThumbnailRailTile {
  @Require @Param cell: ThumbnailCell
  @Param selected: boolean = false
  @Param accent: ResourceColor = '#D93646'
  @Event onSelect: () => void = () => {}
  @Event onPresented: (slot: number, request: number, success: boolean, width: number, height: number) => void = () => {}
  @Event onRetry: (slot: number, request: number) => void = () => {}

  private get index(): number { return this.cell.index }
  private get frame(): ReaderThumbnailFrame | null { return this.cell.frame }

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
            if (this.frame?.asset.page?.thumbnail.kind === 'sprite') {
              ReaderPagedImage({ frame: this.imageFrame(), slotId: this.frame!.slotId,
                assetRequestId: this.frame!.asset.assetRequestId, selectionId: 0, renderedFragment: 'whole', active: false,
                thumbnailCover: true,
                onPresented: this.onPresented,
                onFailed: (_selection: number, slot: number, request: number, _fragment: ReaderFragment): void => {
                  this.onPresented(slot, request, false, 0, 0)
                },
              })
            } else {
              ReaderThumbnailBitmap({ frame: this.frame!, onPresented: this.onPresented })
            }
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

/** An independent thumbnail has no page viewport, visibility or entry transition to observe. */
@ComponentV2
struct ReaderThumbnailBitmap {
  @Require @Param frame: ReaderThumbnailFrame
  @Event onPresented: (slot: number, request: number, success: boolean, width: number, height: number) => void = () => {}

  build() {
    Image(this.frame.asset.uri).width('100%').height('100%')
      .objectFit(ImageFit.Cover).interpolation(ImageInterpolation.Low)
      .onComplete((event): void => {
        if (event?.loadingStatus === 1) {
          this.onPresented(this.frame.slotId, this.frame.asset.assetRequestId, true, event.width, event.height)
        }
      })
      .onError((): void => {
        this.onPresented(this.frame.slotId, this.frame.asset.assetRequestId, false, 0, 0)
      })
  }
}
