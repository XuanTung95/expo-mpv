import ExpoMpvModule from './ExpoMpvModule';

/** Release the native player after every view using this session has unmounted. */
export function releaseMpvSession(sessionId: string): Promise<void> {
  return ExpoMpvModule.releaseSession(sessionId);
}
