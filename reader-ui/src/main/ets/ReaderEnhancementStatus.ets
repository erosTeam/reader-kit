/** Passive processed-image status. Hosts own processors; reader-kit shows only current presentation state. */
@ComponentV2
export struct ReaderEnhancementStatus {
  @Param processing: boolean = false
  @Param applied: boolean = false
  /** A temporary current-unit override is visually disabled, not hidden. */
  @Param enhancementEnabled: boolean = true
  /** Only an explicitly capable host turns the status leaf into a hot zone. */
  @Param toggleAvailable: boolean = false
  @Param accent: ResourceColor = '#D93646'
  @Event onToggle: () => void = () => {}

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.enhancementEnabled && this.processing) {
        LoadingProgress().width(14).height(14).color(Color.White).opacity(0.78)
      } else {
        SymbolGlyph($r('sys.symbol.AI_hd_rectangle')).fontSize(14)
          .fontColor([this.enhancementEnabled && this.applied ? this.accent : Color.White])
          .opacity(this.enhancementEnabled ? 0.78 : 0.39)
      }
    }
      .width(22).height(22).borderRadius(11).backgroundColor('#66000000')
      .hitTestBehavior(this.toggleAvailable ? HitTestMode.Block : HitTestMode.None)
      .enabled(this.toggleAvailable)
      .onClick((): void => { if (this.toggleAvailable) this.onToggle() })
      .id('rkit-enhancement-status')
  }
}
