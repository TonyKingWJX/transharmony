import { TranslatorAdapter } from './TranslatorAdapter';
import {
  AUTO_DETECT,
  LangCode,
  TranslationRequest,
  TranslationResult,
  TranslateError
} from '../models/TranslationTypes';
import { getJson, postJson, truncate } from '../utils/HttpClient';
import { safeParse, safeParseArray, getStr, getArr, getObj } from '../utils/JsonUtil';
import { azureCode, azureFromAzure } from './LangMaps';

/**
 * 微软免费翻译通道（非官方接口，Path C），默认引擎。
 * 旧 edge.microsoft.com/translate/trans 端点已下线（404），现走 Bing 网页版流程：
 * 1) GET https://cn.bing.com/Translator 提取 IG / IID / token(key)（页面防滥用令牌，1 小时有效）
 * 2) POST https://cn.bing.com/ttranslatev3?isVertical=1&&IG=<ig>&IID=<iid>
 *    表单: text / fromLang('auto-detect') / to / token / key / tryFetchingGenderDebiasedTranslations
 * 响应: [{"translations":[{"text":"...","to":"zh-Hans"}],"detectedLanguage":{"language":"en"}}]
 * 语言代码与 Azure 一致（zh-Hans）。限制：单次 1000 字符（网页版上限）。
 * 定位：默认免费兜底引擎，开箱即翻；⚠️ 非公开契约接口，token 机制可能变化。
 */

interface BingToken {
  ig: string;
  iid: string;
  key: string;
  token: string;
}

const TOKEN_TTL_MS = 30 * 60 * 1000;

export class EdgeTranslatorAdapter implements TranslatorAdapter {
  readonly id = 'edge';
  readonly label = '微软翻译';
  readonly isAI = false;
  readonly supportsStyle = false;
  readonly needsConfig = false;

  private readonly hostUrl = 'https://cn.bing.com/Translator';
  private readonly apiHost = 'https://cn.bing.com/ttranslatev3';
  private readonly inputLimit = 1000;
  private cachedToken: BingToken | null = null;
  private tokenFetchedAt: number = 0;

  supportedLangs(): LangCode[] {
    return ['zh', 'en', 'ja', 'ko', 'fr', 'de', 'ru', 'es', 'th', 'vi'];
  }

  async translate(req: TranslationRequest): Promise<TranslationResult> {
    if (req.text.length > this.inputLimit) {
      throw new TranslateError(this.id, 2501,
        '微软免费通道单次最多 ' + this.inputLimit + ' 字符，请缩短文本或改用其他引擎');
    }
    try {
      return await this.doTranslate(req, await this.ensureToken(false));
    } catch (firstErr) {
      // token 失效（400/401）时刷新一次再重试；其他错误直接抛出
      if (firstErr instanceof TranslateError && firstErr.code === 2502) {
        this.cachedToken = null;
        return await this.doTranslate(req, await this.ensureToken(true));
      }
      throw firstErr instanceof Error ? firstErr : new Error(String(firstErr));
    }
  }

  private async doTranslate(req: TranslationRequest, tk: BingToken): Promise<TranslationResult> {
    const from = req.from === AUTO_DETECT ? 'auto-detect' : azureCode(req.from);
    const body = 'text=' + encodeURIComponent(req.text)
      + '&fromLang=' + encodeURIComponent(from)
      + '&to=' + encodeURIComponent(azureCode(req.to))
      + '&tryFetchingGenderDebiasedTranslations=true'
      + '&key=' + encodeURIComponent(tk.key)
      + '&token=' + encodeURIComponent(tk.token);

    const headers: Record<string, string> = {
      'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 Edg/126.0.0.0',
      'Referer': 'https://cn.bing.com/Translator'
    };

    const resp = await postJson({
      url: this.apiHost + '?isVertical=1&&IG=' + tk.ig + '&IID=' + tk.iid,
      headers: headers,
      body: body,
      timeoutMs: 15000,
      // Bing 前置 Akamai 对 h2 无 Content-Length 的 POST 回 411，强制 h1.1
      forceHttp1: true
    });

    const items = safeParseArray(resp.body);
    if (items.length === 0) {
      // {"statusCode":400} 之类：视为 token 失效，交给上层刷新重试
      const errRoot = safeParse(resp.body);
      if (errRoot !== null && getStr(errRoot, 'statusCode').length > 0) {
        throw new TranslateError(this.id, 2502, '微软翻译令牌过期');
      }
      throw new TranslateError(this.id, 2503, '微软翻译无有效返回: ' + truncate(resp.body, 120));
    }

    const first = items[0];
    const translations = getArr(first, 'translations');
    if (translations.length === 0) {
      throw new TranslateError(this.id, 2504, '微软翻译响应缺少 translations 字段');
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

  /** 抓取 Bing 翻译页并提取 IG / IID / 防滥用 token（带 30 分钟内存缓存） */
  private async ensureToken(forceRefresh: boolean): Promise<BingToken> {
    if (!forceRefresh && this.cachedToken !== null
      && Date.now() - this.tokenFetchedAt < TOKEN_TTL_MS) {
      return this.cachedToken;
    }

    const headers: Record<string, string> = {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 Edg/126.0.0.0'
    };
    const resp = await getJson({
      url: this.hostUrl,
      headers: headers,
      body: '',
      timeoutMs: 15000
    });
    const html = resp.body;

    const igMatch = html.match(/IG:"([^"]+)"/);
    const iidMatch = html.match(/data-iid="(translator\.\d+)"/);
    const tkMatch = html.match(/var params_AbusePreventionHelper = \[([^\]]+)\]/);
    if (igMatch === null || iidMatch === null || tkMatch === null) {
      throw new TranslateError(this.id, 2505, '微软翻译页面结构已变化，通道暂时不可用');
    }
    const parts = tkMatch[1].split(',');
    if (parts.length < 2) {
      throw new TranslateError(this.id, 2506, '微软翻译令牌解析失败');
    }

    this.cachedToken = {
      ig: igMatch[1],
      iid: iidMatch[1],
      key: parts[0].trim(),
      token: parts[1].replace(/"/g, '').trim()
    };
    this.tokenFetchedAt = Date.now();
    return this.cachedToken;
  }
}
