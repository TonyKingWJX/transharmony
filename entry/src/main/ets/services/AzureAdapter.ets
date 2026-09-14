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
import { safeParse, safeParseArray, getStr, getArr, getObj } from '../utils/JsonUtil';
import { azureCode, azureFromAzure } from './LangMaps';

/**
 * Azure Translator（微软）适配器。
 * 接口：Translator v3 REST，POST {endpoint}/translate?api-version=3.0
 * 文档：https://learn.microsoft.com/azure/ai-services/translator/reference/v3-0-translate
 * 免费额度：F0 定价层每月 200 万字符（以官网最新政策为准）。
 * 认证：Ocp-Apim-Subscription-Key 请求头；区域资源需附带 Ocp-Apim-Subscription-Region。
 * 默认走全球站终结点，可按需改为区域/中国站终结点。
 */

interface AzureTranslateItem {
  /** 注意：Azure 要求首字母大写的 Text 字段 */
  Text: string;
}

export class AzureAdapter implements TranslatorAdapter {
  id = 'azure';
  label = 'Azure 翻译';
  readonly isAI = false;
  readonly supportsStyle = false;
  readonly needsConfig = true;

  private apiKey: string = '';
  private region: string = '';
  private endpoint: string = 'https://api.cognitive.microsofttranslator.com';

  setCredentials(key: string, region: string, endpoint: string): void {
    this.apiKey = key;
    this.region = region;
    if (endpoint.length > 0) {
      // 去掉末尾斜杠，统一拼接形态
      this.endpoint = endpoint.endsWith('/') ? endpoint.substring(0, endpoint.length - 1) : endpoint;
    } else {
      this.endpoint = 'https://api.cognitive.microsofttranslator.com';
    }
  }

  supportedLangs(): LangCode[] {
    return CORE_LANGS;
  }

  async translate(req: TranslationRequest): Promise<TranslationResult> {
    if (this.apiKey.length === 0) {
      throw new TranslateError(this.id, 2101, '请先在设置中配置 Azure 订阅密钥');
    }

    let url = this.endpoint + '/translate?api-version=3.0&to=' + azureCode(req.to);
    if (req.from !== AUTO_DETECT) {
      url += '&from=' + azureCode(req.from);
    }

    const headers: Record<string, string> = {
      'Ocp-Apim-Subscription-Key': this.apiKey,
      'Content-Type': 'application/json; charset=UTF-8'
    };
    if (this.region.length > 0) {
      headers['Ocp-Apim-Subscription-Region'] = this.region;
    }

    const body = JSON.stringify([{ Text: req.text } as AzureTranslateItem]);

    const resp = await postJson({
      url: url,
      headers: headers,
      body: body,
      timeoutMs: 15000
    });

    // 错误响应是对象：{"error":{"code":401000,"message":"..."}}
    const errRoot = safeParse(resp.body);
    if (errRoot !== null) {
      const errObj = getObj(errRoot, 'error');
      if (errObj !== null) {
        throw new TranslateError(this.id, 2102,
          'Azure 错误 ' + getStr(errObj, 'code') + ': ' + getStr(errObj, 'message'));
      }
    }

    // 成功响应是顶层数组：[{"detectedLanguage":{"language":"zh-Hans"},"translations":[{"text":"...","to":"en"}]}]
    const items = safeParseArray(resp.body);
    if (items.length === 0) {
      throw new TranslateError(this.id, 2103, 'Azure 无返回结果: ' + truncate(resp.body, 120));
    }
    const first = items[0];
    const translations = getArr(first, 'translations');
    if (translations.length === 0) {
      throw new TranslateError(this.id, 2104, 'Azure 响应缺少 translations 字段');
    }

    const result: TranslationResult = {
      text: getStr(translations[0], 'text'),
      providerId: this.id
    };
    const detected = getObj(first, 'detectedLanguage');
    if (detected !== null) {
      const lang = getStr(detected, 'language');
      if (lang.length > 0) {
        result.detectedFrom = azureFromAzure(lang);
      }
    }
    return result;
  }
}
