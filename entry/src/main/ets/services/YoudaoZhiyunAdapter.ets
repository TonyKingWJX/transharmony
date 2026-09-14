import { TranslatorAdapter } from './TranslatorAdapter';
import {
  AUTO_DETECT,
  LangCode,
  TranslationRequest,
  TranslationResult,
  TranslateError,
  CORE_LANGS,
} from '../models/TranslationTypes';
import { postJson, truncate } from '../utils/HttpClient';
import { sha256Hex } from '../utils/HashUtil';
import { safeParse, getNum, getStr, getStrArr } from '../utils/JsonUtil';

/**
 * 有道智云文本翻译适配器（官方 API）。
 * 接口：POST https://openapi.youdao.com/api（form-urlencoded）
 * 文档：https://ai.youdao.com/DOCSIRMA/html/自然语言翻译/API文档/文本翻译服务/文本翻译服务-API文档.html
 * 签名（signType=v3）：sign = sha256(appKey + input + salt + curtime + appSecret)
 * 其中 input = q 前10字符 + q长度 + q 后10字符（q ≤ 20 时取全文）。
 * 响应：translation 数组 + l 命中语言（"l" 形如 "zh-CHS"）；错误时 errorCode 非 0。
 */
export class YoudaoZhiyunAdapter implements TranslatorAdapter {
  readonly id: string;
  readonly label: string;
  readonly isAI = false;
  readonly supportsStyle = false;
  readonly needsConfig = true;

  private appKey: string = '';
  private appSecret: string = '';

  /** id 可带实例后缀（同一目录可添加多个实例） */
  constructor(id: string = 'youdao-zhiyun', label: string = '有道翻译') {
    this.id = id;
    this.label = label;
  }

  setCredentials(appKey: string, appSecret: string): void {
    this.appKey = appKey;
    this.appSecret = appSecret;
  }

  supportedLangs(): LangCode[] {
    return CORE_LANGS;
  }

  /** 内部代码 → 有道代码：zh→zh-CHS、ja→jp、vi→vie */
  private static toCode(code: LangCode): string {
    const map: Record<string, string> = {
      'zh': 'zh-CHS',
      'ja': 'jp',
      'vi': 'vie',
      'en': 'en', 'ko': 'ko', 'fr': 'fr', 'de': 'de', 'ru': 'ru', 'es': 'es', 'th': 'th'
    };
    return map[code] ?? code;
  }

  /** 有道检测语言 → 内部代码（响应 "l" 字段，如 zh-CHS） */
  private static fromCode(code: string): LangCode {
    const map: Record<string, string> = {
      'zh-CHS': 'zh', 'zh-CHT': 'zh', 'jp': 'ja', 'vie': 'vi'
    };
    return map[code] ?? code;
  }

  async translate(req: TranslationRequest): Promise<TranslationResult> {
    if (this.appKey.length === 0 || this.appSecret.length === 0) {
      throw new TranslateError(this.id, 2201, '请先在设置中配置有道智云应用 ID 与密钥');
    }
    const q = req.text;
    const salt = Date.now().toString(16) + Math.floor(Math.random() * 0xffff).toString(16);
    const curtime = Math.floor(Date.now() / 1000).toString();
    // input 截取规则：q≤20 全文；否则前10 + 长度 + 后10
    const input = q.length <= 20 ? q
      : q.substring(0, 10) + q.length.toString() + q.substring(q.length - 10);
    const sign = await sha256Hex(this.appKey + input + salt + curtime + this.appSecret);

    const body = 'q=' + encodeURIComponent(q)
      + '&from=' + encodeURIComponent(req.from === AUTO_DETECT ? 'auto' : YoudaoZhiyunAdapter.toCode(req.from))
      + '&to=' + encodeURIComponent(YoudaoZhiyunAdapter.toCode(req.to))
      + '&appKey=' + encodeURIComponent(this.appKey)
      + '&salt=' + encodeURIComponent(salt)
      + '&sign=' + sign
      + '&signType=v3'
      + '&curtime=' + curtime;

    const resp = await postJson({
      url: 'https://openapi.youdao.com/api',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body,
      timeoutMs: 15000
    });

    const root = safeParse(resp.body);
    if (root === null) {
      throw new TranslateError(this.id, 2202, '有道智云响应解析失败: ' + truncate(resp.body, 120));
    }
    const errorCode = getNum(root, 'errorCode');
    if (errorCode !== 0) {
      throw new TranslateError(this.id, 2203,
        '有道智云错误码 ' + errorCode + '（101 密钥错误 / 110 无权限 / 310 请求语言不支持 / 205 服务异常，请检查凭证）');
    }
    const translations = getStrArr(root, 'translation');
    if (translations.length === 0) {
      throw new TranslateError(this.id, 2204, '有道智云无返回结果: ' + truncate(resp.body, 120));
    }
    const result: TranslationResult = {
      text: translations.join('\n'),
      providerId: this.id
    };
    if (req.from === AUTO_DETECT) {
      // 响应 "l" 为命中语言（字符串，如 zh-CHS）
      const detected = getStr(root, 'l');
      if (detected.length > 0) {
        result.detectedFrom = YoudaoZhiyunAdapter.fromCode(detected);
      }
    }
    return result;
  }
}
