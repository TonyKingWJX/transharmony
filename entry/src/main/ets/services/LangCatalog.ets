/**
 * 扩展语言注册表：插件声明但应用未内置的语言（粤语/文言文等）在此登记，
 * 语言选择器据此动态扩展。仅保留能给出正式中文名的语言（KNOWN_EXTRA_LABELS
 * 或系统 ICU 可译），识别不了的冷门码不展示，防止插件声明上百种语言撑爆选择器。
 * 发布方式：扩展语言码数组 JSON 写入 AppStorage（@StorageProp 订阅刷新）。
 */

import { LangCode, langLabel } from '../models/TranslationTypes';

/** AppStorage 键：扩展语言码数组 JSON，LangSelector / TranslatePage 以 @StorageProp 订阅 */
export const EXT_LANGS_KEY = 'ext_langs_json';

/** 解析 AppStorage 中的扩展语言 JSON（非法/为空返回空数组） */
export function parseExtLangs(json: string): LangCode[] {
  try {
    const arr = JSON.parse(json) as LangCode[];
    return Array.isArray(arr) ? arr : [];
  } catch (e) {
    return [];
  }
}

class LangCatalog {
  /** sourceId（如 'bob:<pluginId>' / 'manggo:<pluginId>'）→ 该源声明的扩展语言码 */
  private sources: Map<string, LangCode[]> = new Map();

  registerSource(sourceId: string, codes: LangCode[]): void {
    const filtered = this.filterKnown(codes);
    const prev = this.sources.get(sourceId);
    if (prev !== undefined && prev.length === filtered.length
      && prev.every((c: LangCode, i: number): boolean => c === filtered[i])) {
      return; // 无变化不触发 UI 刷新
    }
    this.sources.set(sourceId, filtered);
    this.publish();
  }

  unregisterSource(sourceId: string): void {
    if (this.sources.delete(sourceId)) {
      this.publish();
    }
  }

  /** 注销某前缀下已失效的源（插件删除/服务全关后清理残留） */
  prunePrefix(prefix: string, keepIds: Set<string>): void {
    let changed = false;
    for (const sourceId of Array.from(this.sources.keys())) {
      if (sourceId.startsWith(prefix) && !keepIds.has(sourceId)) {
        this.sources.delete(sourceId);
        changed = true;
      }
    }
    if (changed) {
      this.publish();
    }
  }

  /** 插件扩展语言并集（去重，按注册先后排序；均不在内置 LANGUAGE_LIST 中） */
  extendedLangs(): LangCode[] {
    const out: LangCode[] = [];
    for (const codes of this.sources.values()) {
      for (const c of codes) {
        if (!out.includes(c)) {
          out.push(c);
        }
      }
    }
    return out;
  }

  /** 仅保留能解析出正式中文名的语言码（langLabel 识别不了时返回原码） */
  private filterKnown(codes: LangCode[]): LangCode[] {
    const out: LangCode[] = [];
    for (const c of codes) {
      if (langLabel(c) !== c && !out.includes(c)) {
        out.push(c);
      }
    }
    return out;
  }

  private publish(): void {
    try {
      AppStorage.setOrCreate(EXT_LANGS_KEY, JSON.stringify(this.extendedLangs()));
    } catch (e) {
      // AppStorage 未就绪（极端时序）：UI 下次读取仍能拿到最新列表
    }
  }
}

export const langCatalog = new LangCatalog();
