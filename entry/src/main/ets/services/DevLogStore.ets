/**
 * 开发者日志系统（开发者模式内）：
 * - 采集：插件 $log（registerLogHandler 全局回投）、插件安装/加载/卸载等关键事件；
 *   仅在「日志收集」开关开启时记录
 * - 存储：内存环形缓冲（上限 500 条）+ 沙箱 files/dev_log.jsonl 落盘（脏标记 1s 合并写，重启不丢）
 * - 查看：DevLogPage 经 AppStorage 版本号实时刷新
 * - 导出：DocumentViewPicker DOWNLOAD 模式保存为 .txt（与 BackupService 导出同规格）
 * - 联动：关闭日志收集或开发者模式时停采并清空（内存 + 落盘）
 */

import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { fileUri } from '@kit.CoreFileKit';
import { picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

/** 单条日志：时间戳 + 级别 + 来源 + 消息 */
export interface DevLogEntry {
  ts: number;
  level: string;
  tag: string;
  message: string;
}

const MAX_ENTRIES = 500;
const LOG_FILE = 'dev_log.jsonl';
/** AppStorage 版本号键：每次追加后 bump，DevLogPage 经 @StorageProp 实时刷新 */
export const DEVLOG_VERSION_KEY = 'devlog_version';
/** AppStorage 插件 $log 文本键：PluginLabPage 页内实时输出（保留原 40 行行为） */
export const PLUGIN_LOG_TEXT_KEY = 'plugin_log_text';

export class DevLogStore {
  private enabled: boolean = false;
  private buffer: DevLogEntry[] = [];
  private dirty: boolean = false;
  private flushTimer: number = -1;
  private ctx: common.Context | null = null;
  private pref: preferences.Preferences | null = null;

  /** EntryAbility 启动时初始化：读开关偏好 + 回灌落盘日志到内存 */
  async init(context: common.Context): Promise<void> {
    this.ctx = context.getApplicationContext();
    if (this.pref === null) {
      this.pref = await preferences.getPreferences(this.ctx, 'transharmony_settings');
    }
    this.enabled = (this.pref.getSync('dev_log_enabled', false) as boolean);
    this.loadFromDisk();
  }

  getEnabled(): boolean {
    return this.enabled;
  }

  /** 开关日志收集：关闭时停采并清空（内存 + 落盘） */
  async setEnabled(v: boolean): Promise<void> {
    this.enabled = v;
    if (this.pref !== null) {
      await this.pref.put('dev_log_enabled', v);
      await this.pref.flush();
    }
    if (!v) {
      this.wipe();
    }
  }

  /** 关闭开发者模式联动：停采 + 清空（内存 + 落盘），开关回默认关闭 */
  async disable(): Promise<void> {
    await this.setEnabled(false);
  }

  /** 采集一条：未开启时忽略；追加后 bump AppStorage 版本号并安排落盘 */
  append(level: string, tag: string, message: string): void {
    if (!this.enabled || !this.ctx) {
      return;
    }
    this.buffer.push({ ts: Date.now(), level: level, tag: tag, message: message });
    if (this.buffer.length > MAX_ENTRIES) {
      this.buffer = this.buffer.slice(-MAX_ENTRIES);
    }
    AppStorage.setOrCreate(DEVLOG_VERSION_KEY, Date.now());
    this.scheduleFlush();
  }

  /** 当前缓冲快照（查看页渲染用） */
  entries(): DevLogEntry[] {
    return this.buffer;
  }

  /** 清空（日志页手动清空按钮）：内存 + 落盘 */
  clear(): void {
    this.wipe();
  }

  /** 导出：DOWNLOAD 模式保存 .txt，返回文件名（用户取消返回 ''） */
  async exportLog(ctx: common.UIAbilityContext): Promise<string> {
    const text = this.toText();
    if (text.length === 0) {
      return '';
    }
    const saveOpts = new picker.DocumentSaveOptions();
    saveOpts.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
    const dvp = new picker.DocumentViewPicker(ctx);
    const uris = await dvp.save(saveOpts);
    if (uris === undefined || uris.length === 0) {
      return '';
    }
    const fileName = 'transharmony_dev_log_' + this.stamp() + '.txt';
    const filePath = new fileUri.FileUri(uris[0] + '/' + fileName).path;
    const file = fs.openSync(filePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, text);
    } finally {
      fs.closeSync(file);
    }
    return fileName;
  }

  // ---- 内部 ----

  private wipe(): void {
    this.buffer = [];
    this.dirty = false;
    AppStorage.setOrCreate(DEVLOG_VERSION_KEY, Date.now());
    AppStorage.setOrCreate(PLUGIN_LOG_TEXT_KEY, '');
    if (!this.ctx) {
      return;
    }
    try {
      fs.unlinkSync(this.filePath());
    } catch (e) {
      // 文件不存在等场景忽略
    }
  }

  private filePath(): string {
    return this.ctx!.filesDir + '/' + LOG_FILE;
  }

  /** 脏标记 1s 合并写：流式 $log 不逐条写盘 */
  private scheduleFlush(): void {
    this.dirty = true;
    if (this.flushTimer >= 0) {
      return;
    }
    this.flushTimer = setTimeout((): void => {
      this.flushTimer = -1;
      this.flushNow();
    }, 1000);
  }

  /** 立即落盘（崩溃回调、退后台时调用：不等 1s 合并写，防日志随进程丢失） */
  flush(): void {
    this.flushNow();
  }

  private flushNow(): void {
    if (!this.dirty || !this.ctx) {
      return;
    }
    this.dirty = false;
    try {
      const file = fs.openSync(this.filePath(), fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, this.buffer.map((e: DevLogEntry): string => JSON.stringify(e)).join('\n'));
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      // 落盘失败不影响采集
    }
  }

  /** 启动回灌：从沙箱文件恢复历史日志 */
  private loadFromDisk(): void {
    try {
      if (!fs.accessSync(this.filePath())) {
        return;
      }
      const file = fs.openSync(this.filePath(), fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(file.fd);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      const text = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buf));
      const lines = text.split('\n');
      const out: DevLogEntry[] = [];
      for (const line of lines) {
        if (line.trim().length === 0) {
          continue;
        }
        try {
          const o = JSON.parse(line) as Record<string, Object>;
          out.push({
            ts: typeof o['ts'] === 'number' ? o['ts'] as number : 0,
            level: typeof o['level'] === 'string' ? o['level'] as string : 'info',
            tag: typeof o['tag'] === 'string' ? o['tag'] as string : '',
            message: typeof o['message'] === 'string' ? o['message'] as string : ''
          });
        } catch (e) {
          // 跳过损坏行
        }
      }
      this.buffer = out.slice(-MAX_ENTRIES);
    } catch (e) {
      // 文件损坏等场景忽略，从空开始
    }
  }

  /** 时间戳 → yyyyMMdd-HHmmss（导出文件名用） */
  private stamp(): string {
    const d = new Date();
    const p = (n: number, w: number): string => String(n).padStart(w, '0');
    return d.getFullYear() + p(d.getMonth() + 1, 2) + p(d.getDate(), 2) + '-' + p(d.getHours(), 2) + p(d.getMinutes(), 2) + p(d.getSeconds(), 2);
  }

  /** 导出/查看共用文本 */
  private toText(): string {
    return this.buffer.map((e: DevLogEntry): string => {
      const d = new Date(e.ts);
      const p = (n: number, w: number): string => String(n).padStart(w, '0');
      return d.getFullYear() + '-' + p(d.getMonth() + 1, 2) + '-' + p(d.getDate(), 2) + ' ' +
        p(d.getHours(), 2) + ':' + p(d.getMinutes(), 2) + ':' + p(d.getSeconds(), 2) + '.' + p(d.getMilliseconds(), 3) +
        ' [' + e.level + '] [' + e.tag + '] ' + e.message;
    }).join('\n');
  }
}

export const devLogStore = new DevLogStore();
