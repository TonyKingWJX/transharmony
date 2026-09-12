import {
  LangCode,
  TranslationRequest,
  TranslationResult,
  TranslateError
} from '../models/TranslationTypes';

/**
 * 引擎插件统一接口。
 * 新增引擎 = 新增一个实现本接口的 Adapter，UI 与领域层零改动。
 */
export interface TranslatorAdapter {
  /** 唯一 id，如 'tencent' | 'baidu' | 'ai-deepseek' */
  readonly id: string;
  /** UI 显示名 */
  readonly label: string;
  /** 是否 AI 大模型引擎 */
  readonly isAI: boolean;
  /** 是否支持风格指令（润色/正式/口语化） */
  readonly supportsStyle: boolean;
  /** 是否需要用户配置（如 BYOK 填 Key）才可用 */
  readonly needsConfig: boolean;

  translate(req: TranslationRequest): Promise<TranslationResult>;

  /**
   * 流式翻译（可选实现）：每次增量通过 onDelta 回调（累积后的完整文本），
   * 完成时 resolve 最终结果。未实现的适配器由调用方回退 translate()。
   */
  translateStream?(req: TranslationRequest, onDelta: (fullText: string) => void): Promise<TranslationResult>;

  /** 返回本引擎支持的目标语言代码（内部枚举） */
  supportedLangs(): LangCode[];
}

export function toTranslateError(providerId: string, code: number, raw: string): TranslateError {
  return new TranslateError(providerId, code, raw);
}
