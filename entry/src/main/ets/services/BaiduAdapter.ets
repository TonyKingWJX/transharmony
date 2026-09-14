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
import { md5Hex } from '../utils/HashUtil';
import { safeParse, getStr, getArr, getObj } from '../utils/JsonUtil';
import { baiduCode } from './LangMaps';

/**
 * 百度翻译开放平台适配器。
 * 接入文档：https://fanyi-api.baidu.com/doc/21
 * 签名：MD5(appid + q + salt + 密钥)；标准版免费但 QPS=1。
 * 注意：q 需按 UTF-8 计算，签名与请求体里的 q 必须一致（form-urlencoded）。
 */
export class BaiduAdapter implements TranslatorAdapter {
  id = 'baidu';
  label = '百度翻译';
  readonly isAI = false;
  readonly supportsStyle = false;
  readonly needsConfig = true;

  private appid: string = '';
  private secret: string = '';

  setCredentials(appid: string, secret: string): void {
    this.appid = appid;
    this.secret = secret;
  }

  supportedLangs(): LangCode[] {
    return CORE_LANGS;
  }

  async translate(req: TranslationRequest): Promise<TranslationResult> {
    if (this.appid.length === 0 || this.secret.length === 0) {
      throw new TranslateError(this.id, 1001, '请先在设置中配置百度翻译 AppID 与密钥');
    }
    const from = req.from === AUTO_DETECT ? 'auto' : baiduCode(req.from);
    const to = baiduCode(req.to);
    const salt = Math.floor(Math.random() * 1000000000).toString();
    const sign = await md5Hex(this.appid + req.text + salt + this.secret);

    // 官方要求 POST（form-urlencoded）；q 必须参与签名且与请求体一致
    const body = 'q=' + encodeURIComponent(req.text)
      + '&from=' + from
      + '&to=' + to
      + '&appid=' + this.appid
      + '&salt=' + salt
      + '&sign=' + sign;

    const resp = await postJson({
      url: 'https://fanyi-api.baidu.com/api/trans/vip/translate',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body
    });

    const root = safeParse(resp.body);
    if (root === null) {
      throw new TranslateError(this.id, 1002, '百度翻译响应解析失败: ' + truncate(resp.body, 120));
    }
    const errCode = getStr(root, 'error_code');
    if (errCode.length > 0) {
      throw new TranslateError(this.id, Number(errCode),
        '百度翻译错误 ' + errCode + ': ' + getStr(root, 'error_msg'));
    }
    const list = getArr(root, 'trans_result');
    if (list.length === 0) {
      throw new TranslateError(this.id, 1003, '百度翻译无结果');
    }
    // 多行文本时逐条拼接（按 \n 分段是官方建议的处理方式）
    const parts: string[] = [];
    for (const item of list) {
      parts.push(getStr(item, 'dst'));
    }
    const src0 = getStr(list[0], 'src');
    const result: TranslationResult = {
      text: parts.join('\n'),
      providerId: this.id
    };
    if (req.from === AUTO_DETECT) {
      const fromField = getStr(root, 'from');
      result.detectedFrom = this.fromBaiduCode(fromField);
    }
    void src0;
    return result;
  }

  private fromBaiduCode(code: string): LangCode {
    const map: Record<string, string> = {
      'zh': 'zh', 'en': 'en', 'jp': 'ja', 'kor': 'ko', 'fra': 'fr',
      'de': 'de', 'ru': 'ru', 'spa': 'es', 'th': 'th', 'vie': 'vi'
    };
    return map[code] ?? code;
  }
}

// 保留引用避免未使用告警（getObj 供后续扩展词典字段使用）
void getObj;
