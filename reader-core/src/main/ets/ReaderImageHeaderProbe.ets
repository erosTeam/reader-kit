/** Image pixel size read from an encoded image header. */
export interface ReaderImagePixelSize {
  width: number
  height: number
}

const MAX_IMAGE_HEADER_BYTES: number = 64 * 1024

function be32(bytes: Uint8Array, offset: number): number {
  return ((bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3]) >>> 0
}

function be16(bytes: Uint8Array, offset: number): number {
  return (bytes[offset] << 8) | bytes[offset + 1]
}

function le16(bytes: Uint8Array, offset: number): number {
  return bytes[offset] | (bytes[offset + 1] << 8)
}

function jpegFrameSize(bytes: Uint8Array): ReaderImagePixelSize | undefined {
  let offset = 2
  while (offset + 4 <= bytes.length) {
    if (bytes[offset] !== 0xFF) {
      offset += 1
      continue
    }
    const marker = bytes[offset + 1]
    if (marker === 0xD8 || marker === 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      offset += 2
      continue
    }
    if (marker === 0xD9 || marker === 0xDA) return undefined
    const segment = be16(bytes, offset + 2)
    if (segment < 2) return undefined
    const isFrame = (marker >= 0xC0 && marker <= 0xC3) || (marker >= 0xC5 && marker <= 0xC7) ||
      (marker >= 0xC9 && marker <= 0xCB) || (marker >= 0xCD && marker <= 0xCF)
    if (isFrame) {
      if (offset + 9 > bytes.length) return undefined
      return { height: be16(bytes, offset + 5), width: be16(bytes, offset + 7) }
    }
    offset += 2 + segment
  }
  return undefined
}

function webpSize(bytes: Uint8Array): ReaderImagePixelSize | undefined {
  if (bytes.length < 30) return undefined
  if (bytes[12] === 0x56 && bytes[13] === 0x50 && bytes[14] === 0x38 && bytes[15] === 0x58) {
    return {
      width: 1 + (bytes[24] | (bytes[25] << 8) | (bytes[26] << 16)),
      height: 1 + (bytes[27] | (bytes[28] << 8) | (bytes[29] << 16)),
    }
  }
  if (bytes[12] === 0x56 && bytes[13] === 0x50 && bytes[14] === 0x38 && bytes[15] === 0x4C) {
    if (bytes.length < 25 || bytes[20] !== 0x2F) return undefined
    const bits = (bytes[21] | (bytes[22] << 8) | (bytes[23] << 16) | (bytes[24] << 24)) >>> 0
    return { width: (bits & 0x3FFF) + 1, height: ((bits >> 14) & 0x3FFF) + 1 }
  }
  if (bytes[12] === 0x56 && bytes[13] === 0x50 && bytes[14] === 0x38 && bytes[15] === 0x20) {
    if (bytes.length < 30 || bytes[23] !== 0x9D || bytes[24] !== 0x01 || bytes[25] !== 0x2A) return undefined
    return { width: le16(bytes, 26) & 0x3FFF, height: le16(bytes, 28) & 0x3FFF }
  }
  return undefined
}

function ispeSize(bytes: Uint8Array): ReaderImagePixelSize | undefined {
  for (let index = 4; index + 16 <= bytes.length; index += 1) {
    if (bytes[index] !== 0x69 || bytes[index + 1] !== 0x73 ||
      bytes[index + 2] !== 0x70 || bytes[index + 3] !== 0x65) continue
    const width = be32(bytes, index + 8)
    const height = be32(bytes, index + 12)
    if (width > 0 && height > 0) return { width, height }
  }
  return undefined
}

/**
 * Read pixel dimensions from the beginning of an encoded image. Returns
 * undefined when the current bytes do not yet contain the size marker or the
 * format is not recognized; callers may feed more bytes and try again.
 */
export function readerImagePixelSize(bytes: Uint8Array): ReaderImagePixelSize | undefined {
  const length = bytes.length
  if (length >= 24 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4E && bytes[3] === 0x47) {
    return { width: be32(bytes, 16), height: be32(bytes, 20) }
  }
  if (length >= 10 && bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46) {
    return { width: le16(bytes, 6), height: le16(bytes, 8) }
  }
  if (length >= 4 && bytes[0] === 0xFF && bytes[1] === 0xD8) {
    return jpegFrameSize(bytes)
  }
  if (length >= 16 && bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46 &&
    bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50) {
    return webpSize(bytes)
  }
  if (length >= 16 && bytes[4] === 0x66 && bytes[5] === 0x74 && bytes[6] === 0x79 && bytes[7] === 0x70) {
    return ispeSize(bytes)
  }
  return undefined
}

/**
 * Incremental header probe for a single image response.
 *
 * A host feeds the chunks it already receives while downloading a page image.
 * The probe never issues a request and never waits for the complete payload:
 * it answers on the chunk that completes the header and releases its buffer.
 * Accumulating across chunks matters for JPEG, whose frame marker can sit
 * behind APPn/EXIF segments split over several reads.
 */
export class ReaderImageHeaderProbe {
  private buffer: Uint8Array = new Uint8Array(0)
  private resolved: ReaderImagePixelSize | undefined = undefined
  private stopped: boolean = false
  private readonly limit: number

  constructor(limit: number = MAX_IMAGE_HEADER_BYTES) {
    this.limit = limit
  }

  /** The size read so far, if any. */
  size(): ReaderImagePixelSize | undefined {
    return this.resolved
  }

  /** True once the probe found the size or gave up on the header. */
  done(): boolean {
    return this.stopped
  }

  /**
   * Feed one received chunk. Returns the size when it is known, including a
   * size completed by an earlier chunk. Synchronous and allocation-bounded;
   * safe to call from a network data callback.
   */
  push(chunk: ArrayBuffer): ReaderImagePixelSize | undefined {
    if (this.stopped) return this.resolved
    const incoming = new Uint8Array(chunk)
    if (incoming.length === 0) return undefined
    const keep = Math.min(this.buffer.length, this.limit)
    const combined = new Uint8Array(Math.min(this.limit, keep + incoming.length))
    combined.set(this.buffer.subarray(0, Math.min(keep, combined.length)), 0)
    const offset = Math.min(keep, combined.length)
    const room = combined.length - offset
    if (room > 0) combined.set(incoming.subarray(0, Math.min(room, incoming.length)), offset)
    this.buffer = combined
    this.resolved = readerImagePixelSize(combined)
    if (this.resolved !== undefined || combined.length >= this.limit) {
      this.stopped = true
      this.buffer = new Uint8Array(0)
    }
    return this.resolved
  }

  /** Drop accumulated bytes, keeping the probe reusable for another image. */
  reset(): void {
    this.buffer = new Uint8Array(0)
    this.resolved = undefined
    this.stopped = false
  }
}
