import { TranslatorAdapter } from './TranslatorAdapter';
import {
  AUTO_DETECT,
  LangCode,
  TranslationRequest,
  TranslationResult,
  TranslateError
} from '../models/TranslationTypes';
import { postJson, truncate } from '../utils/HttpClient';
import { safeParse, getNum, getStr, getStrArr } from '../utils/JsonUtil';
import { youdaoCode, youdaoFromYoudao } from './LangMaps';

/**
 * 有道免费翻译通道（非官方接口，Path C）。
 * 有道 AI 文本翻译演示页使用的端点，无需签名：
 * POST https://aidemo.youdao.com/trans  表单: q / from / to
 * 源语言为自动检测时 from、to 均传 'Auto'；响应 type 形如 'zh-CHS2en'，可反解检测语言。
 * 限制：单次最多 1000 字符（aidemo 页面限制）。
 * 定位：免费兜底引擎之一；⚠️ 非公开契约接口，签名/参数可能随页面调整。
 */
export class YoudaoAdapter implements TranslatorAdapter {
  readonly id = 'youdao';
  readonly label = '有道翻译';
  readonly isAI = false;
  readonly supportsStyle = false;
  readonly needsConfig = false;

  private readonly endpoint = 'https://aidemo.youdao.com/trans';
  /** aidemo 页面限制的单次字符数 */
  private readonly inputLimit = 1000;

  supportedLangs(): LangCode[] {
    return ['zh', 'en', 'ja', 'ko', 'fr', 'de', 'ru', 'es', 'th', 'vi'];
  }

  async translate(req: TranslationRequest): Promise<TranslationResult> {
    if (req.text.length > this.inputLimit) {
      throw new TranslateError(this.id, 2301,
        '有道免费通道单次最多 ' + this.inputLimit + ' 字符，请缩短文本或改用其他引擎');
    }

    // 自动检测时仅 from 传 'Auto'；to 必须传真实目标语言，否则接口默认译成英文
    const from = req.from === AUTO_DETECT ? 'Auto' : youdaoCode(req.from);
    const to = youdaoCode(req.to);

    const body = 'q=' + encodeURIComponent(req.text)
      + '&from=' + encodeURIComponent(from)
      + '&to=' + encodeURIComponent(to);

    const headers: Record<string, string> = {
      'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
      'Referer': 'https://ai.youdao.com/product-fanyi-text.s'
    };

    const resp = await postJson({
      url: this.endpoint,
      headers: headers,
      body: body,
      timeoutMs: 15000
    });

    const root = safeParse(resp.body);
    if (root === null) {
      throw new TranslateError(this.id, 2302, '有道翻译无有效返回: ' + truncate(resp.body, 120));
    }
    const errCode = getNum(root, 'errorCode');
    if (errCode !== 0) {
      throw new TranslateError(this.id, 2303, '有道翻译错误码 ' + errCode + '（可能请求过频，请稍后重试）');
    }
    const translations = getStrArr(root, 'translation');
    if (translations.length === 0) {
      throw new TranslateError(this.id, 2304, '有道翻译响应缺少 translation 字段');
    }

    const result: TranslationResult = {
      text: translations[0],
      providerId: this.id
    };

    // type 形如 'zh-CHS2en'，反解检测到的源语言
    const type = getStr(root, 'type');
    if (type.length > 0 && type.indexOf('2') > 0) {
      const detected = type.substring(0, type.indexOf('2'));
      result.detectedFrom = youdaoFromYoudao(detected);
    }
    return result;
  }
}
