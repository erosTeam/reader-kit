import { ReaderSession, ReaderSnapshot, ReaderUnitKey } from '@reader-kit/core'

/** A diagnostic integration surface, not a replacement for the production reader chrome. */
@ComponentV2
export struct ReaderLabSurface {
  @Require @Param session: ReaderSession
  @Require @Param initialUnit: ReaderUnitKey
  @Param initialIndex: number = 0
  @Local private state: ReaderSnapshot = new ReaderSnapshot()

  aboutToAppear(): void {
    this.session.subscribe((state: ReaderSnapshot): void => { this.state = state })
    void this.session.open(this.initialUnit, this.initialIndex)
  }

  aboutToDisappear(): void { this.session.close() }

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.rkit_lab_scope'))
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
      Text(this.state.unit === null ? '' : this.state.unit.title)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Row({ space: 12 }) {
        Text(this.state.unit === null ? '0 / 0' : `${this.state.sourceIndex + 1} / ${this.state.unit.pageCount}`)
          .id('rkit-page-position')
        Text(this.state.phase).id('rkit-phase').fontSize(12)
      }
      Stack() {
        if (this.state.uri.length > 0) {
          ForEach([this.state], (frame: ReaderSnapshot) => {
            ReaderLabImage({
              frame: frame,
              onPresented: (requestId: number, success: boolean): void => {
                this.session.reportPresentation(requestId, success)
              },
            })
          }, (frame: ReaderSnapshot): string => frame.requestId.toString())
        }
        if (this.state.phase === 'catalog' || this.state.phase === 'asset' || this.state.phase === 'decoding') {
          LoadingProgress().width(32).height(32)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .clip(true)
      .id('rkit-image-viewport')
      if (this.state.error.length > 0) {
        Text(this.state.error).fontSize(12).id('rkit-error')
        Button($r('app.string.rkit_retry'))
          .height(40).constraintSize({ minWidth: 120 })
          .onClick((): void => { void this.session.retry() })
      }
      Row({ space: 12 }) {
        Button($r('app.string.rkit_previous_page'))
          .layoutWeight(1).height(40)
          .enabled(this.state.sourceIndex > 0)
          .id('rkit-previous-page')
          .onClick((): void => { void this.session.show(this.state.sourceIndex - 1, this.state.kind) })
        Button($r('app.string.rkit_next_page'))
          .layoutWeight(1).height(40)
          .enabled(this.state.unit !== null && this.state.sourceIndex + 1 < this.state.unit.pageCount)
          .id('rkit-next-page')
          .onClick((): void => { void this.session.show(this.state.sourceIndex + 1, this.state.kind) })
      }
      Row({ space: 12 }) {
        Button(this.state.kind === 'original' ? $r('app.string.rkit_thumbnail') : $r('app.string.rkit_original'))
          .layoutWeight(1).height(40)
          .enabled(this.state.page !== null && this.state.page.thumbnail.available)
          .id('rkit-asset-kind')
          .onClick((): void => {
            void this.session.show(this.state.sourceIndex, this.state.kind === 'original' ? 'thumbnail' : 'original')
          })
        if (this.state.canPreviousUnit) {
          Button($r('app.string.rkit_previous_unit')).height(40)
            .id('rkit-previous-unit')
            .onClick((): void => { void this.session.switchUnit('previous') })
        }
        if (this.state.canNextUnit) {
          Button($r('app.string.rkit_next_unit')).height(40)
            .id('rkit-next-unit')
            .onClick((): void => { void this.session.switchUnit('next') })
        }
      }
      Text(`D1 · cancellation=${this.session.cancellationMode()}`)
        .fontSize(11).fontColor($r('sys.color.font_secondary'))
    }
    .padding(12)
    .width('100%').height('100%')
    .backgroundColor($r('sys.color.background_primary'))
  }
}

@ComponentV2
struct ReaderLabImage {
  @Require @Param frame: ReaderSnapshot
  @Event onPresented: (requestId: number, success: boolean) => void = () => {}
  @Local private viewportWidth: number = 1
  @Local private viewportHeight: number = 1

  private spriteScale(): number {
    const thumbnail = this.frame.page?.thumbnail
    if (thumbnail === undefined || thumbnail.width <= 0 || thumbnail.height <= 0) return 1
    return Math.min(this.viewportWidth / thumbnail.width, this.viewportHeight / thumbnail.height)
  }

  build() {
    Stack() {
      if (this.frame.kind === 'thumbnail' && this.frame.page?.thumbnail.kind === 'sprite') {
        Stack({ alignContent: Alignment.TopStart }) {
          Image(this.frame.uri)
            .width(this.frame.page.thumbnail.spriteWidth * this.spriteScale())
            .height(this.frame.page.thumbnail.spriteHeight * this.spriteScale())
            .objectFit(ImageFit.Fill)
            .position({
              x: -this.frame.page.thumbnail.offsetX * this.spriteScale(),
              y: -this.frame.page.thumbnail.offsetY * this.spriteScale(),
            })
            .onComplete((event): void => {
              if (event?.loadingStatus === 1) this.onPresented(this.frame.requestId, true)
            })
            .onError((): void => { this.onPresented(this.frame.requestId, false) })
        }
        .width(this.frame.page.thumbnail.width * this.spriteScale())
        .height(this.frame.page.thumbnail.height * this.spriteScale())
        .clip(true)
      } else {
        Image(this.frame.uri)
          .width('100%').height('100%')
          .objectFit(ImageFit.Contain)
          .onComplete((event): void => {
            if (event?.loadingStatus === 1) this.onPresented(this.frame.requestId, true)
          })
          .onError((): void => { this.onPresented(this.frame.requestId, false) })
      }
    }
    .width('100%').height('100%')
    .onAreaChange((_oldArea: Area, area: Area): void => {
      this.viewportWidth = Math.max(1, Number(area.width))
      this.viewportHeight = Math.max(1, Number(area.height))
    })
  }
}
