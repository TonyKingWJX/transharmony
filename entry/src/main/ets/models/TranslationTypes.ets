/**
 * 领域层类型定义。
 * UI 层与引擎层只通过这里的类型通信，禁止出现各服务商私有字段。
 */

/** 内部统一语言代码（BCP-47 风格主子标签） */
export type LangCode = string;

export const AUTO_DETECT: LangCode = 'auto';

export interface LanguageItem {
  code: LangCode;
  /** 中文名，如「简体中文」 */
  label: string;
}

/** 支持的语言清单（首发范围：中英日韩 + 自动检测） */
export const LANGUAGE_LIST: LanguageItem[] = [
  { code: 'zh', label: '简体中文' },
  { code: 'en', label: '英语' },
  { code: 'ja', label: '日语' },
  { code: 'ko', label: '韩语' },
  { code: 'fr', label: '法语' },
  { code: 'de', label: '德语' },
  { code: 'ru', label: '俄语' },
  { code: 'es', label: '西班牙语' },
  { code: 'th', label: '泰语' },
  { code: 'vi', label: '越南语' }
];

export function langLabel(code: LangCode): string {
  if (code === AUTO_DETECT) {
    return '自动检测';
  }
  const hit = LANGUAGE_LIST.find((it) => it.code === code);
  return hit ? hit.label : code;
}

/** 翻译风格（AI 引擎专用，传统引擎忽略） */
export type TranslateStyle = 'plain' | 'polished' | 'formal' | 'casual';

/** 风格指令清单（翻译页 chips 用，'polished' 即「更地道」；供官方 ChipGroup 渲染） */
export const STYLE_OPTIONS: StyleOption[] = [
  { value: 'polished', label: '更地道' },
  { value: 'formal', label: '正式' },
  { value: 'casual', label: '口语化' },
  { value: 'plain', label: '忠实直译' }
];

export interface StyleOption {
  value: TranslateStyle;
  label: string;
}

/** 聚合翻译的单引擎视图状态（UI 层渲染用） */
export type AggregateStatus = 'loading' | 'done' | 'error';

export interface AggregateItem {
  engineId: string;
  label: string;
  isAI: boolean;
  status: AggregateStatus;
  text: string;
  /** 本引擎耗时（毫秒） */
  elapsedMs: number;
  error: string;
}

export interface TranslationRequest {
  text: string;
  from: LangCode;
  to: LangCode;
  style?: TranslateStyle;
}

export interface TokenUsage {
  promptTokens?: number;
  completionTokens?: number;
}

export interface TranslationResult {
  text: string;
  /** 引擎 id，如 'tencent' | 'baidu' | 'ai-deepseek' */
  providerId: string;
  detectedFrom?: LangCode;
  usage?: TokenUsage;
}

/** 引擎错误：带用户可读信息 */
export class TranslateError extends Error {
  readonly providerId: string;
  readonly code: number;

  constructor(providerId: string, code: number, message: string) {
    super(message);
    this.providerId = providerId;
    this.code = code;
  }
}
