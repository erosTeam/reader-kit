import { LengthMetrics } from '@kit.ArkUI'
import { ReaderEnhancementStatus } from './ReaderEnhancementStatus'

/** Passive reading status, outlined for both light and dark original pages. */
@ComponentV2
export struct ReaderPageStatus {
  @Require @Param value: string
  @Param bottomMargin: number = 0
  @Param showPageNumber: boolean = true
  @Param showEnhancement: boolean = false
  @Param enhancementProcessing: boolean = false
  @Param enhancementApplied: boolean = false
  @Param enhancementEnabled: boolean = true
  @Param enhancementToggleAvailable: boolean = false
  @Param accent: ResourceColor = '#D93646'
  @Event onToggleEnhancement: () => void = () => {}
  private controller: TextController = new TextController()

  @Monitor('value')
  updateText(): void {
    const styled = new MutableStyledString(this.value, [])
    styled.setStyle({ start: 0, length: this.value.length, styledKey: StyledStringKey.FONT,
      styledValue: new TextStyle({ fontColor: '#99FFFFFF', fontSize: LengthMetrics.vp(14),
        fontWeight: FontWeight.Medium, strokeWidth: LengthMetrics.vp(-2.5), strokeColor: '#80000000' }),
    })
    this.controller.setStyledString(styled)
  }

  build() {
    Row({ space: 4 }) {
      if (this.showPageNumber) {
        Text(undefined, { controller: this.controller }).textAlign(TextAlign.Center).maxLines(1)
          .onAppear((): void => { this.updateText() }).id('rkit-persistent-page')
      }
      if (this.showEnhancement) {
        ReaderEnhancementStatus({ processing: this.enhancementProcessing,
          applied: this.enhancementApplied, enhancementEnabled: this.enhancementEnabled,
          toggleAvailable: this.enhancementToggleAvailable, accent: this.accent,
          onToggle: (): void => { this.onToggleEnhancement() } })
      }
    }.width('100%').justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
      .margin({ bottom: this.bottomMargin })
      .hitTestBehavior(this.enhancementToggleAvailable ? HitTestMode.Transparent : HitTestMode.None)
  }
}
