import { TranslatorAdapter } from './TranslatorAdapter';
import {
  AUTO_DETECT,
  LangCode,
  TranslationRequest,
  TranslationResult,
  TranslateError
} from '../models/TranslationTypes';
import { postJson, truncate } from '../utils/HttpClient';
import { safeParse, getStr, getStrArr } from '../utils/JsonUtil';

/**
 * 彩云小译适配器（官方 API）。
 * 接口：POST https://api.interpreter.caiyunai.com/v1/translator
 * 文档：https://open.caiyunai.com/docs/（彩云小译 API）
 * 鉴权：请求头 X-Authorization: token <令牌>（开放平台控制台获取）
 * 请求体：{ source: [...行...], trans_type: "x2y", detect: true }
 * 响应：{ target: [...译文行...], confidence, detected_source }
 * trans_type 在源语言为 auto 时需 detect=true，目标语言照常；
 * 官方建议 trans_type 里的方向需与实际一致，auto 源由 detect 参数兜底。
 */
export class CaiyunAdapter implements TranslatorAdapter {
  readonly id: string;
  readonly label: string;
  readonly isAI = false;
  readonly supportsStyle = false;
  readonly needsConfig = true;

  private token: string = '';

  constructor(id: string = 'caiyun', label: string = '彩云小译') {
    this.id = id;
    this.label = label;
  }

  setCredentials(token: string): void {
    this.token = token;
  }

  supportedLangs(): LangCode[] {
    return ['zh', 'en', 'ja', 'ko', 'fr', 'de', 'ru', 'es', 'th', 'vi'];
  }

  /** 彩云语言代码：zh / en / ja / ko / fr / de（de→de）与内部一致，无额外映射 */
  private static toCode(code: LangCode): string {
    const map: Record<string, string> = {
      'zh': 'zh', 'en': 'en', 'ja': 'ja', 'ko': 'ko',
      'fr': 'fr', 'de': 'de', 'ru': 'ru', 'es': 'es', 'th': 'th', 'vi': 'vi'
    };
    return map[code] ?? code;
  }

  async translate(req: TranslationRequest): Promise<TranslationResult> {
    if (this.token.length === 0) {
      throw new TranslateError(this.id, 2401, '请先在设置中配置彩云小译令牌');
    }
    // 彩云 source 为字符串数组（按行拆分），trans_type 为 "源2目标"
    const source = req.text.split('\n');
    const fromCode = req.from === AUTO_DETECT ? 'auto' : CaiyunAdapter.toCode(req.from);
    const payload = JSON.stringify({
      source: source,
      trans_type: fromCode + '2' + CaiyunAdapter.toCode(req.to),
      detect: req.from === AUTO_DETECT,
      media: 'text',
      request_id: 'transharmony-' + Date.now().toString(16)
    });

    const resp = await postJson({
      url: 'https://api.interpreter.caiyunai.com/v1/translator',
      headers: {
        'Content-Type': 'application/json',
        'X-Authorization': 'token ' + this.token
      },
      body: payload,
      timeoutMs: 15000
    });

    const root = safeParse(resp.body);
    if (root === null) {
      throw new TranslateError(this.id, 2402, '彩云小译响应解析失败: ' + truncate(resp.body, 120));
    }
    const target = getStrArr(root, 'target');
    if (target.length === 0) {
      // 官方错误形如 {"error":"/v1/translator/invalid token"} 或 message 字段
      throw new TranslateError(this.id, 2403, '彩云小译无返回结果: ' + truncate(resp.body, 160));
    }
    const result: TranslationResult = {
      text: target.join('\n'),
      providerId: this.id
    };
    if (req.from === AUTO_DETECT) {
      // detected_source 官方返回为字符串
      const detected = getStr(root, 'detected_source');
      if (detected.length > 0) {
        result.detectedFrom = detected;
      }
    }
    return result;
  }
}
