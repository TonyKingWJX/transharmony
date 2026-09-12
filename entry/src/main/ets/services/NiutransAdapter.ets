import { TranslatorAdapter } from './TranslatorAdapter';
import {
  AUTO_DETECT,
  LangCode,
  TranslationRequest,
  TranslationResult,
  TranslateError
} from '../models/TranslationTypes';
import { postJson, truncate } from '../utils/HttpClient';
import { safeParse, getStr } from '../utils/JsonUtil';

/**
 * 小牛翻译适配器（官方 API，NiuTransServer 文本翻译）。
 * 接口：POST https://api.niutrans.com/NiuTransServer/translation（form-urlencoded）
 * 文档：https://niutrans.com/document/develop/website/10-api.php（开放平台 API Key）
 * 参数：from / to / apikey / src_text；from=auto 自动检测。
 * 响应：{ "tgt_text": "...", "from": "zh", ... }；错误 { "error_code": "...", "error_msg": "..." }
 * 语言代码：zh / cht / yue / en / ja / ko / fr / es / ru / de / th / vi…
 */
export class NiutransAdapter implements TranslatorAdapter {
  readonly id: string;
  readonly label: string;
  readonly isAI = false;
  readonly supportsStyle = false;
  readonly needsConfig = true;

  private apiKey: string = '';

  constructor(id: string = 'niutrans', label: string = '小牛翻译') {
    this.id = id;
    this.label = label;
  }

  setCredentials(apiKey: string): void {
    this.apiKey = apiKey;
  }

  supportedLangs(): LangCode[] {
    return ['zh', 'en', 'ja', 'ko', 'fr', 'de', 'ru', 'es', 'th', 'vi'];
  }

  private static toCode(code: LangCode): string {
    const map: Record<string, string> = {
      'zh': 'zh', 'en': 'en', 'ja': 'ja', 'ko': 'ko',
      'fr': 'fr', 'de': 'de', 'ru': 'ru', 'es': 'es', 'th': 'th', 'vi': 'vi'
    };
    return map[code] ?? code;
  }

  async translate(req: TranslationRequest): Promise<TranslationResult> {
    if (this.apiKey.length === 0) {
      throw new TranslateError(this.id, 2701, '请先在设置中配置小牛翻译 API Key');
    }
    const body = 'from=' + encodeURIComponent(req.from === AUTO_DETECT ? 'auto' : NiutransAdapter.toCode(req.from))
      + '&to=' + encodeURIComponent(NiutransAdapter.toCode(req.to))
      + '&apikey=' + encodeURIComponent(this.apiKey)
      + '&src_text=' + encodeURIComponent(req.text);

    const resp = await postJson({
      url: 'https://api.niutrans.com/NiuTransServer/translation',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body,
      timeoutMs: 15000
    });

    const root = safeParse(resp.body);
    if (root === null) {
      throw new TranslateError(this.id, 2702, '小牛翻译响应解析失败: ' + truncate(resp.body, 120));
    }
    const errCode = getStr(root, 'error_code');
    if (errCode.length > 0) {
      throw new TranslateError(this.id, 2703,
        '小牛翻译错误 ' + errCode + ': ' + getStr(root, 'error_msg'));
    }
    const tgt = getStr(root, 'tgt_text');
    if (tgt.length === 0) {
      throw new TranslateError(this.id, 2704, '小牛翻译无返回结果: ' + truncate(resp.body, 160));
    }
    const result: TranslationResult = {
      text: tgt,
      providerId: this.id
    };
    if (req.from === AUTO_DETECT) {
      const detected = getStr(root, 'from');
      if (detected.length > 0) {
        result.detectedFrom = detected;
      }
    }
    return result;
  }
}
