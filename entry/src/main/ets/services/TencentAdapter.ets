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
import { sha256Hex, hmacSha256Hex, hmacSha256Raw, utf8 } from '../utils/HashUtil';
import { safeParse, getStr, getObj } from '../utils/JsonUtil';
import { tencentCode } from './LangMaps';

/**
 * 腾讯云机器翻译 TMT 适配器。
 * 接口：TextTranslate（tmt.tencentcloudapi.com，版本 2018-03-21）
 * 签名：TC3-HMAC-SHA256，文档 https://cloud.tencent.com/document/api/551/15619
 * 免费额度：每月 500 万字符（以官网最新政策为准）。
 */
export class TencentAdapter implements TranslatorAdapter {
  id = 'tencent';
  label = '腾讯翻译';
  readonly isAI = false;
  readonly supportsStyle = false;
  readonly needsConfig = true;

  private secretId: string = '';
  private secretKey: string = '';

  setCredentials(secretId: string, secretKey: string): void {
    this.secretId = secretId;
    this.secretKey = secretKey;
  }

  supportedLangs(): LangCode[] {
    return CORE_LANGS;
  }

  async translate(req: TranslationRequest): Promise<TranslationResult> {
    if (this.secretId.length === 0 || this.secretKey.length === 0) {
      throw new TranslateError(this.id, 2001, '请先在设置中配置腾讯云 SecretId / SecretKey');
    }
    const from = req.from === AUTO_DETECT ? 'auto' : tencentCode(req.from);
    const to = tencentCode(req.to);
    const payload = JSON.stringify({
      SourceText: req.text,
      Source: from,
      Target: to,
      ProjectId: 0
    });

    const host = 'tmt.tencentcloudapi.com';
    const service = 'tmt';
    const version = '2018-03-21';
    // TMT 为地域性服务，X-TC-Region 必传（公共参数文档标注可选，但缺失时服务端报
    // MissingParameter 'Region'）；文本翻译在广州地域开放
    const region = 'ap-guangzhou';
    const now = new Date();
    const timestamp = Math.floor(now.getTime() / 1000);
    // TC3 规范：UTC 日期，格式 yyyy-MM-dd
    const date = now.toISOString().substring(0, 10);

    // 1. 拼接规范请求串
    const canonicalRequest = 'POST\n/\n\n'
      + 'content-type:application/json; charset=utf-8\n'
      + 'host:' + host + '\n'
      + 'x-tc-action:' + 'texttranslate'.toLowerCase() + '\n'
      + '\n'
      + 'content-type;host;x-tc-action\n'
      + await sha256Hex(payload);

    // 2. 拼接待签名串
    const stringToSign = 'TC3-HMAC-SHA256\n'
      + timestamp + '\n'
      + date + '/' + service + '/tc3_request\n'
      + await sha256Hex(canonicalRequest);

    // 3. 派生签名密钥
    const kDate = await hmacSha256Raw(utf8('TC3' + this.secretKey), date);
    const kService = await hmacSha256Raw(kDate, service);
    const kSigning = await hmacSha256Raw(kService, 'tc3_request');

    // 4. 计算签名
    const signature = await hmacSha256Hex(kSigning, stringToSign);

    const authorization = 'TC3-HMAC-SHA256 '
      + 'Credential=' + this.secretId + '/' + date + '/' + service + '/tc3_request, '
      + 'SignedHeaders=content-type;host;x-tc-action, '
      + 'Signature=' + signature;

    const resp = await postJson({
      url: 'https://' + host,
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'Host': host,
        'X-TC-Action': 'TextTranslate',
        'X-TC-Version': version,
        'X-TC-Region': region,
        'X-TC-Timestamp': timestamp.toString(),
        'Authorization': authorization
      },
      body: payload
    });

    const root = safeParse(resp.body);
    if (root === null) {
      throw new TranslateError(this.id, 2002, '腾讯翻译响应解析失败: ' + truncate(resp.body, 120));
    }
    const response = getObj(root, 'Response');
    if (response === null) {
      throw new TranslateError(this.id, 2003, '腾讯翻译响应缺少 Response 字段');
    }
    const errCode = getStr(response, 'Error.Code') === ''
      ? codeOf(response, 'Error')
      : getStr(response, 'Error.Code');
    if (errCode.length > 0) {
      const errObj = getObj(response, 'Error');
      const msg = errObj === null ? '' : getStr(errObj, 'Message');
      throw new TranslateError(this.id, 2004, '腾讯云错误 ' + errCode + ': ' + msg);
    }
    // 官方 TextTranslateResponse：TargetText=译文，Source=源语言，Target=目标语言代码
    const result: TranslationResult = {
      text: getStr(response, 'TargetText'),
      providerId: this.id
    };
    if (req.from === AUTO_DETECT) {
      const src = getStr(response, 'Source');
      result.detectedFrom = src.length > 0 ? src : undefined;
    }
    return result;
  }
}

/** 从 Response.Error 子对象取 Code（JsonUtil 的点路径不支持，单独处理） */
function codeOf(response: Record<string, Object | null>, key: string): string {
  const errObj = getObj(response, key);
  if (errObj === null) {
    return '';
  }
  return getStr(errObj, 'Code');
}
