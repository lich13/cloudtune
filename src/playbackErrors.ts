export function isNativeDecodePlaybackError(error: unknown) {
  return String(error).toLowerCase().includes('failed to decode audio file')
}
