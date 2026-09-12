import { TranslatorAdapter } from './TranslatorAdapter';
import {
  AUTO_DETECT,
  LangCode,
  TranslationRequest,
  TranslationResult,
  TranslateError
} from '../models/TranslationTypes';
import { postJson, truncate } from '../utils/HttpClient';
import { safeParse, getObj, getStr, getNum } from '../utils/JsonUtil';
import { hmacSha1Base64, utf8 } from '../utils/HashUtil';

/**
 * 阿里云机器翻译（alimt）适配器——官方 API，非网页逆向。
 * 接口：TranslateGeneral（通用版），端点 mt.aliyuncs.com，版本 2018-10-12
 * 文档：https://help.aliyun.com/document_detail/1971341.html
 * 免费额度：通用版每月 100 万字符（以官网最新政策为准）；需开通机器翻译服务并创建 AccessKey。
 * 签名：阿里云 RPC V1.0——HMAC-SHA1(AccessKeySecret + '&', StringToSign) 后 Base64。
 * 语言代码与内部枚举一致（zh/en/ja/ko/...），SourceLanguage 支持 auto 自动检测。
 */

/** RFC3986 百分号编码（阿里云签名规范：+ → %20、* → %2A、~ 不编码） */
function pctEncode(s: string): string {
  return encodeURIComponent(s)
    .replace(/\+/g, '%20')
    .replace(/\*/g, '%2A')
    .replace(/%7E/g, '~');
}

function randomHex(len: number): string {
  let s = '';
  for (let i = 0; i < len; i++) {
    s += Math.floor(Math.random() * 16).toString(16);
  }
  return s;
}

export class AliyunAdapter implements TranslatorAdapter {
  id = 'aliyun';
  label = '阿里云翻译';
  readonly isAI = false;
  readonly supportsStyle = false;
  readonly needsConfig = true;

  private readonly endpoint = 'https://mt.aliyuncs.com/';
  private accessKeyId: string = '';
  private accessKeySecret: string = '';

  setCredentials(keyId: string, keySecret: string): void {
    this.accessKeyId = keyId;
    this.accessKeySecret = keySecret;
  }

  supportedLangs(): LangCode[] {
    return ['zh', 'en', 'ja', 'ko', 'fr', 'de', 'ru', 'es', 'th', 'vi'];
  }

  async translate(req: TranslationRequest): Promise<TranslationResult> {
    if (this.accessKeyId.length === 0 || this.accessKeySecret.length === 0) {
      throw new TranslateError(this.id, 2601, '请先在设置中配置阿里云 AccessKey');
    }

    // 业务参数 + 公共参数，按 key 字典序排列后拼签名串
    // FormatType 为官方必填（text=纯文本），缺失会报参数错误
    const params: Record<string, string> = {
      'AccessKeyId': this.accessKeyId,
      'Action': 'TranslateGeneral',
      'Format': 'JSON',
      'FormatType': 'text',
      'Scene': 'general',
      'SignatureMethod': 'HMAC-SHA1',
      'SignatureNonce': Date.now().toString(16) + randomHex(12),
      'SignatureVersion': '1.0',
      'SourceLanguage': req.from === AUTO_DETECT ? 'auto' : req.from,
      'SourceText': req.text,
      'TargetLanguage': req.to,
      'Timestamp': new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
      'Version': '2018-10-12'
    };
    const keys = Object.keys(params).sort();
    const canonical: string[] = [];
    for (const k of keys) {
      canonical.push(pctEncode(k) + '=' + pctEncode(params[k]));
    }
    const stringToSign = 'POST&' + pctEncode('/') + '&' + pctEncode(canonical.join('&'));
    const signature = await hmacSha1Base64(utf8(this.accessKeySecret + '&'), stringToSign);
    const body = canonical.join('&') + '&Signature=' + pctEncode(signature);

    const headers: Record<string, string> = {
      'Content-Type': 'application/x-www-form-urlencoded'
    };

    const resp = await postJson({
      url: this.endpoint,
      headers: headers,
      body: body,
      timeoutMs: 15000
    });

    const root = safeParse(resp.body);
    if (root === null) {
      throw new TranslateError(this.id, 2602, '阿里云翻译无有效返回: ' + truncate(resp.body, 160));
    }
    // 成功响应：{"Code":200,"Message":"success","Data":{...}}——Code 是数字 200（成功），
    // 仅当为非 200 的错误码（字符串如 "InvalidParameterValue" 或数字）时才算失败
    const codeNum = getNum(root, 'Code');
    const codeStr = getStr(root, 'Code');
    if (codeNum !== 200 && codeStr !== '' && codeStr !== '200') {
      throw new TranslateError(this.id, 2603,
        '阿里云错误 ' + codeStr + ': ' + getStr(root, 'Message') + '（免费额度每月 100 万字符，请检查凭证与额度）');
    }
    const data = getObj(root, 'Data');
    if (data === null) {
      throw new TranslateError(this.id, 2604, '阿里云翻译响应缺少 Data 字段: ' + truncate(resp.body, 160));
    }
    // 官方响应字段为大驼峰（SDK names() 映射确认）：Data.Translated / Data.DetectedLanguage
    const result: TranslationResult = {
      text: getStr(data, 'Translated'),
      providerId: this.id
    };
    // SourceLanguage 传 auto 时响应会回带检测语言
    const detected = getStr(data, 'DetectedLanguage');
    if (detected.length > 0) {
      result.detectedFrom = detected;
    }
    return result;
  }
}
