import { media } from '@kit.MediaKit';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import pluginHost from 'libpluginhost.so';
import { bobPluginEngine, toBobLang } from './BobPluginEngine';
import { devLogStore } from '../DevLogStore';
import {
  manggoEntryGlobalName,
  parseManggoServices,
  applyManggoLangMap,
  toManggoLang,
  splitServiceRef
} from './ManggoTypes';

/**
 * 插件 TTS 播放（语音服务插件执行层）：
 *  - Bob：调用插件 tts(query, completion) → Bob tts result {type:'url'|'base64', value} →
 *    AVPlayer 播放（url 直连；base64 解码写沙箱临时文件后 fd 播放）；
 *  - Manggo：调用 tts(text, language, options)（promise 模式）→ 归一化 {__phAudio:{base64}} →
 *    同样写临时文件后 fd 播放。
 *  暂停/继续/停止对齐系统 TTS 播放通道（SpeechPlayback 接口），调用方无感切换。
 */

/** 播放通道统一接口（系统 TtsPlayback 与插件播放器共同实现） */
export interface SpeechPlayback {
  pause(): Promise<void>;
  resume(): Promise<void>;
  stop(): Promise<void>;
  isPaused(): boolean;
}

export class PluginTtsPlayback implements SpeechPlayback {
  private player: media.AVPlayer | null = null;
  private paused: boolean = false;
  private stopped: boolean = false;
  /** base64 播放的临时文件（fd 与路径，结束/停止时清理） */
  private tempPath: string = '';
  private tempFd: number = -1;
  private onFinished: (() => void) | null = null;

  isPaused(): boolean {
    return this.paused;
  }

  /** 合成并播放：插件 tts → 音频数据 → AVPlayer（错误统一采集日志） */
  static async speak(ctx: common.UIAbilityContext, pluginId: string, text: string,
    langTag: string, onFinished: () => void): Promise<PluginTtsPlayback> {
    try {
      return await PluginTtsPlayback.doSpeak(ctx, pluginId, text, langTag, onFinished);
    } catch (e) {
      const msg = (e instanceof Error) ? e.message : String(e);
      devLogStore.append('error', 'tts', `TTS 失败：${pluginId}：${msg}`);
      throw new Error(msg);
    }
  }

  private static async doSpeak(ctx: common.UIAbilityContext, pluginId: string, text: string,
    langTag: string, onFinished: () => void): Promise<PluginTtsPlayback> {
    await bobPluginEngine.ensureLoaded(pluginId);
    const query: Record<string, string> = {
      'text': text,
      'lang': toBobLang(langTag.startsWith('en') ? 'en' : (langTag.startsWith('zh') ? 'zh' : langTag))
    };
    const raw = await pluginHost.callPluginFn(pluginId, 'tts',
      JSON.stringify([query]), 'callback', 60000);

    let parsed: Record<string, Object>;
    try {
      parsed = JSON.parse(raw) as Record<string, Object>;
    } catch (e) {
      throw new Error('插件 TTS 返回无法解析');
    }
    if (parsed['error'] !== undefined && parsed['error'] !== null) {
      const err = parsed['error'] as Record<string, Object>;
      const msg = typeof err['message'] === 'string' ? err['message'] as string : '插件 TTS 错误';
      throw new Error(msg);
    }
    const result = parsed['result'] as Record<string, Object>;
    if (result === undefined || result === null) {
      throw new Error('插件未返回 TTS 结果');
    }
    const type = typeof result['type'] === 'string' ? result['type'] as string : '';
    const value = typeof result['value'] === 'string' ? result['value'] as string : '';
    if (type.length === 0 || value.length === 0) {
      throw new Error('插件 TTS 结果缺少 type/value');
    }

    const pb = new PluginTtsPlayback();
    pb.onFinished = onFinished;
    await pb.start(ctx, type, value);
    return pb;
  }

  /** Manggo 语音服务合成并播放：engineId = 'plugin-<pid>#<sid>'，langTag 为 BCP 风格标签 */
  static async speakManggo(ctx: common.UIAbilityContext, engineId: string, text: string,
    langTag: string, onFinished: () => void): Promise<PluginTtsPlayback> {
    try {
      return await PluginTtsPlayback.doSpeakManggo(ctx, engineId, text, langTag, onFinished);
    } catch (e) {
      const msg = (e instanceof Error) ? e.message : String(e);
      devLogStore.append('error', 'tts', `TTS 失败：${engineId}：${msg}`);
      throw new Error(msg);
    }
  }

  private static async doSpeakManggo(ctx: common.UIAbilityContext, engineId: string, text: string,
    langTag: string, onFinished: () => void): Promise<PluginTtsPlayback> {
    const parts = splitServiceRef(engineId.substring('plugin-'.length));
    await bobPluginEngine.ensureLoaded(parts.pluginId);
    // 语言：BCP 标签主子标签 → 内部码 → manggo 码 → 清单 language 映射（第三方码）
    const appCode = langTag.indexOf('-') >= 0 ? langTag.substring(0, langTag.indexOf('-')).toLowerCase()
      : langTag;
    const rec = bobPluginEngine.record(parts.pluginId);
    let languageJson = '';
    if (rec !== undefined) {
      const svc = parseManggoServices(rec.infoJson).find((m): boolean => m.id === parts.serviceId);
      languageJson = svc !== undefined ? svc.languageJson : '';
    }
    const langArg = applyManggoLangMap(languageJson, toManggoLang(appCode));
    const raw = await pluginHost.callPluginFn(parts.pluginId, manggoEntryGlobalName(parts.serviceId),
      JSON.stringify([text, langArg]), 'promise', 60000);

    let parsed: Object;
    try {
      parsed = JSON.parse(raw) as Object;
    } catch (e) {
      throw new Error('插件 TTS 返回无法解析');
    }
    // 启动脚本归一化结果：{__phAudio: {base64, format?}}（未识别的返回已在沙盒内抛错）
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      throw new Error('插件 TTS 返回了不支持的音频数据');
    }
    const audio = (parsed as Record<string, Object>)['__phAudio'] as Record<string, Object>;
    if (audio === undefined || audio === null || typeof audio['base64'] !== 'string'
      || (audio['base64'] as string).length === 0) {
      throw new Error('插件未返回有效音频数据');
    }

    const pb = new PluginTtsPlayback();
    pb.onFinished = onFinished;
    await pb.start(ctx, 'base64', audio['base64'] as string);
    return pb;
  }

  private async start(ctx: common.UIAbilityContext, type: string, value: string): Promise<void> {
    const player = await media.createAVPlayer();
    this.player = player;

    // AVPlayer 状态机事件驱动：url/fd 赋值后异步进入 initialized，此刻才能 prepare → play
    player.on('stateChange', (state: string): void => {
      if (this.stopped) {
        return;
      }
      if (state === 'initialized') {
        player.prepare().then(async (): Promise<void> => {
          if (!this.stopped) {
            await player.play();
          }
        }).catch((e: BusinessError): void => {
          hilog.error(0x0001, 'PluginTts', 'prepare/play failed %{public}d %{public}s', e.code, e.message);
          this.finish();
        });
      } else if (state === 'completed' || state === 'error' || state === 'released') {
        this.finish();
      }
    });
    player.on('error', (err: BusinessError): void => {
      hilog.error(0x0001, 'PluginTts', 'avplayer error %{public}d %{public}s', err.code, err.message);
      if (!this.stopped) {
        this.finish();
      }
    });

    if (type === 'url') {
      player.url = value;
    } else {
      // base64：解码写沙箱临时文件 → fd 播放
      const helper = new util.Base64Helper();
      const bytes = helper.decodeSync(value);
      this.tempPath = `${ctx.cacheDir}/tts_plugin_${Date.now()}.audio`;
      const f = fileIo.openSync(this.tempPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, bytes.buffer as ArrayBuffer, { length: bytes.byteLength });
      this.tempFd = f.fd;
      player.url = 'fd://' + f.fd;
    }
  }

  private finish(): void {
    const cb = this.onFinished;
    this.cleanup();
    if (cb !== null) {
      cb();
    }
  }

  private cleanup(): void {
    this.stopped = true;
    if (this.player !== null) {
      const p = this.player;
      this.player = null;
      p.off('stateChange');
      p.off('error');
      p.release().catch((e: BusinessError): void => {
        hilog.error(0x0001, 'PluginTts', 'release failed %{public}s', e.message);
      });
    }
    if (this.tempFd >= 0) {
      try {
        fileIo.closeSync(this.tempFd);
      } catch (e) {
        // 忽略
      }
      this.tempFd = -1;
    }
    if (this.tempPath.length > 0) {
      try {
        if (fileIo.accessSync(this.tempPath)) {
          fileIo.unlinkSync(this.tempPath);
        }
      } catch (e) {
        // 忽略
      }
      this.tempPath = '';
    }
  }

  async pause(): Promise<void> {
    if (this.player !== null && !this.paused) {
      await this.player.pause();
      this.paused = true;
    }
  }

  async resume(): Promise<void> {
    if (this.player !== null && this.paused) {
      await this.player.play();
      this.paused = false;
    }
  }

  async stop(): Promise<void> {
    this.cleanup();
  }
}
