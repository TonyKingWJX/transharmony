import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 全局敏感词检测（DFA 字典树）：
 * 词库来自 rawfile/sensitive_words.json（按类别分组），命中「硬拦截类」即拒译——
 * 不发网络请求、不写历史，UI 展示中性提示且不回显命中词。
 * 匹配前先归一化（全角→半角、去空白与零宽字符、转小写），防简单绕过。
 * 词库懒加载：首次翻译时构建字典树，构建失败按「词库不可用=放行」处理（不阻断主流程）。
 */

/** 单词库条目 */
interface WordEntry {
  /** 归一化后的命中词 */
  word: string;
  /** 类别：leader / security / separatism / terrorism */
  category: string;
}

/** 词库 JSON 反序列化载体（ArkTS 显式接口） */
interface Wordlist {
  version: number;
  categories: Record<string, string[]>;
}

/** 检测结果：命中词与类别（词仅用于本地日志，不回显到界面） */
export interface SensitiveHit {
  word: string;
  category: string;
}

/** 拒译统一文案（各页面错误栏直接展示） */
export const SENSITIVE_BLOCK_MSG = '内容包含受限词汇，无法提供翻译';

/** 字典树叶子标记：node.get(LEAF) 非空即命中，值为类别 */
const LEAF = '\u0000';

class SensitiveFilter {
  /** 字典树节点：key=下一字符，value=子节点 Map；叶子以 LEAF 键标记 */
  private root: Map<string, Object> | null = null;
  /** 词库条数（诊断用） */
  wordCount: number = 0;
  private loading: Promise<void> | null = null;

  /** 懒加载词库并构建字典树（幂等；并发调用共享同一次加载） */
  ensureLoaded(ctx: common.Context): void {
    if (this.root !== null || this.loading !== null) {
      return;
    }
    this.loading = this.build(ctx).then((): void => {
      this.loading = null;
    }).catch((): void => {
      // 构建失败按无词库处理：放行 + 允许下次重试
      this.root = null;
      this.loading = null;
    });
  }

  private async build(ctx: common.Context): Promise<void> {
    const raw = await ctx.resourceManager.getRawFileContent('sensitive_words.json');
    const decoder = util.TextDecoder.create('utf-8');
    const text = decoder.decodeToString(raw);
    const parsed = JSON.parse(text) as Wordlist;
    const list: WordEntry[] = [];
    for (const cat of Object.keys(parsed.categories)) {
      for (const w of parsed.categories[cat]) {
        const norm = SensitiveFilter.normalize(w);
        if (norm.length > 0) {
          list.push({ word: norm, category: cat });
        }
      }
    }
    const root: Map<string, Object> = new Map();
    for (const it of list) {
      let node: Map<string, Object> = root;
      for (let i = 0; i < it.word.length; i++) {
        const ch = it.word.charAt(i);
        const next: Object | undefined = node.get(ch);
        if (next === undefined || !(next instanceof Map)) {
          const fresh: Map<string, Object> = new Map();
          node.set(ch, fresh);
          node = fresh;
        } else {
          node = next as Map<string, Object>;
        }
      }
      // 整词消费完才在终点节点打命中标记。
      // 此前版本在"还差最后一个字符"的节点上标记，导致两字词（藏独/台独/东突…）
      // 退化为单字命中、长词命中去尾前缀，说明书里的"贮藏"都会误拦。
      node.set(LEAF, it.category);
    }
    this.wordCount = list.length;
    this.root = root;
  }

  /** 归一化：全角→半角、剔零宽与空白、转小写 */
  static normalize(s: string): string {
    let out = '';
    for (const ch of s) {
      const code = ch.codePointAt(0) ?? 0;
      let c = ch;
      if (code === 0x3000) {
        c = ' '; // 全角空格
      } else if (code >= 0xff01 && code <= 0xff5e) {
        c = String.fromCharCode(code - 0xfee0); // 全角 ASCII → 半角
      }
      if (c === ' ') {
        continue;
      }
      const cc = c.codePointAt(0) ?? 0;
      if (cc <= 0x20 || (cc >= 0x200b && cc <= 0x200f) || cc === 0xfeff
        || (cc >= 0x202a && cc <= 0x202e) || cc === 0x2060) {
        continue; // 控制字符 / 零宽字符
      }
      out += c.toLowerCase();
    }
    return out;
  }

  /** 是否命中硬拦截词（命中返回词与类别，未命中返回 null）。词库未就绪时放行 */
  check(text: string): SensitiveHit | null {
    const root = this.root;
    if (root === null || text.length === 0) {
      return null;
    }
    const norm = SensitiveFilter.normalize(text);
    for (let i = 0; i < norm.length; i++) {
      let node: Object | undefined = root.get(norm.charAt(i));
      let j = i + 1;
      while (node !== undefined && node instanceof Map) {
        const cur = node as Map<string, Object>;
        const hit: Object | undefined = cur.get(LEAF);
        if (hit !== undefined) {
          return { word: norm.substring(i, j), category: hit as string };
        }
        if (j >= norm.length) {
          break;
        }
        node = cur.get(norm.charAt(j));
        j++;
      }
    }
    return null;
  }

  /** 检测 + 拒译抛错（UseCase 各入口统一调用；词库未就绪时等待构建完成再检测） */
  async guard(text: string, ctx?: common.Context): Promise<void> {
    if (ctx !== undefined) {
      this.ensureLoaded(ctx);
    }
    // 首次翻译时词库可能仍在后台构建：等待本次构建完成，避免首翻漏检
    if (this.root === null && this.loading !== null) {
      await this.loading;
    }
    const hit = this.check(text);
    if (hit !== null) {
      // 本地调试日志：记录命中的词与类别，便于排查误拦（不回显到界面、不上传）
      hilog.info(0x0001, 'SensitiveFilter', '命中敏感词 %{public}s 类别 %{public}s',
        hit.word, hit.category);
      throw new Error(SENSITIVE_BLOCK_MSG);
    }
  }
}

export const sensitiveFilter = new SensitiveFilter();
