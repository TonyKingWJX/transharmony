import { TranslatorAdapter } from './TranslatorAdapter';
import {
  LangCode,
  TranslationRequest,
  TranslationResult,
  TranslateError,
  TranslateStyle,
  langLabel
} from '../models/TranslationTypes';
import { postJson, postStream, truncate } from '../utils/HttpClient';
import { safeParse, getStr, getArr, getNum, getObj } from '../utils/JsonUtil';
import { aiLangName } from './LangMaps';

/**
 * OpenAI Chat Completions 兼容 AI 适配器。
 * DeepSeek / GLM / 通义 / Kimi 等均兼容该协议，仅 Base URL 与模型名不同。
 * BYOK：Key 由用户在设置页填写，仅存本机，请求直连服务商。
 */
interface ChatMessage {
  role: string;
  content: string;
}

interface ChatRequestBody {
  model: string;
  messages: ChatMessage[];
  temperature: number;
  stream: boolean;
}

export class OpenAICompatAdapter implements TranslatorAdapter {
  readonly id: string;
  readonly label: string;
  readonly isAI = true;
  readonly supportsStyle = true;
  readonly needsConfig = true;

  private baseUrl: string;
  private model: string;
  private apiKey: string = '';
  /** 用户自定义 Prompt（空 = 用默认模板） */
  private customPrompt: string = '';

  constructor(id: string, label: string, baseUrl: string, model: string) {
    this.id = id;
    this.label = label;
    this.baseUrl = baseUrl;
    this.model = model;
  }

  setApiKey(key: string): void {
    this.apiKey = key;
  }

  /** 用户可在 AI 配置页自定义 API 地址（覆盖预置 Base URL） */
  setBaseUrl(url: string): void {
    this.baseUrl = url;
  }

  /** 模型名可在设置里切换（如 deepseek-chat → deepseek-reasoner） */
  setModel(model: string): void {
    this.model = model;
  }

  /** 注入用户自定义翻译 Prompt（空串表示使用内置默认模板） */
  setCustomPrompt(prompt: string): void {
    this.customPrompt = prompt;
  }

  getEndpoint(): string {
    return this.baseUrl + '/chat/completions';
  }

  supportedLangs(): LangCode[] {
    return ['zh', 'en', 'ja', 'ko', 'fr', 'de', 'ru', 'es', 'th', 'vi'];
  }

  async translate(req: TranslationRequest): Promise<TranslationResult> {
    if (this.apiKey.length === 0) {
      throw new TranslateError(this.id, 3001, '请先在设置中配置 ' + this.label + ' 的 API Key');
    }
    const systemPrompt = this.customPrompt.trim().length > 0
      ? applyCustomPrompt(this.customPrompt, req.to)
      : buildPrompt(req.to, req.style ?? 'plain');
    const messages: ChatMessage[] = [
      { role: 'system', content: systemPrompt },
      { role: 'user', content: req.text }
    ];
    const reqBody: ChatRequestBody = {
      model: this.model,
      messages: messages,
      temperature: 1.3,
      stream: false
    };
    const body = JSON.stringify(reqBody);

    const resp = await postJson({
      url: this.getEndpoint(),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + this.apiKey
      },
      body: body,
      timeoutMs: 60000
    });

    const root = safeParse(resp.body);
    if (root === null) {
      throw new TranslateError(this.id, 3002, this.label + '响应解析失败: ' + truncate(resp.body, 120));
    }
    const errObj = getObj(root, 'error');
    if (errObj !== null) {
      throw new TranslateError(this.id, 3003,
        this.label + '错误: ' + getStr(errObj, 'message'));
    }
    const choices = getArr(root, 'choices');
    if (choices.length === 0) {
      throw new TranslateError(this.id, 3004, this.label + '无返回结果');
    }
    const message = getObj(choices[0], 'message');
    const content = message === null ? '' : getStr(message, 'content');
    const result: TranslationResult = {
      text: content.trim(),
      providerId: this.id
    };
    const usage = getObj(root, 'usage');
    if (usage !== null) {
      result.usage = {
        promptTokens: getNum(usage, 'prompt_tokens'),
        completionTokens: getNum(usage, 'completion_tokens')
      };
    }
    return result;
  }

  /** 流式翻译：stream:true + SSE，逐段回传累积文本，最终 resolve 完整结果 */
  async translateStream(req: TranslationRequest, onDelta: (fullText: string) => void): Promise<TranslationResult> {
    if (this.apiKey.length === 0) {
      throw new TranslateError(this.id, 3001, '请先在设置中配置 ' + this.label + ' 的 API Key');
    }
    const systemPrompt = this.customPrompt.trim().length > 0
      ? applyCustomPrompt(this.customPrompt, req.to)
      : buildPrompt(req.to, req.style ?? 'plain');
    const messages: ChatMessage[] = [
      { role: 'system', content: systemPrompt },
      { role: 'user', content: req.text }
    ];
    const reqBody: ChatRequestBody = {
      model: this.model,
      messages: messages,
      temperature: 1.3,
      stream: true
    };
    const body = JSON.stringify(reqBody);

    let full = '';
    let usagePrompt = -1;
    let usageCompletion = -1;
    let errMsg = '';
    try {
      await postStream({
        url: this.getEndpoint(),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + this.apiKey
        },
        body: body,
        timeoutMs: 90000,
        onChunk: (payload: string): void => {
          const root = safeParse(payload);
          if (root === null) {
            return;
          }
          const errObj = getObj(root, 'error');
          if (errObj !== null) {
            errMsg = getStr(errObj, 'message');
            return;
          }
          const usage = getObj(root, 'usage');
          if (usage !== null) {
            usagePrompt = getNum(usage, 'prompt_tokens');
            usageCompletion = getNum(usage, 'completion_tokens');
          }
          const choices = getArr(root, 'choices');
          if (choices.length === 0) {
            return;
          }
          const delta = getObj(choices[0], 'delta');
          const piece = delta === null ? '' : getStr(delta, 'content');
          if (piece.length > 0) {
            full += piece;
            onDelta(full);
          }
        }
      });
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      throw new TranslateError(this.id, 3005, this.label + '流式请求失败: ' + msg);
    }
    if (errMsg.length > 0) {
      throw new TranslateError(this.id, 3003, this.label + '错误: ' + errMsg);
    }
    const result: TranslationResult = {
      text: full.trim(),
      providerId: this.id
    };
    if (usagePrompt >= 0 || usageCompletion >= 0) {
      result.usage = {
        promptTokens: usagePrompt >= 0 ? usagePrompt : undefined,
        completionTokens: usageCompletion >= 0 ? usageCompletion : undefined
      };
    }
    return result;
  }
}

/** 预置 AI 服务商清单已迁至 ProviderCatalog（AI_PROVIDERS）；此处仅保留协议实现 */

/**
 * 默认翻译 Prompt：融合 mango 翻译的三条输出规则（仅译文/保格式/术语标注），
 * 风格化要求仅在默认模板下生效（自定义 Prompt 时完全交给用户）。
 */
export function buildPrompt(to: LangCode, style: TranslateStyle): string {
  const target = langLabel(to);
  let styleLine = '- 保持原文的语气与格式';
  switch (style) {
    case 'polished':
      styleLine = '- 译文要地道自然，符合目标语言的表达习惯，不要逐字直译';
      break;
    case 'formal':
      styleLine = '- 使用正式书面语体，并保持原文格式';
      break;
    case 'casual':
      styleLine = '- 使用轻松口语化语体，并保持原文格式';
      break;
    default:
      break;
  }
  return 'You are a professional translator. Translate the input text into ' + target + '.\n'
    + 'Rules:\n'
    + '- Output ONLY the translation, no explanation, no quotes, no prefixes or suffixes\n'
    + '- Preserve original formatting, line breaks, and punctuation\n'
    + '- For technical terms, keep the English original in parentheses\n'
    + styleLine;
}

/**
 * 自定义 Prompt 应用：把 {target_language} 替换为目标语言名；
 * 未写占位符时把目标语言追加到末尾（保证模型知道往哪种语言翻）。
 */
export function applyCustomPrompt(template: string, to: LangCode): string {
  const target = langLabel(to);
  const t = template.trim();
  if (t.includes('{target_language}')) {
    return t.split('{target_language}').join(target);
  }
  return t + '\n\nTarget language: ' + target;
}

/** 配置页展示的默认 Prompt 全文（供自定义参考） */
export function defaultPromptText(): string {
  return buildPrompt('en', 'plain');
}
