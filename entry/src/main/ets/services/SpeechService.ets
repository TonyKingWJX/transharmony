import { textToSpeech, speechRecognizer } from '@kit.CoreSpeechKit';
import { audio } from '@kit.AudioKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { settingsStore } from './SettingsStore';
import { SpeechPlayback, PluginTtsPlayback } from './plugin/PluginTtsPlayback';
import { bobPluginEngine } from './plugin/BobPluginEngine';

const TAG = 'SpeechService';

/**
 * TTS 播放通道（官方 speakOnData 模式）：
 * speak 时 extraParams 传 playType:0，引擎只合成不播放，PCM 分片经 onData 按给应用；
 * 分片可能乱序（官方文档要求按 sequence 排序），内部按序拼接成字节流，
 * 交给 AudioRenderer 播放——AudioRenderer 原生 pause/start，从而支持暂停/继续。
 */
class TtsPlayback implements SpeechPlayback {
  private renderer: audio.AudioRenderer | null = null;
  /** sequence → pcm 分片（乱序到达时暂存） */
  private pending: Map<number, Uint8Array> = new Map();
  /** 下一个待拼接的序号 */
  private nextSeq: number = 0;
  /** 按序拼好的可播放字节流 */
  private pcm: Uint8Array = new Uint8Array(0);
  private paused: boolean = false;
  private stopped: boolean = false;
  private finished: boolean = false;
  /** 播放结束通知（合成完成且字节流播尽） */
  private onFinished: (() => void) | null = null;
  private synthesisDone: boolean = false;

  /** 收到一片合成音频（复制入队，按 sequence 归位） */
  pushAudio(seq: number, data: ArrayBuffer): void {
    if (this.stopped) {
      return;
    }
    this.pending.set(seq, new Uint8Array(data.slice(0)));
    this.drainPending();
  }

  /** 把连续到达的分片拼进字节流尾部 */
  private drainPending(): void {
    while (this.pending.has(this.nextSeq)) {
      const chunk = this.pending.get(this.nextSeq);
      this.pending.delete(this.nextSeq);
      this.nextSeq++;
      if (chunk !== undefined) {
        const merged = new Uint8Array(this.pcm.length + chunk.length);
        merged.set(this.pcm);
        merged.set(chunk, this.pcm.length);
        this.pcm = merged;
      }
    }
  }

  markSynthesisDone(): void {
    this.synthesisDone = true;
    this.drainPending();
  }

  isPaused(): boolean {
    return this.paused;
  }

  async start(onFinished: () => void): Promise<void> {
    this.onFinished = onFinished;
    this.stopped = false;
    this.paused = false;
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const options: audio.AudioRendererOptions = {
      streamInfo: streamInfo,
      rendererInfo: {
        usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
        rendererFlags: 0
      }
    };
    this.renderer = await audio.createAudioRenderer(options);
    this.renderer.on('writeData', (buffer: ArrayBuffer): audio.AudioDataCallbackResult | void => {
      if (this.stopped) {
        return audio.AudioDataCallbackResult.INVALID;
      }
      this.drainPending();
      if (this.pcm.length === 0) {
        // 合成完成且播尽 → 结束；否则等下一轮取数（合成仍在进行）
        if (this.synthesisDone && this.pending.size === 0 && !this.finished) {
          this.finished = true;
          const done = this.onFinished;
          this.onFinished = null;
          if (done !== null) {
            done();
          }
        }
        return audio.AudioDataCallbackResult.INVALID;
      }
      // 按渲染器要的字节数从流头取数据；不足一帧的尾部补静音，避免杂音
      const n = Math.min(buffer.byteLength, this.pcm.length);
      const view = new Uint8Array(buffer);
      view.set(this.pcm.subarray(0, n));
      for (let i = n; i < view.length; i++) {
        view[i] = 0;
      }
      this.pcm = this.pcm.slice(n);
      return audio.AudioDataCallbackResult.VALID;
    });
    await this.renderer.start();
  }

  /** 暂停：渲染器停止消费，字节流原地保留 */
  async pause(): Promise<void> {
    if (this.renderer !== null && !this.paused) {
      this.paused = true;
      try {
        await this.renderer.pause();
      } catch (e) {
        // 状态不允许时忽略
      }
    }
  }

  /** 继续 */
  async resume(): Promise<void> {
    if (this.renderer !== null && this.paused) {
      this.paused = false;
      try {
        await this.renderer.start();
      } catch (e) {
        // 已在 running 时忽略
      }
    }
  }

  /** 停止并释放资源 */
  async stop(): Promise<void> {
    this.stopped = true;
    this.pending.clear();
    this.pcm = new Uint8Array(0);
    const r = this.renderer;
    this.renderer = null;
    if (r !== null) {
      try {
        await r.stop();
        await r.release();
      } catch (e) {
        // 已释放时忽略
      }
    }
  }
}

export class SpeechService {
  private static ttsEngines: Map<string, textToSpeech.TextToSpeechEngine> = new Map();
  private static asrEngine: speechRecognizer.SpeechRecognitionEngine | null = null;
  /** 当前 TTS 播放通道（系统 TtsPlayback 或插件 PluginTtsPlayback，含暂停/继续能力） */
  private static playback: SpeechPlayback | null = null;
  /** 应用上下文（bootstrap 存入）：插件 TTS 的临时音频文件落盘用 */
  private static appCtx: common.UIAbilityContext | null = null;
  /** 当前通道归属：'input' | 'result'，供调用方区分两颗按钮 */
  static activeChannel: string = '';
  /** ASR 语音识别中 */
  private static listening: boolean = false;
  /** ASR 结束回调 */
  private static asrOnEnd: ((errMsg: string) => void) | null = null;
  /** 最近一次 startListening 的会话 id（finish/cancel 须与之一致） */
  private static activeSessionId: string = '';

  /** bootstrap 存应用上下文（插件 TTS 临时文件用） */
  static init(context: common.UIAbilityContext): void {
    SpeechService.appCtx = context;
  }

  /** 当前 TTS 服务是否支持该语言：插件服务按插件声明（未声明=放行），系统服务仅中英 */
  static isLangSupported(code: string): boolean {
    const ttsEngineId = settingsStore.getTtsEngineId();
    if (ttsEngineId.startsWith('plugin-')) {
      const pluginId = ttsEngineId.substring('plugin-'.length);
      const normalized = code.startsWith('en') ? 'en' : (code.startsWith('zh') ? 'zh' : code);
      return bobPluginEngine.langsOf(pluginId).includes(normalized);
    }
    return code.startsWith('zh') || code.startsWith('en');
  }

  private static errMsg(e: Object): string {
    const be = e as BusinessError;
    if (be !== null && be !== undefined && be.code !== undefined) {
      return be.code + ' ' + (be.message ?? '');
    }
    if (e instanceof Error) {
      return e.message;
    }
    return String(e);
  }

  // ---- TTS 朗读（合成→PCM 流→AudioRenderer 播放，支持暂停/继续） ----

  /**
   * 按语种懒创建 TTS 引擎。音色按官方要求配置（CreateEngineParams.person）：
   * 中文 13=聆小珊女声（推荐），英文 8=劳拉女声（需系统内已下载该音色）。
   * 英文音色缺失时回退中文引擎朗读，保证有声音输出。
   */
  private static async ensureTts(language: string): Promise<textToSpeech.TextToSpeechEngine> {
    const cached = SpeechService.ttsEngines.get(language);
    if (cached !== undefined) {
      return cached;
    }
    const person = language.startsWith('en') ? 8 : 13;
    try {
      const engine = await textToSpeech.createEngine({
        language: language,
        person: person,
        online: 1
      });
      SpeechService.ttsEngines.set(language, engine);
      return engine;
    } catch (e) {
      // 英文音色（person 8）未下载等场景：回退中文引擎（13），朗读不中断
      if (language.startsWith('en')) {
        hilog.error(0x0001, TAG, 'tts en engine failed, fallback to zh: %{public}s',
          SpeechService.errMsg(e as Object));
        const fallback = await SpeechService.ensureTts('zh-CN');
        SpeechService.ttsEngines.set(language, fallback);
        return fallback;
      }
      throw new Error(SpeechService.errMsg(e as Object));
    }
  }

  /**
   * 朗读文本：合成经 onData 转 AudioRenderer 播放，支持暂停/继续。
   * @param channel 'input' | 'result'（调用方按钮标识，状态互斥）
   * @param onStateChange 播放结束回调（含 stop/出错），用于复位按钮状态
   */
  static async speak(text: string, langTag: string, channel: string,
    onStateChange: () => void): Promise<void> {
    await SpeechService.stopSpeakInternal();

    // 语音服务选择为插件时走插件 TTS（tts(query, completion) → url/base64 → AVPlayer）
    const ttsEngineId = settingsStore.getTtsEngineId();
    if (ttsEngineId.startsWith('plugin-')) {
      const pluginId = ttsEngineId.substring('plugin-'.length);
      if (SpeechService.appCtx === null) {
        throw new Error('应用尚未初始化完成');
      }
      const pb = await PluginTtsPlayback.speak(SpeechService.appCtx, pluginId, text, langTag,
        onStateChange);
      SpeechService.playback = pb;
      SpeechService.activeChannel = channel;
      return;
    }

    const language = langTag.startsWith('en') ? 'en-US' : 'zh-CN';
    const engine = await SpeechService.ensureTts(language);

    const pb = new TtsPlayback();
    SpeechService.playback = pb;
    SpeechService.activeChannel = channel;

    const listener: textToSpeech.SpeakListener = {
      onStart: (requestId: string, response: textToSpeech.StartResponse): void => {
      },
      onComplete: (requestId: string, response: textToSpeech.CompleteResponse): void => {
        pb.markSynthesisDone();
      },
      onStop: (requestId: string, response: textToSpeech.StopResponse): void => {
        pb.markSynthesisDone();
      },
      onData: (requestId: string, pcm: ArrayBuffer,
        response: textToSpeech.SynthesisResponse): void => {
        pb.pushAudio(response.sequence, pcm);
      },
      onError: (requestId: string, errorCode: number, errorMessage: string): void => {
        hilog.error(0x0001, TAG, 'tts onError %{public}d %{public}s', errorCode, errorMessage);
        pb.markSynthesisDone();
      }
    };
    engine.setListener(listener);

    const params: textToSpeech.SpeakParams = {
      requestId: 'th-' + Date.now().toString(),
      // playType:0 = 引擎只合成不播放（官方 speakOnData 模式），PCM 交应用 AudioRenderer 播放，
      // 这是暂停/继续能力的前提；soundChannel:1 = 左声道单声道输出
      extraParams: {
        'queueMode': 0,
        'speed': 1,
        'volume': 2,
        'pitch': 1,
        'languageContext': language,
        'audioType': 'pcm',
        'soundChannel': 1,
        'playType': 0
      } as Record<string, Object>
    };
    await pb.start(onStateChange);
    engine.speak(text, params);
  }

  /** 暂停当前朗读 */
  static async pauseSpeak(): Promise<void> {
    if (SpeechService.playback !== null) {
      await SpeechService.playback.pause();
    }
  }

  /** 继续当前朗读 */
  static async resumeSpeak(): Promise<void> {
    if (SpeechService.playback !== null) {
      await SpeechService.playback.resume();
    }
  }

  /** 当前朗读是否处于暂停态 */
  static isSpeakPaused(): boolean {
    return SpeechService.playback !== null && SpeechService.playback.isPaused();
  }

  static activePlaybackChannel(): string {
    return SpeechService.activeChannel;
  }

  /** 停止朗读（对外） */
  static stopSpeak(): void {
    SpeechService.stopSpeakInternal();
  }

  private static async stopSpeakInternal(): Promise<void> {
    const pb = SpeechService.playback;
    SpeechService.playback = null;
    SpeechService.activeChannel = '';
    if (pb !== null) {
      await pb.stop();
    }
  }

  // ---- ASR 语音识别 ----

  private static async ensureAsr(): Promise<speechRecognizer.SpeechRecognitionEngine> {
    if (SpeechService.asrEngine !== null) {
      return SpeechService.asrEngine;
    }
    SpeechService.asrEngine = await speechRecognizer.createEngine({
      language: 'zh-CN',
      online: 1
    });
    return SpeechService.asrEngine;
  }

  /**
   * 开始语音识别（recognitionMode 0：引擎内部实时录音，结束调 finish/cancel）。
   * 「暂停」即 finish 当前会话（拿到已识别文本）；再调 startAsr 开新会话即可继续。
   * @param onText 识别结果回调（含中间结果）
   * @param onEnd 识别结束回调（errMsg 为空串表示正常结束）
   */
  static async startAsr(onText: (text: string) => void,
    onEnd: (errMsg: string) => void): Promise<void> {
    const engine = await SpeechService.ensureAsr();
    // 上一次会话若未正常收尾，先显式取消，避免残留会话态
    if (SpeechService.activeSessionId.length > 0) {
      try {
        engine.cancel(SpeechService.activeSessionId);
      } catch (e) {
        // 无残留会话时 cancel 报错，忽略
      }
      SpeechService.activeSessionId = '';
    }
    const sessionId = 'th-asr-' + util.generateRandomUUID();
    SpeechService.listening = true;
    SpeechService.asrOnEnd = onEnd;
    engine.setListener({
      onStart: (sid: string, eventMessage: string) => {
        hilog.info(0x0001, TAG, 'asr onStart');
      },
      onEvent: (sid: string, eventCode: number, eventMessage: string) => {
        hilog.info(0x0001, TAG, 'asr onEvent %{public}d', eventCode);
      },
      onResult: (sid: string, result: speechRecognizer.SpeechRecognitionResult) => {
        onText(result.result);
      },
      onComplete: (sid: string, eventMessage: string) => {
        SpeechService.activeSessionId = '';
        SpeechService.listening = false;
        const cb = SpeechService.asrOnEnd;
        SpeechService.asrOnEnd = null;
        if (cb !== null) {
          cb('');
        }
      },
      onError: (sid: string, errorCode: number, errorMessage: string) => {
        hilog.error(0x0001, TAG, 'asr onError %{public}d %{public}s', errorCode, errorMessage);
        SpeechService.activeSessionId = '';
        SpeechService.listening = false;
        const cb = SpeechService.asrOnEnd;
        SpeechService.asrOnEnd = null;
        if (cb !== null) {
          cb(errorMessage);
        }
      }
    });

    const audioParam: speechRecognizer.AudioInfo = {
      audioType: 'pcm',
      sampleRate: 16000,
      soundChannel: 1,
      sampleBit: 16
    };
    // 模式 0（长语音）：vadBegin/vadEnd 为不支持配置项，不传；上限 60s，可提前点停止
    const extraParam: Record<string, Object> = {
      'recognitionMode': 0,
      'maxAudioDuration': 60000
    };
    const params: speechRecognizer.StartParams = {
      sessionId: sessionId,
      audioInfo: audioParam,
      extraParams: extraParam
    };
    engine.startListening(params);
    SpeechService.activeSessionId = sessionId;
  }

  /**
   * 暂停识别：finish 当前会话（引擎回调 onComplete，已识别文本已通过 onResult 给出）。
   * 「继续」= 再次调 startAsr。
   */
  static pauseAsr(): void {
    if (SpeechService.activeSessionId.length > 0) {
      try {
        SpeechService.asrEngine?.finish(SpeechService.activeSessionId);
      } catch (e) {
        // 会话已结束时 finish 可能报错，忽略
      }
    }
  }

  /** 彻底取消识别（切页/切换语言等场景） */
  static cancelAsr(): void {
    if (SpeechService.activeSessionId.length > 0) {
      try {
        SpeechService.asrEngine?.cancel(SpeechService.activeSessionId);
      } catch (e) {
        // 忽略
      }
      SpeechService.activeSessionId = '';
    }
    SpeechService.listening = false;
    SpeechService.asrOnEnd = null;
  }

  static isListening(): boolean {
    return SpeechService.listening;
  }
}
