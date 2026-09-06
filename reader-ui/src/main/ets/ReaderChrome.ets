import { ReaderPagedSnapshot, ReaderDisplayPolicy, ReaderUnitKey } from '@reader-kit/core'

/** Default overlay chrome. It emits intentions; it never opens a catalog or writes preferences. */
@ComponentV2
export struct ReaderChrome {
  @Require @Param snapshot: ReaderPagedSnapshot
  @Param active: boolean = true
  @Param topInset: number = 0
  @Param bottomInset: number = 0
  @Param accent: ResourceColor = '#D93646'
  @Param thumbnailsVisible: boolean = false
  @Event onThumbnails: () => void = () => {}
  @Event onMenuVisible: (visible: boolean) => void = () => {}
  @Event onClose: () => void = () => {}
  @Event onPolicy: (policy: ReaderDisplayPolicy) => void = () => {}
  @Event onSeek: (index: number, unit: ReaderUnitKey, navigation: number) => void = () => {}
  @Event onPreview: (index: number, unit: ReaderUnitKey | null, navigation: number) => void = () => {}
  @Local private preview: number = -1
  private seekUnit: ReaderUnitKey | null = null
  private seekNavigation: number = -1

  @Monitor('snapshot', 'active')
  onSnapshotChanged(): void {
    if (!this.active || this.snapshot.phase !== 'ready' ||
      this.seekUnit !== null && (!this.snapshot.unit?.key.equals(this.seekUnit) ||
        this.snapshot.navigationRevision !== this.seekNavigation)) this.cancelSeek()
  }

  aboutToDisappear(): void { this.cancelSeek(); this.onMenuVisible(false) }

  private cancelSeek(): void {
    const hadPreview = this.seekUnit !== null
    this.preview = -1; this.seekUnit = null; this.seekNavigation = -1
    if (hadPreview) this.onPreview(-1, null, -1)
  }
  private count(): number { return this.snapshot.unit?.pageCount ?? 0 }
  private page(): number { return this.count() > 0 ? (this.snapshot.anchor?.sourceIndexHint ?? 0) + 1 : 0 }
  private value(): number { return this.preview >= 1 ? this.preview : this.page() }

  private beginSeek(): void {
    if (!this.active || this.snapshot.phase !== 'ready' || this.snapshot.unit === null) return
    this.seekUnit = this.snapshot.unit.key.copy()
    this.seekNavigation = this.snapshot.navigationRevision
  }

  private commitSeek(value: number): void {
    const unit = this.seekUnit
    const navigation = this.seekNavigation
    const current = this.active && this.snapshot.phase === 'ready' && unit !== null &&
      this.snapshot.unit?.key.equals(unit) && this.snapshot.navigationRevision === navigation
    if (current && unit !== null) this.onSeek(Math.round(value) - 1, unit, navigation)
    this.cancelSeek()
  }

  private sliderChanged(value: number, mode: SliderChangeMode): void {
    if (mode === SliderChangeMode.Begin) this.beginSeek()
    if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
      if (this.seekUnit !== null && this.preview !== Math.round(value)) {
        this.preview = Math.round(value)
        this.onPreview(this.preview - 1, this.seekUnit.copy(), this.seekNavigation)
      }
    } else if (mode === SliderChangeMode.Click) {
      if (this.seekUnit === null) this.beginSeek()
      this.commitSeek(value)
    } else if (mode === SliderChangeMode.End) this.commitSeek(value)
  }

  private setLayout(layout: 'single' | 'spread' | 'continuous'): void {
    const policy = this.snapshot.policy.copy()
    policy.layout = layout
    this.onPolicy(policy)
  }

  @Builder
  private RuntimeMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.rkit_single') }).onClick((): void => { this.setLayout('single') })
      MenuItem({ content: $r('app.string.rkit_spread') }).onClick((): void => { this.setLayout('spread') })
      MenuItem({ content: $r('app.string.rkit_continuous') }).onClick((): void => { this.setLayout('continuous') })
      MenuItem({ content: this.snapshot.policy.direction === 'ltr' ? $r('app.string.rkit_rtl') : $r('app.string.rkit_ltr') })
        .enabled(this.snapshot.policy.layout !== 'continuous')
        .onClick((): void => {
          const policy = this.snapshot.policy.copy()
          policy.direction = policy.direction === 'ltr' ? 'rtl' : 'ltr'
          this.onPolicy(policy)
        })
      MenuItem({ content: this.snapshot.policy.firstPageAlone ? $r('app.string.rkit_cover_off') : $r('app.string.rkit_cover_on') })
        .enabled(this.snapshot.policy.layout === 'spread')
        .onClick((): void => {
          const policy = this.snapshot.policy.copy()
          policy.firstPageAlone = !policy.firstPageAlone
          this.onPolicy(policy)
        })
      MenuItem({ content: this.snapshot.policy.splitWidePages ? $r('app.string.rkit_split_off') : $r('app.string.rkit_split_on') })
        .enabled(this.snapshot.policy.layout === 'single')
        .onClick((): void => {
          const policy = this.snapshot.policy.copy()
          policy.splitWidePages = !policy.splitWidePages
          this.onPolicy(policy)
        })
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Stack({ alignContent: Alignment.Center }) {
        Row() {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(22).fontColor([Color.White])
          }.width(44).height(44).backgroundColor(Color.Transparent)
            .id('rkit-close').accessibilityText($r('app.string.rkit_close'))
            .onClick((): void => { this.onClose() })
          Blank()
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.gearshape')).fontSize(22).fontColor([Color.White])
          }.width(44).height(44).backgroundColor(Color.Transparent)
            .id('rkit-runtime-settings').accessibilityText($r('app.string.rkit_runtime_settings'))
            .enabled(this.active && this.snapshot.phase === 'ready')
            .bindMenu(this.RuntimeMenu, {
              aboutToAppear: (): void => { this.onMenuVisible(true) },
              onDisappear: (): void => { this.onMenuVisible(false) },
            })
        }.width('100%').height(56).alignItems(VerticalAlign.Center)
        Text(`${this.page()} / ${this.count()}`).fontSize(14).fontColor(Color.White)
          .maxLines(1).textAlign(TextAlign.Center).hitTestBehavior(HitTestMode.None)
          .id('rkit-chrome-page')
      }.width('100%').height(this.topInset + 56)
        .padding({ top: this.topInset, left: 8, right: 8 })
        .backgroundColor('#CC000000').position({ x: 0, y: 0 })
        .id('rkit-chrome-top')

      Column({ space: 4 }) {
        Row({ space: 4 }) {
          Text(`${this.snapshot.policy.direction === 'rtl' ? this.count() : this.value()}`)
            .fontSize(14).fontColor(Color.White).constraintSize({ minWidth: 30 }).maxLines(1)
          Slider({ value: Math.max(1, this.value()), min: 1, max: Math.max(2, this.count()), step: 1,
            style: SliderStyle.InSet, reverse: this.snapshot.policy.direction === 'rtl' })
            .layoutWeight(1).trackColor('#33FFFFFF').selectedColor(this.accent)
            .enabled(this.active && this.snapshot.phase === 'ready' && this.count() > 1)
            .id('rkit-source-slider').accessibilityText($r('app.string.rkit_seek_page'))
            .onChange((value: number, mode: SliderChangeMode): void => { this.sliderChanged(value, mode) })
            .onTouch((event: TouchEvent): void => {
              if (event.type === TouchType.Cancel) this.cancelSeek()
            })
          Text(`${this.snapshot.policy.direction === 'rtl' ? this.value() : this.count()}`)
            .fontSize(14).fontColor(Color.White).constraintSize({ minWidth: 30 }).maxLines(1).textAlign(TextAlign.End)
        }.width('100%').alignItems(VerticalAlign.Center)
        Row() {
          // Host image actions and auto-reading remain separate capability slices.
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.rectangle_grid_2x1')).fontSize(22)
              .fontColor([this.thumbnailsVisible ? this.accent : Color.White])
          }.width(44).height(44).backgroundColor(Color.Transparent)
            .enabled(this.active && this.snapshot.phase === 'ready')
            .id('rkit-toggle-thumbnails').accessibilityText($r('app.string.rkit_thumbnail'))
            .onClick(this.onThumbnails)
          Blank()
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.book')).fontSize(22)
              .fontColor([this.snapshot.policy.layout === 'spread' ? this.accent : Color.White])
          }.width(44).height(44).backgroundColor(Color.Transparent)
            .enabled(this.active && this.snapshot.phase === 'ready' && this.snapshot.policy.layout !== 'continuous')
            .id('rkit-toggle-spread').accessibilityText($r('app.string.rkit_spread'))
            .onClick((): void => { this.setLayout(this.snapshot.policy.layout === 'spread' ? 'single' : 'spread') })
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph(this.snapshot.policy.layout === 'continuous' ? $r('sys.symbol.scroll_vertical') :
              this.snapshot.policy.direction === 'rtl' ? $r('sys.symbol.arrow_left_and_square') : $r('sys.symbol.arrow_right_and_square')).fontSize(22).fontColor([Color.White])
          }.width(44).height(44).backgroundColor(Color.Transparent)
            .enabled(this.active && this.snapshot.phase === 'ready')
            .id('rkit-reading-mode').accessibilityText($r('app.string.rkit_runtime_settings'))
            .bindMenu(this.RuntimeMenu, {
              aboutToAppear: (): void => { this.onMenuVisible(true) },
              onDisappear: (): void => { this.onMenuVisible(false) },
            })
        }.width('100%').alignItems(VerticalAlign.Center)
      }.width('100%').height(this.bottomInset + 112)
        .padding({ left: 16, right: 16, top: 8, bottom: this.bottomInset + 8 })
        .backgroundColor('#CC000000').id('rkit-chrome-bottom')
    }.width('100%').height('100%').hitTestBehavior(HitTestMode.Transparent)
  }
}
