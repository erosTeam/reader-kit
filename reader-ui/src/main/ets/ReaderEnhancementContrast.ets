export const READER_ENHANCEMENT_ACTIVE_ALPHA: number = 0.8

function linearChannel(channel: number): number {
  const value = channel / 255
  return value <= 0.04045 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4)
}

function luminance(red: number, green: number, blue: number, underlay: number): number {
  const alpha = READER_ENHANCEMENT_ACTIVE_ALPHA
  return 0.2126 * linearChannel(red * alpha + underlay * (1 - alpha)) +
    0.7152 * linearChannel(green * alpha + underlay * (1 - alpha)) +
    0.0722 * linearChannel(blue * alpha + underlay * (1 - alpha))
}

/** Choose the stronger worst-case contrast over a black or white comic behind the translucent fill. */
export function readerEnhancementContentColor(red: number, green: number, blue: number): string {
  const blackContrast = (luminance(red, green, blue, 0) + 0.05) / 0.05
  const whiteContrast = 1.05 / (luminance(red, green, blue, 255) + 0.05)
  return blackContrast >= whiteContrast ? '#000000' : '#FFFFFF'
}
