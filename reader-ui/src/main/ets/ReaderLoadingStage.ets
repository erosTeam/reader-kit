/**
 * Faithful kit port of the legacy host ReaderLoadingBar + ReaderLoadingStage
 * presentation. Constants and timer mechanics are copied verbatim from the
 * NN/NE ReaderPage implementations (height 4, width 80%, maxWidth 180,
 * radius 2, track #33FFFFFF, fill white, slider ratio 0.3, progress anim
 * 220ms EaseOut, indeterminate step 900ms, stage spacing 8, label font 14,
 * padding 24): the shared cell reuses the existing product presentation
 * instead of inventing new geometry. A real received/total byte pair renders
 * the determinate bar plus percent; otherwise the indeterminate bar plus the
 * stage label. Unknown totals never fabricate a percentage.
 */
const LOADING_PROGRESS_ANIM_DURATION: number = 220
const LOADING_INDETERMINATE_ANIM_DURATION: number = 900
const LOADING_BAR_HEIGHT: number = 4
const LOADING_BAR_WIDTH_PERCENT: string = '80%'
const LOADING_BAR_MAX_WIDTH: number = 180
const LOADING_SLIDER_WIDTH_RATIO: number = 0.3
const LOADING_BAR_RADIUS: number = 2
const LOADING_BAR_BG: ResourceColor = '#33FFFFFF'
const LOADING_BAR_FG: ResourceColor = Color.White
const LOADING_STAGE_SPACE: number = 8
const LOADING_STAGE_PADDING: number = 24
const LOADING_STAGE_FONT: number = 14

@ComponentV2
struct ReaderLoadingBar {
  @Param determinate: boolean = false
  @Param ratio: number = 0
  @Param barFillColor: ResourceColor = LOADING_BAR_FG
  @Param barTrackColor: ResourceColor = LOADING_BAR_BG
  @Local trackWidth: number = 0
  @Local indeterminatePosition: number = 0
  private indeterminateStartTimer: number = -1
  private indeterminateTimer: number = -1

  aboutToAppear(): void {
    this.syncIndeterminateAnimation()
  }

  aboutToDisappear(): void {
    this.stopIndeterminateAnimation()
  }

  @Monitor('determinate')
  private onDeterminateChanged(): void {
    this.syncIndeterminateAnimation()
  }

  private syncIndeterminateAnimation(): void {
    if (this.determinate) {
      this.stopIndeterminateAnimation()
      this.indeterminatePosition = 0
      return
    }
    this.startIndeterminateAnimation()
  }

  private startIndeterminateAnimation(): void {
    if (this.trackWidth <= 0 || this.indeterminateStartTimer >= 0 || this.indeterminateTimer >= 0) {
      return
    }
    this.indeterminatePosition = 0
    this.indeterminateStartTimer = setTimeout((): void => {
      this.indeterminateStartTimer = -1
      if (this.determinate) {
        return
      }
      this.moveIndeterminateSlider()
      this.indeterminateTimer = setInterval((): void => {
        this.moveIndeterminateSlider()
      }, LOADING_INDETERMINATE_ANIM_DURATION)
    }, 0)
  }

  private stopIndeterminateAnimation(): void {
    if (this.indeterminateStartTimer >= 0) {
      clearTimeout(this.indeterminateStartTimer)
      this.indeterminateStartTimer = -1
    }
    if (this.indeterminateTimer >= 0) {
      clearInterval(this.indeterminateTimer)
      this.indeterminateTimer = -1
    }
  }

  private moveIndeterminateSlider(): void {
    this.indeterminatePosition = this.indeterminatePosition > 0 ? 0 : 1
  }

  private barWidth(): number {
    return this.trackWidth > 0 ? this.trackWidth : LOADING_BAR_MAX_WIDTH
  }

  private sliderWidth(): number {
    return this.barWidth() * LOADING_SLIDER_WIDTH_RATIO
  }

  private clampedRatio(): number {
    if (this.ratio < 0) {
      return 0
    }
    if (this.ratio > 1) {
      return 1
    }
    return this.ratio
  }

  private fillWidth(): number {
    return this.determinate ? this.barWidth() * this.clampedRatio() : this.sliderWidth()
  }

  private sliderX(): number {
    return this.determinate ? 0 : (this.barWidth() - this.sliderWidth()) * this.indeterminatePosition
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      if (this.determinate) {
        Row()
          .width(this.fillWidth())
          .height(LOADING_BAR_HEIGHT)
          .backgroundColor(this.barFillColor)
          .borderRadius(LOADING_BAR_RADIUS)
          .animation({ duration: LOADING_PROGRESS_ANIM_DURATION, curve: Curve.EaseOut })
      } else {
        Row()
          .width(this.sliderWidth())
          .height(LOADING_BAR_HEIGHT)
          .backgroundColor(this.barFillColor)
          .borderRadius(LOADING_BAR_RADIUS)
          .translate({ x: this.sliderX() })
          .animation({ duration: LOADING_INDETERMINATE_ANIM_DURATION, curve: Curve.EaseInOut })
      }
    }
    .width(LOADING_BAR_WIDTH_PERCENT)
    .constraintSize({ maxWidth: LOADING_BAR_MAX_WIDTH })
    .height(LOADING_BAR_HEIGHT)
    .backgroundColor(this.barTrackColor)
    .borderRadius(LOADING_BAR_RADIUS)
    .clip(true)
    .onAreaChange((_oldArea: Area, area: Area): void => {
      this.trackWidth = area.width as number
      this.syncIndeterminateAnimation()
    })
  }
}

/**
 * Shared loading presentation. Plain (non-transition-panel) mode is used by
 * the paged cell; the host transition proxy keeps its own panel presentation.
 */
@ComponentV2
export struct ReaderLoadingStage {
  @Param label: ResourceStr = ''
  @Param loaded: number = 0
  @Param total: number = 0

  private hasProgress(): boolean {
    return this.total > 0
  }

  private progressRatio(): number {
    if (!this.hasProgress()) {
      return 0
    }
    const ratio = this.loaded / this.total
    if (ratio < 0) {
      return 0
    }
    if (ratio > 1) {
      return 1
    }
    return ratio
  }

  private progressPercent(): string {
    return `${Math.round(this.progressRatio() * 100)}%`
  }

  @Builder
  private LoadingElements() {
    ReaderLoadingBar({ determinate: this.hasProgress(), ratio: this.progressRatio() })
    Text(this.hasProgress() ? this.progressPercent() : this.label)
      .fontSize(LOADING_STAGE_FONT)
      .fontColor(LOADING_BAR_FG)
      .textAlign(TextAlign.Center)
  }

  build() {
    Column({ space: LOADING_STAGE_SPACE }) {
      this.LoadingElements()
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding(LOADING_STAGE_PADDING)
  }
}
