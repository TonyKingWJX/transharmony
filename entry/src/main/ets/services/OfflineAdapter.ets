import { TranslatorAdapter } from './TranslatorAdapter';
import { LangCode, TranslationRequest, TranslationResult } from '../models/TranslationTypes';
import { OfflineTranslator, OFFLINE_ENGINE_ID } from './OfflineTranslator';

/**
 * 离线翻译适配器：端侧内置模型（中英双向），无网络、无凭证。
 * 与免费通道同为 needsConfig=false 的内置引擎，但不进「免费通道」分组：
 * 开关状态存 settingsStore 独立键（offline_*），管理入口为独立的离线翻译页。
 */
export class OfflineAdapter implements TranslatorAdapter {
  readonly id = OFFLINE_ENGINE_ID;
  readonly label = '离线翻译';
  readonly isAI = false;
  readonly supportsStyle = false;
  readonly needsConfig = false;

  supportedLangs(): LangCode[] {
    return OfflineTranslator.supportedLangs();
  }

  translate(req: TranslationRequest): Promise<TranslationResult> {
    return OfflineTranslator.translate(req);
  }
}
