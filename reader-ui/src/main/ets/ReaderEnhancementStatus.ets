/** Passive processed-image status. Hosts own processors; reader-kit shows only current presentation state. */
@ComponentV2
export struct ReaderEnhancementStatus {
  @Param processing: boolean = false
  @Param applied: boolean = false
  @Param accent: ResourceColor = '#D93646'

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.processing) {
        LoadingProgress().width(14).height(14).color(Color.White).opacity(0.78)
      } else {
        SymbolGlyph($r('sys.symbol.AI_hd_rectangle')).fontSize(14)
          .fontColor([this.applied ? this.accent : Color.White]).opacity(0.78)
      }
    }
      .width(22).height(22).borderRadius(11).backgroundColor('#66000000')
      .hitTestBehavior(HitTestMode.None).id('rkit-enhancement-status')
  }
}
