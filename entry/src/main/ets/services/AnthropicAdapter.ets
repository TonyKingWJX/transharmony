import { TranslatorAdapter } from './TranslatorAdapter';
import {
  LangCode,
  TranslationRequest,
  TranslationResult,
  TranslateError
} from '../models/TranslationTypes';
import { postJson, postStream, truncate } from '../utils/HttpClient';
import { safeParse, getObj, getArr, getStr, getNum } from '../utils/JsonUtil';
import { aiLangName } from './LangMaps';
import { applyCustomPrompt } from './OpenAICompatAdapter';

interface AnthropicMessage {
  role: string;
  content: string;
}

/**
 * Anthropic Messages 兼容 AI 适配器（Claude 官方协议）。
 * 接口：POST {baseUrl}/v1/messages
 * 文档：https://docs.anthropic.com/en/api/messages
 * 鉴权：x-api-key 头 + anthropic-version 头（固定 2023-06-01）。
 * 请求：{ model, max_tokens, system, messages:[{role:"user",content}] }
 * 响应：{ content: [{type:"text",text:"..."}], usage:{input_tokens,output_tokens} }
 * BYOK：Key 由用户填写，仅存本机，请求直连服务商。
 */
export class AnthropicAdapter implements TranslatorAdapter {
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
  private static readonly VERSION = '2023-06-01';

  constructor(id: string, label: string, baseUrl: string, model: string) {
    this.id = id;
    this.label = label;
    this.baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    this.model = model;
  }

  setApiKey(key: string): void {
    this.apiKey = key;
  }

  setBaseUrl(url: string): void {
    this.baseUrl = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  }

  setModel(model: string): void {
    this.model = model;
  }

  /** 注入用户自定义翻译 Prompt（空串表示使用内置默认模板） */
  setCustomPrompt(prompt: string): void {
    this.customPrompt = prompt;
  }

  getEndpoint(): string {
    return this.baseUrl + '/v1/messages';
  }

  supportedLangs(): LangCode[] {
    return ['zh', 'en', 'ja', 'ko', 'fr', 'de', 'ru', 'es', 'th', 'vi'];
  }

  async translate(req: TranslationRequest): Promise<TranslationResult> {
    if (this.apiKey.length === 0) {
      throw new TranslateError(this.id, 3001, '请先在设置中配置 ' + this.label + ' 的 API Key');
    }
    const messages: AnthropicMessage[] = [
      { role: 'user', content: req.text }
    ];
    const systemPrompt = this.customPrompt.trim().length > 0
      ? applyCustomPrompt(this.customPrompt, req.to)
      : buildSystemPrompt(req.to, req.style ?? 'plain');
    const body = JSON.stringify({
      model: this.model,
      max_tokens: 4096,
      system: systemPrompt,
      messages: messages
    });

    const resp = await postJson({
      url: this.getEndpoint(),
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': this.apiKey,
        'anthropic-version': AnthropicAdapter.VERSION
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
      throw new TranslateError(this.id, 3003, this.label + '错误: ' + getStr(errObj, 'message'));
    }
    const content = getArr(root, 'content');
    if (content.length === 0) {
      throw new TranslateError(this.id, 3004, this.label + '无返回结果');
    }
    // content 数组可能含 text / thinking 块，只取 text 块拼接
    const parts: string[] = [];
    for (const block of content) {
      if (getStr(block, 'type') === 'text') {
        parts.push(getStr(block, 'text'));
      }
    }
    if (parts.length === 0) {
      throw new TranslateError(this.id, 3005, this.label + '返回无文本内容（可能是纯思考块）');
    }
    const result: TranslationResult = {
      text: parts.join('').trim(),
      providerId: this.id
    };
    const usage = getObj(root, 'usage');
    if (usage !== null) {
      result.usage = {
        promptTokens: getNum(usage, 'input_tokens'),
        completionTokens: getNum(usage, 'output_tokens')
      };
    }
    return result;
  }

  /** 流式翻译：stream:true + SSE（content_block_delta 事件逐段拼接） */
  async translateStream(req: TranslationRequest, onDelta: (fullText: string) => void): Promise<TranslationResult> {
    if (this.apiKey.length === 0) {
      throw new TranslateError(this.id, 3001, '请先在设置中配置 ' + this.label + ' 的 API Key');
    }
    const messages: AnthropicMessage[] = [
      { role: 'user', content: req.text }
    ];
    const systemPrompt = this.customPrompt.trim().length > 0
      ? applyCustomPrompt(this.customPrompt, req.to)
      : buildSystemPrompt(req.to, req.style ?? 'plain');
    const body = JSON.stringify({
      model: this.model,
      max_tokens: 4096,
      system: systemPrompt,
      messages: messages,
      stream: true
    });

    let full = '';
    let errMsg = '';
    try {
      await postStream({
        url: this.getEndpoint(),
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': this.apiKey,
          'anthropic-version': AnthropicAdapter.VERSION
        },
        body: body,
        timeoutMs: 90000,
        onChunk: (payload: string): void => {
          const root = safeParse(payload);
          if (root === null) {
            return;
          }
          const type = getStr(root, 'type');
          if (type === 'error') {
            const errObj = getObj(root, 'error');
            errMsg = errObj !== null ? getStr(errObj, 'message') : 'stream error';
            return;
          }
          if (type !== 'content_block_delta') {
            return;
          }
          const delta = getObj(root, 'delta');
          if (delta !== null && getStr(delta, 'type') === 'text_delta') {
            const piece = getStr(delta, 'text');
            if (piece.length > 0) {
              full += piece;
              onDelta(full);
            }
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
    if (full.trim().length === 0) {
      throw new TranslateError(this.id, 3004, this.label + '无返回结果');
    }
    const result: TranslationResult = {
      text: full.trim(),
      providerId: this.id
    };
    return result;
  }
}

/** Anthropic system 提示词（与 OpenAI 版 buildPrompt 规则对齐） */
function buildSystemPrompt(to: LangCode, style: string): string {
  const target = aiLangName(to);
  let styleLine = '- 保持原文的语气与格式';
  if (style === 'polished') {
    styleLine = '- 译文要地道自然，符合目标语言的表达习惯，不要逐字直译';
  } else if (style === 'formal') {
    styleLine = '- 使用正式书面语体，并保持原文格式';
  } else if (style === 'casual') {
    styleLine = '- 使用轻松口语化语体，并保持原文格式';
  }
  return 'You are a professional translator. Translate the input text into ' + target + '.\n'
    + 'Rules:\n'
    + '- Output ONLY the translation, no explanation, no quotes, no prefixes or suffixes\n'
    + '- Preserve original formatting, line breaks, and punctuation\n'
    + '- For technical terms, keep the English original in parentheses\n'
    + styleLine;
}
