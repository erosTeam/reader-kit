import { ReaderPagedSession, ReaderPagedSnapshot, ReaderPagedFrame, ReaderUnitKey, ReaderFragment } from '@reader-kit/core'
import { ReaderPagerSurface } from './ReaderPagerSurface'

/** Diagnostic controls only; the viewport has no dependency on this chrome. */
@ComponentV2
export struct ReaderLabSurface {
  @Require @Param session: ReaderPagedSession
  @Require @Param initialUnit: ReaderUnitKey
  @Require @Param active: boolean
  @Param initialIndex: number = 0
  @Local private state: ReaderPagedSnapshot = new ReaderPagedSnapshot()

  aboutToAppear(): void {
    this.session.setNeighborPreload(true)
    this.session.setViewportActive(this.active)
    this.session.subscribe((state: ReaderPagedSnapshot): void => { this.state = state })
    void this.session.open(this.initialUnit, this.initialIndex)
  }

  aboutToDisappear(): void { this.session.close() }

  @Monitor('active')
  onActiveChanged(): void {
    this.session.setViewportActive(this.active)
    console.info(`[ReaderLab] viewport_active=${this.active}`)
  }

  private error(): string {
    return this.state.error || this.state.frames.find((frame: ReaderPagedFrame) => frame.asset.error.length > 0)?.asset.error || ''
  }

  private toggleAlignment(): void {
    const policy = this.state.policy.copy()
    if (policy.layout === 'single') policy.splitWidePages = !policy.splitWidePages
    else policy.firstPageAlone = !policy.firstPageAlone
    this.session.setPolicy(policy)
  }

  private alignmentLabel(): ResourceStr {
    if (this.state.policy.layout === 'single') {
      return this.state.policy.splitWidePages ? $r('app.string.rkit_split_on') : $r('app.string.rkit_split_off')
    }
    return this.state.policy.firstPageAlone ? $r('app.string.rkit_cover_on') : $r('app.string.rkit_cover_off')
  }

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.rkit_lab_scope')).fontSize(13).fontColor($r('sys.color.font_secondary'))
      Text(this.state.unit === null ? '' : this.state.unit.title)
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      Row({ space: 12 }) {
        Text(this.state.unit === null ? '0 / 0' : `${(this.state.anchor?.sourceIndexHint ?? 0) + 1} / ${this.state.unit.pageCount}`)
          .id('rkit-page-position')
        Text(this.state.displayCount === 0 ? '0 / 0' :
          `${this.state.displayIndex + 1} / ${this.state.displayCount} · ${this.state.anchor?.fragment ?? 'whole'}`)
          .fontSize(12).id('rkit-display-position')
        Text(this.state.phase).fontSize(12).id('rkit-phase')
      }
      Row({ space: 12 }) {
        Select([{ value: $r('app.string.rkit_single') }, { value: $r('app.string.rkit_spread') }])
          .selected(this.state.policy.layout === 'single' ? 0 : 1)
          .value(this.state.policy.layout === 'single' ? $r('app.string.rkit_single') : $r('app.string.rkit_spread'))
          .font({ size: 14 }).height(40).layoutWeight(1).id('rkit-layout')
          .onSelect((index: number): void => {
            const policy = this.state.policy.copy()
            policy.layout = index === 0 ? 'single' : 'spread'
            this.session.setPolicy(policy)
          })
        Select([{ value: $r('app.string.rkit_ltr') }, { value: $r('app.string.rkit_rtl') }])
          .selected(this.state.policy.direction === 'ltr' ? 0 : 1)
          .value(this.state.policy.direction === 'ltr' ? $r('app.string.rkit_ltr') : $r('app.string.rkit_rtl'))
          .font({ size: 14 }).height(40).layoutWeight(1).id('rkit-direction')
          .onSelect((index: number): void => {
            const policy = this.state.policy.copy()
            policy.direction = index === 0 ? 'ltr' : 'rtl'
            this.session.setPolicy(policy)
          })
        Button(this.alignmentLabel()).fontSize(14).height(40).layoutWeight(1)
          .id('rkit-alignment').onClick((): void => { this.toggleAlignment() })
      }
      .width('100%')
      ReaderPagerSurface({
        snapshot: this.state, active: this.active,
        onSelect: (index: number, topologyRevision: number, navigationRevision: number): void => {
          const accepted = this.session.selectDisplay(index, topologyRevision, navigationRevision)
          console.info(`[ReaderLab] pager_selection index=${index} accepted=${accepted}`)
        },
        onPresented: (slotId: number, requestId: number, success: boolean, width: number, height: number): void => {
          this.session.reportPresentation(slotId, requestId, success, width, height)
        },
        onFailed: (topologyRevision: number, itemKey: string, slotId: number, requestId: number, fragment: ReaderFragment): void => {
          this.session.reportCachedRenderFailure(topologyRevision, itemKey, slotId, requestId, fragment)
        },
        onVisible: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment): void => {
          this.session.setViewportActive(this.active)
          const accepted = this.session.reportVisible(selectionId, slotId, requestId, fragment)
          const snapshot = this.session.snapshot()
          console.info(`[ReaderLab] original_observation active=${this.active} selection=${selectionId} slot=${slotId} request=${requestId} accepted=${accepted} sourceIndex=${snapshot.observedAnchor?.sourceIndexHint ?? -1} fragment=${snapshot.observedAnchor?.fragment ?? 'whole'}`)
        },
      }).layoutWeight(1)
      if (this.error().length > 0) {
        Text(this.error()).fontSize(12).id('rkit-error')
        Button($r('app.string.rkit_retry'))
          .height(40).constraintSize({ minWidth: 120 })
          .onClick((): void => { void this.session.retry() })
      }
      Row({ space: 12 }) {
        Button($r('app.string.rkit_previous_page'))
          .layoutWeight(1).height(40)
          .enabled(this.state.phase === 'ready' && this.state.displayIndex > 0)
          .id('rkit-previous-page')
          .onClick((): void => { this.session.move('previous') })
        Button($r('app.string.rkit_next_page'))
          .layoutWeight(1).height(40)
          .enabled(this.state.phase === 'ready' && this.state.displayIndex + 1 < this.state.displayCount)
          .id('rkit-next-page')
          .onClick((): void => { this.session.move('next') })
      }
      Row({ space: 12 }) {
        Button(this.state.kind === 'original' ? $r('app.string.rkit_thumbnail') : $r('app.string.rkit_original'))
          .layoutWeight(1).height(40)
          .enabled(this.state.phase === 'ready' && this.state.frames.length > 0 &&
            this.state.frames.every((frame: ReaderPagedFrame) => frame.asset.page !== null && frame.asset.page.thumbnail.available))
          .id('rkit-asset-kind')
          .onClick((): void => {
            this.session.setAssetKind(this.state.kind === 'original' ? 'thumbnail' : 'original')
          })
        if (this.state.canPreviousUnit) {
          Button($r('app.string.rkit_previous_unit')).height(40).id('rkit-previous-unit')
            .onClick((): void => { void this.session.switchUnit('previous') })
        }
        if (this.state.canNextUnit) {
          Button($r('app.string.rkit_next_unit')).height(40).id('rkit-next-unit')
            .onClick((): void => { void this.session.switchUnit('next') })
        }
      }
      Text(`D3 · cancellation=${this.session.cancellationMode()}`)
        .fontSize(11).fontColor($r('sys.color.font_secondary'))
    }
    .padding(12).width('100%').height('100%')
    .backgroundColor($r('sys.color.background_primary'))
  }
}
