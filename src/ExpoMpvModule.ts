import { NativeModule, requireNativeModule } from 'expo';

import type { ExpoMpvModuleEvents } from './ExpoMpv.types';

declare class ExpoMpvModule extends NativeModule<ExpoMpvModuleEvents> {
  releaseSession(sessionId: string): Promise<void>;
}

// This call loads the native module object from the JSI.
export default requireNativeModule<ExpoMpvModule>('ExpoMpv');
