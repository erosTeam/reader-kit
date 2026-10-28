import { ColorMetrics } from '@kit.ArkUI'
import { READER_ENHANCEMENT_ACTIVE_ALPHA, readerEnhancementContentColor } from './ReaderEnhancementContrast'

/** Hosts own processors; reader-kit shows only current presentation state. */
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

  private active(): boolean {
    return this.enhancementEnabled && (this.processing || this.applied)
  }

  private activeFill(): string {
    const color = ColorMetrics.resourceColor(this.accent)
    // Keep the adopted theme fill, but let the comic show through. Ink selection
    // accounts for both darkest and lightest content underneath this 80% fill.
    return ColorMetrics.rgba(color.red, color.green, color.blue, READER_ENHANCEMENT_ACTIVE_ALPHA).color
  }

  private activeInk(): string {
    const color = ColorMetrics.resourceColor(this.accent)
    return readerEnhancementContentColor(color.red, color.green, color.blue)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.enhancementEnabled && this.processing) {
        LoadingProgress().width(14).height(14).color(this.activeInk())
      } else {
        SymbolGlyph($r('sys.symbol.AI_hd_rectangle')).fontSize(14)
          .fontColor([this.active() ? this.activeInk() : Color.White])
          .opacity(this.active() ? 1 : this.enhancementEnabled ? 0.78 : 0.39)
      }
    }
      .width(22).height(22).borderRadius(11)
      .backgroundColor(this.active() ? this.activeFill() : '#26000000')
      .hitTestBehavior(this.toggleAvailable ? HitTestMode.Block : HitTestMode.None)
      .enabled(this.toggleAvailable)
      .onClick((): void => { if (this.toggleAvailable) this.onToggle() })
      .id('rkit-enhancement-status')
  }
}
