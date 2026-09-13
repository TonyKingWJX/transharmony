import pluginHost from 'libpluginhost.so';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TranslatorAdapter } from '../TranslatorAdapter';
import {
  LangCode,
  TranslationRequest,
  TranslationResult,
  TranslateError
} from '../../models/TranslationTypes';
import { bobPluginEngine, toBobLang, fromBobLang } from './BobPluginEngine';

/**
 * Bob 翻译插件适配器：把沙盒里的标准 Bob 翻译插件（supportLanguages + translate(query, completion)）
 * 包装成应用统一的 TranslatorAdapter，引擎行/聚合/历史零改动接入。
 *
 * 调用约定：
 *  - query 按官方字段传 text/from/to（Bob 码），另附 detectFrom/detectTo（官方约定非 auto；
 *    应用不做语言检测，auto 时以目标语言兜底，多数免费插件不依赖该字段）；
 *  - 结果 {result:{toParagraphs}} → 段落以换行拼接；{error:{message}} → TranslateError；
 *  - 超时 30s（插件默认 60s 上限，此处取体验优先）。
 */
export class BobPluginAdapter implements TranslatorAdapter {
  readonly pluginId: string;
  id: string;
  label: string;
  isAI: boolean = false;
  supportsStyle: boolean = false;
  needsConfig: boolean = true;

  /** 插件超时（毫秒） */
  private static readonly TIMEOUT_MS: number = 30000;
  /** 错误码段：插件类 2900-2999 */
  private static readonly ERR_PLUGIN = 2900;
  private static readonly ERR_HOST = 2901;

  constructor(serviceId: string, pluginId: string, label: string) {
    this.id = serviceId;
    this.pluginId = pluginId;
    this.label = label;
  }

  async translate(req: TranslationRequest): Promise<TranslationResult> {
    hilog.info(0x0001, 'BobPluginAdapter', 'translate enter plugin=%{public}s textLen=%{public}d %{public}s->%{public}s',
      this.pluginId, req.text.length, req.from, req.to);
    try {
      await bobPluginEngine.ensureLoaded(this.pluginId);
    } catch (e) {
      // 加载失败必须透传真实原因（如 require 缺模块），否则被聚合兜底文案掩盖
      const loadMsg = e instanceof Error ? e.message : String(e);
      hilog.error(0x0001, 'BobPluginAdapter', 'ensureLoaded failed: %{public}s', loadMsg);
      throw new TranslateError(this.id, BobPluginAdapter.ERR_HOST, '插件加载失败: ' + loadMsg);
    }
    hilog.info(0x0001, 'BobPluginAdapter', 'ensureLoaded ok');

    const from = toBobLang(req.from);
    const to = toBobLang(req.to);
    // Bob 官方约定 detectFrom/detectTo 非 auto（宿主做语言检测后传入）。
    // 应用无检测器，auto 时用轻量书写系统嗅探兜底（回退目标语言会产生 xx2xx 的错误翻译方向）。
    const detectFrom = req.from !== 'auto' ? from : BobPluginAdapter.sniffLang(req.text);
    const detectTo = req.to !== 'auto' ? to : BobPluginAdapter.sniffLang(req.text);
    const query: Record<string, string> = {
      'text': req.text,
      'from': from,
      'to': to,
      'detectFrom': detectFrom,
      'detectTo': detectTo
    };

    let raw: string;
    try {
      raw = await pluginHost.callPluginFn(this.pluginId, 'translate',
        JSON.stringify([query]), 'callback', BobPluginAdapter.TIMEOUT_MS);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      hilog.error(0x0001, 'BobPluginAdapter', 'callPluginFn failed: %{public}s', msg);
      throw new TranslateError(this.id, BobPluginAdapter.ERR_HOST, '插件调用失败: ' + msg);
    }
    hilog.info(0x0001, 'BobPluginAdapter', 'callPluginFn ok len=%{public}d', raw.length);

    let parsed: Record<string, Object>;
    try {
      parsed = JSON.parse(raw) as Record<string, Object>;
    } catch (e) {
      throw new TranslateError(this.id, BobPluginAdapter.ERR_HOST, '插件返回了无法解析的结果');
    }

    const errObj = parsed['error'];
    if (errObj !== undefined && errObj !== null) {
      const err = errObj as Record<string, Object>;
      const msg = typeof err['message'] === 'string' ? err['message'] as string : '插件返回错误';
      throw new TranslateError(this.id, BobPluginAdapter.ERR_PLUGIN, msg);
    }

    const resultObj = parsed['result'];
    if (resultObj === undefined || resultObj === null) {
      throw new TranslateError(this.id, BobPluginAdapter.ERR_PLUGIN, '插件未返回结果');
    }
    const result = resultObj as Record<string, Object>;

    // toParagraphs 与 toDict 二选一必填（Bob 官方约定）。段落只收字符串项：
    // 有道查词等插件会往 toParagraphs 塞对象数组（展示层用 toDict），此处丢弃对象项。
    const paras: string[] = [];
    const rawParas = result['toParagraphs'];
    if (Array.isArray(rawParas)) {
      const items = rawParas as Array<Object>;
      for (const p of items) {
        if (typeof p === 'string') {
          paras.push(p as string);
        }
      }
    }

    // 无可用段落时回退 toDict：按词典结构拼可读文本（词头/音标/词性释义/变形/附注）
    if (paras.length === 0) {
      const rawDict = result['toDict'];
      if (rawDict !== undefined && rawDict !== null) {
        const dict = rawDict as Record<string, Object>;
        const lines: string[] = [];
        const word = dict['word'];
        if (typeof word === 'string' && (word as string).length > 0) {
          lines.push(word as string);
        }
        const rawPhonetics = dict['phonetics'];
        if (Array.isArray(rawPhonetics)) {
          const ph: string[] = [];
          for (const p of rawPhonetics as Array<Object>) {
            const po = p as Record<string, Object>;
            const val = typeof po['value'] === 'string' ? po['value'] as string : '';
            if (val.length === 0) {
              continue;
            }
            const t = typeof po['type'] === 'string' ? po['type'] as string : '';
            ph.push((t === 'us' ? '美' : t === 'uk' ? '英' : '') + ' ' + val);
          }
          if (ph.length > 0) {
            lines.push(ph.join('   '));
          }
        }
        const rawParts = dict['parts'];
        if (Array.isArray(rawParts)) {
          for (const p of rawParts as Array<Object>) {
            const po = p as Record<string, Object>;
            const part = typeof po['part'] === 'string' ? po['part'] as string : '';
            const means = po['means'];
            if (Array.isArray(means)) {
              const ms: string[] = [];
              for (const m of means as Array<Object>) {
                ms.push(typeof m === 'string' ? m as string : String(m));
              }
              if (ms.length > 0) {
                lines.push((part.length > 0 ? part + ' ' : '') + ms.join('；'));
              }
            }
          }
        }
        const rawExchanges = dict['exchanges'];
        if (Array.isArray(rawExchanges)) {
          for (const e of rawExchanges as Array<Object>) {
            const eo = e as Record<string, Object>;
            const name = typeof eo['name'] === 'string' ? eo['name'] as string : '';
            const words = eo['words'];
            if (Array.isArray(words)) {
              const ws: string[] = [];
              for (const w of words as Array<Object>) {
                ws.push(typeof w === 'string' ? w as string : String(w));
              }
              if (ws.length > 0) {
                lines.push((name.length > 0 ? name + '：' : '') + ws.join('、'));
              }
            }
          }
        }
        const rawAdditions = dict['additions'];
        if (Array.isArray(rawAdditions)) {
          for (const a of rawAdditions as Array<Object>) {
            const ao = a as Record<string, Object>;
            const name = typeof ao['name'] === 'string' ? ao['name'] as string : '';
            const value = typeof ao['value'] === 'string' ? ao['value'] as string : '';
            if (name.length > 0 && value.length > 0) {
              lines.push(name + '：' + value);
            }
          }
        }
        if (lines.length > 0) {
          paras.push(lines.join('\n'));
        }
      }
    }

    if (paras.length === 0) {
      throw new TranslateError(this.id, BobPluginAdapter.ERR_PLUGIN, '插件未返回结果');
    }

    let detected: LangCode | undefined = undefined;
    const fromRaw = result['from'];
    if (typeof fromRaw === 'string' && fromRaw !== 'auto') {
      detected = fromBobLang(fromRaw);
    }

    const out: TranslationResult = {
      text: paras.join('\n'),
      providerId: this.id,
      detectedFrom: detected
    };
    return out;
  }

  /** 书写系统嗅探（Bob 码）：日文假名/韩文谚文/汉字/西里尔 → 对应语言，其余按拉丁 */
  private static sniffLang(text: string): string {
    if (/[\u3040-\u30ff]/.test(text)) {
      return 'ja';
    }
    if (/[\uac00-\ud7af]/.test(text)) {
      return 'ko';
    }
    if (/[\u4e00-\u9fff]/.test(text)) {
      return 'zh-Hans';
    }
    if (/[\u0400-\u04ff]/.test(text)) {
      return 'ru';
    }
    return 'en';
  }

  supportedLangs(): LangCode[] {
    return bobPluginEngine.langsOf(this.pluginId);
  }

  /** 流式翻译：query.onStream 的 result（{toParagraphs}）逐段回传累积文本 */
  async translateStream(req: TranslationRequest, onDelta: (fullText: string) => void): Promise<TranslationResult> {
    const listener = (resultJson: string): void => {
      try {
        const parsed = JSON.parse(resultJson) as Record<string, Object>;
        const raw = parsed['toParagraphs'];
        if (Array.isArray(raw)) {
          const paras: string[] = [];
          for (const p of raw as Array<Object>) {
            paras.push(typeof p === 'string' ? p as string : String(p));
          }
          if (paras.length > 0) {
            onDelta(paras.join('\n'));
          }
        }
      } catch (e) {
        // 流式增量解析失败忽略，等最终结果
      }
    };
    bobPluginEngine.setStreamListener(this.pluginId, listener);
    try {
      return await this.translate(req);
    } finally {
      bobPluginEngine.clearStreamListener(this.pluginId, listener);
    }
  }
}
