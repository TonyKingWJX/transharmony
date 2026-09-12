import { TranslatorAdapter } from './TranslatorAdapter';
import {
  LangCode,
  TranslationRequest,
  TranslationResult,
  TranslateError
} from '../models/TranslationTypes';
import { postJson, truncate } from '../utils/HttpClient';
import { safeParse, getStr, getStrArr } from '../utils/JsonUtil';

/**
 * 阿里翻译免费通道（非官方接口，Path C）。
 * 阿里翻译网页版（translate.alibaba.com）使用的端点，无需签名：
 * POST https://translate.alibaba.com/translationopenseviceapp/trans/TranslateTextAddAlignment.do
 *      ?dmtrack_pageid=<自生成的 42 位追踪 ID>
 * 表单: srcLanguage / tgtLanguage / srcText / bizType / viewType / source
 * 响应: {"listTargetText":["译文"], "success":true}（响应无检测语言信息）
 * dmtrack_pageid 生成规则来自网页端脚本：16 位 hex + 时间戳 hex + 随机 hex，共 42 位。
 * 定位：免费兜底引擎之一；⚠️ 非公开契约接口，参数可能随页面调整。
 */
export class AlibabaAdapter implements TranslatorAdapter {
  readonly id = 'alibaba';
  readonly label = '阿里翻译';
  readonly isAI = false;
  readonly supportsStyle = false;
  readonly needsConfig = false;

  private readonly endpoint =
    'https://translate.alibaba.com/translationopenseviceapp/trans/TranslateTextAddAlignment.do';

  supportedLangs(): LangCode[] {
    return ['zh', 'en', 'ja', 'ko', 'fr', 'de', 'ru', 'es', 'th', 'vi'];
  }

  async translate(req: TranslationRequest): Promise<TranslationResult> {
    const body = 'srcLanguage=' + encodeURIComponent(req.from)
      + '&tgtLanguage=' + encodeURIComponent(req.to)
      + '&srcText=' + encodeURIComponent(req.text)
      + '&bizType=message&viewType=&source=';

    const headers: Record<string, string> = {
      'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
      'Referer': 'https://translate.alibaba.com/'
    };

    const resp = await postJson({
      url: this.endpoint + '?dmtrack_pageid=' + AlibabaAdapter.genPageId(),
      headers: headers,
      body: body,
      timeoutMs: 15000
    });

    const root = safeParse(resp.body);
    if (root === null) {
      throw new TranslateError(this.id, 2401, '阿里翻译无有效返回: ' + truncate(resp.body, 120));
    }
    const targets = getStrArr(root, 'listTargetText');
    if (targets.length === 0) {
      throw new TranslateError(this.id, 2402, '阿里翻译响应缺少 listTargetText 字段');
    }

    const result: TranslationResult = {
      text: targets[0],
      providerId: this.id
    };
    // 该接口不返回检测语言信息，detectedFrom 留空
    return result;
  }

  /** 按网页端规则生成 42 位 dmtrack_pageid：16 位 hex + 时间戳 hex + 随机 hex */
  private static genPageId(): string {
    let e = '';
    for (let i = 0; i < 16; i++) {
      e += Math.floor(Math.random() * 16).toString(16);
    }
    let o = e + Math.floor(Date.now() / 1000).toString(16);
    for (let i = 1; i < 10; i++) {
      o += Math.floor(Math.random() * 0x100000).toString(16);
    }
    return o.substring(0, 42);
  }
}
