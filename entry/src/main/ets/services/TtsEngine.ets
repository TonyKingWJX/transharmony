import { media } from '@kit.MediaKit';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { postBinary, postJson, truncate } from '../utils/HttpClient';
import { safeParse, getStr, getObj, getArr } from '../utils/JsonUtil';
import { settingsStore, ServiceItem } from './SettingsStore';
import { findDef, ProviderDef } from './ProviderCatalog';
import { devLogStore } from './DevLogStore';
import { SpeechPlayback } from './plugin/PluginTtsPlayback';

/**
 * 云端 TTS 执行器（语音服务实例，与系统/插件 TTS 并列的通道）：
 * 合成协议统一为 OpenAI /audio/speech 形状（model/input/voice → mp3 音频字节）；
 * Anthropic 兼容（aiFormat='anthropic'）仅改变鉴权头（x-api-key + anthropic-version）。
 * 音频字节写沙箱临时文件 → AVPlayer fd 播放，暂停/继续/停止对齐 SpeechPlayback 接口，
 * 调用方（SpeechService）无感切换。
 */

const TAG = 'TtsEngine';

function trimSlash(s: string): string {
  return s.endsWith('/') ? s.substring(0, s.length - 1) : s;
}

/** 云端 TTS 播放通道（AVPlayer + 沙箱临时文件） */
class CloudTtsPlayback implements SpeechPlayback {
  private player: media.AVPlayer | null = null;
  private paused: boolean = false;
  private stopped: boolean = false;
  /** 沙箱临时音频文件（fd 与路径，结束/停止时清理） */
  private tempPath: string = '';
  private tempFd: number = -1;
  /** 播放结束通知（TtsEngine 落盘启动前赋值；同模块内访问，不设 private） */
  onFinished: (() => void) | null = null;

  isPaused(): boolean {
    return this.paused;
  }

  /** 音频字节落盘 → fd 播放（AVPlayer 状态机事件驱动，同 PluginTtsPlayback） */
  async start(ctx: common.UIAbilityContext, bytes: Uint8Array): Promise<void> {
    const player = await media.createAVPlayer();
    this.player = player;

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
          hilog.error(0x0001, TAG, 'prepare/play failed %{public}d %{public}s', e.code, e.message);
          this.finish();
        });
      } else if (state === 'completed' || state === 'error' || state === 'released') {
        this.finish();
      }
    });
    player.on('error', (err: BusinessError): void => {
      hilog.error(0x0001, TAG, 'avplayer error %{public}d %{public}s', err.code, err.message);
      if (!this.stopped) {
        this.finish();
      }
    });

    this.tempPath = ctx.cacheDir + '/tts_cloud_' + Date.now() + '.mp3';
    const f = fileIo.openSync(this.tempPath,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(f.fd, bytes.buffer as ArrayBuffer, { length: bytes.byteLength });
    this.tempFd = f.fd;
    player.url = 'fd://' + f.fd;
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
        hilog.error(0x0001, TAG, 'release failed %{public}s', e.message);
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

/** 连通测试结果（ServiceConfigPage 用） */
export interface TtsTestResult {
  ok: boolean;
  message: string;
}

export class TtsEngine {
  /**
   * 合成并播放：实例凭证 → /audio/speech → mp3 字节 → AVPlayer。
   * 错误统一采集日志；返回播放通道供 SpeechService 挂到当前 playback。
   */
  static async speak(ctx: common.UIAbilityContext, serviceId: string, text: string,
    onFinished: () => void): Promise<CloudTtsPlayback> {
    try {
      return await TtsEngine.doSpeak(ctx, serviceId, text, onFinished);
    } catch (e) {
      const msg = (e instanceof Error) ? e.message : String(e);
      devLogStore.append('error', 'tts', '云端 TTS 失败：' + msg + TtsEngine.keyDiagnostic(serviceId));
      throw new Error(msg);
    }
  }

  /** 诊断后缀：本机密钥是否已配置（开发者日志用于区分「本机未配密钥」与「服务端鉴权失败 401」） */
  private static keyDiagnostic(serviceId: string): string {
    const s = settingsStore.getServiceIn('tts', serviceId);
    const len = s !== undefined ? (s.config['apiKey'] ?? '').length : -1;
    return len > 0 ? '（本机密钥已配置，疑似服务端校验失败）' : '（本机密钥未配置或读取失败）';
  }

  private static async doSpeak(ctx: common.UIAbilityContext, serviceId: string, text: string,
    onFinished: () => void): Promise<CloudTtsPlayback> {
    const bytes = await TtsEngine.synthesize(serviceId, text);
    const pb = new CloudTtsPlayback();
    pb.onFinished = onFinished;
    await pb.start(ctx, bytes);
    return pb;
  }

  /** 连通测试：合成一句短文本（不播放），验证地址/密钥/模型/音色全链路 */
  static async testService(serviceId: string): Promise<TtsTestResult> {
    const started = Date.now();
    try {
      const bytes = await TtsEngine.synthesize(serviceId, '你好。');
      const ok: TtsTestResult = {
        ok: true,
        message: '连通正常 · ' + (Date.now() - started) + 'ms · 音频 ' + Math.max(1, Math.round(bytes.length / 1024)) + 'KB'
      };
      return ok;
    } catch (e) {
      const fail: TtsTestResult = { ok: false, message: e instanceof Error ? e.message : '测试失败，请检查网络与凭证' };
      devLogStore.append('error', 'tts', '连通测试失败：' + fail.message + TtsEngine.keyDiagnostic(serviceId));
      return fail;
    }
  }

  /** 合成：解析实例凭证 → POST {base}/audio/speech → 音频字节 */
  private static async synthesize(serviceId: string, text: string): Promise<Uint8Array> {
    const s: ServiceItem | undefined = settingsStore.getServiceIn('tts', serviceId);
    if (s === undefined) {
      throw new Error('未找到该语音服务实例');
    }
    if (!s.enabled) {
      throw new Error('「' + s.name + '」已停用，请在偏好设置中重新选择');
    }
    const def: ProviderDef | undefined = findDef(s.defId);
    if (def === undefined) {
      throw new Error('未找到该语音服务定义');
    }
    const base = trimSlash((s.config['baseUrl'] ?? '').length > 0 ? s.config['baseUrl'] : def.baseUrl);
    if (base.length === 0) {
      throw new Error('请先在配置页填写 API 地址');
    }
    const model = (s.config['model'] ?? '').length > 0 ? s.config['model'] : def.defaultModel;
    if (model.length === 0) {
      throw new Error('请先在配置页填写模型名');
    }
    const voice = (s.config['voice'] ?? '').length > 0
      ? s.config['voice'] : (def.defaultVoice ?? '');
    const apiKey = s.config['apiKey'] ?? '';

    // MiMo：官方 TTS 走 chat/completions，音频以 base64 随响应 JSON 返回（非 /audio/speech 二进制）
    if (def.ttsApi === 'mimo') {
      return await TtsEngine.mimoSynthesize(base, model, voice, apiKey, text);
    }

    // Anthropic 兼容：x-api-key 鉴权（官方无 TTS，供中转/自建兼容服务）；其余 Bearer
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    if (def.aiFormat === 'anthropic') {
      if (apiKey.length > 0) {
        headers['x-api-key'] = apiKey;
      }
      headers['anthropic-version'] = '2023-06-01';
    } else if (apiKey.length > 0) {
      headers['Authorization'] = 'Bearer ' + apiKey;
    }
    const bodyObj: Record<string, string> = {
      'model': model, 'input': text, 'response_format': 'mp3'
    };
    if (voice.length > 0) {
      bodyObj['voice'] = voice;
    }

    const started = Date.now();
    const resp = await postBinary({
      url: base + '/audio/speech',
      headers: headers,
      body: JSON.stringify(bodyObj),
      timeoutMs: 60000
    });
    if (resp.bytes.length === 0) {
      throw new Error('语音服务返回了空音频');
    }
    devLogStore.append('info', 'tts',
      '合成成功：' + s.name + ' ' + Math.round(resp.bytes.length / 1024) + 'KB 耗时' + (Date.now() - started) + 'ms');
    return resp.bytes;
  }

  /**
   * MiMo 合成（官方文档：POST /v1/chat/completions，audio 参数声明输出，音频 base64 在
   * choices[].message.audio.data）。鉴权用 api-key 头（官方亦支持 Bearer）。
   * 音色仅 mimo-v2.5-tts 支持；voicedesign 不带 voice 字段。
   */
  private static async mimoSynthesize(base: string, model: string, voice: string,
    apiKey: string, text: string): Promise<Uint8Array> {
    const assistantMsg: Record<string, string> = { 'role': 'assistant', 'content': text };
    const body: Record<string, Object> = {
      'model': model,
      'messages': [assistantMsg as Object]
    };
    // voicedesign 模型不支持 voice 参数，仅预置音色模型携带
    if (voice.length > 0 && model.indexOf('voicedesign') < 0) {
      const audioParams: Record<string, string> = { 'format': 'mp3', 'voice': voice };
      body['audio'] = audioParams;
    } else {
      const audioParams: Record<string, string> = { 'format': 'mp3' };
      body['audio'] = audioParams;
    }
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    if (apiKey.length > 0) {
      headers['api-key'] = apiKey;
    }
    const started = Date.now();
    const resp = await postJson({
      url: base + '/chat/completions',
      headers: headers,
      body: JSON.stringify(body),
      timeoutMs: 60000
    });
    const root = safeParse(resp.body);
    if (root === null) {
      throw new Error('MiMo 响应解析失败: ' + truncate(resp.body, 120));
    }
    const errObj = getObj(root, 'error');
    if (errObj !== null) {
      throw new Error('MiMo 错误：' + getStr(errObj, 'message'));
    }
    const choices = getArr(root, 'choices');
    if (choices.length === 0) {
      throw new Error('MiMo 响应缺少 choices: ' + truncate(resp.body, 120));
    }
    const message = getObj(choices[0], 'message');
    if (message === null) {
      throw new Error('MiMo 响应缺少 message');
    }
    const audio = getObj(message, 'audio');
    const b64 = audio !== null ? getStr(audio, 'data') : '';
    if (b64.length === 0) {
      throw new Error('MiMo 未返回音频数据: ' + truncate(resp.body, 120));
    }
    const bytes = new util.Base64Helper().decodeSync(b64);
    if (bytes.length === 0) {
      throw new Error('MiMo 音频数据解码失败');
    }
    devLogStore.append('info', 'tts',
      '合成成功：' + Math.round(bytes.length / 1024) + 'KB 耗时' + (Date.now() - started) + 'ms');
    return bytes;
  }
}
