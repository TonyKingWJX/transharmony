import { AbilityConstant, UIAbility, Want, ConfigurationConstant, Configuration, errorManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { TranslateUseCase } from '../services/TranslateUseCase';
import { settingsStore } from '../services/SettingsStore';
import { devLogStore, PLUGIN_LOG_TEXT_KEY } from '../services/DevLogStore';
import { Ux } from '../common/Ux';
import pluginHost from 'libpluginhost.so';

const DOMAIN = 0x0000;
const TAG = 'TransHarmony';

/**
 * 插件 $log 全局回投：采集进开发者日志系统（开关开启时），
 * 同时更新 AppStorage 文本供插件实验室页内实时展示（保留原 40 行行为）。
 * 在 EntryAbility 注册一次，避免实验室页注册覆盖导致离开页面后采集中断。
 */
function onPluginLog(logJson: string): void {
  try {
    const entry = JSON.parse(logJson) as Record<string, string>;
    const level = entry['level'] ?? 'info';
    const message = entry['message'] ?? '';
    devLogStore.append(level, 'plugin', message);
    const prev = AppStorage.get<string>(PLUGIN_LOG_TEXT_KEY) ?? '';
    const lines = prev === '' ? [] : prev.split('\n');
    lines.push('[' + level + '] ' + message);
    AppStorage.setOrCreate(PLUGIN_LOG_TEXT_KEY, lines.slice(-40).join('\n'));
  } catch (e) {
    // 忽略解析失败
  }
}

/**
 * 全局崩溃钩子：未捕获异常（含完整堆栈）采集进开发者日志并立即落盘。
 * 两个回调对同一次崩溃都会触发，onUnhandledException 按 500ms 去重；
 * 回调只做记录，不干预系统默认崩溃处理，不影响现有行为。
 */
let lastCrashLogAt = 0;

const crashObserver: errorManager.ErrorObserver = {
  onException(errObj: Error): void {
    lastCrashLogAt = Date.now();
    const stack = typeof errObj.stack === 'string' ? errObj.stack : '';
    devLogStore.append('error', 'crash', '异常：' + errObj.name + '：' + errObj.message +
      (stack.length > 0 ? '\n' + stack.substring(0, 800) : ''));
    devLogStore.flush();
  },
  onUnhandledException(errMsg: string): void {
    if (Date.now() - lastCrashLogAt < 500) {
      return; // onException 已记录同一次崩溃
    }
    devLogStore.append('error', 'crash', '未捕获异常：' + errMsg.substring(0, 800));
    devLogStore.flush();
  }
};

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbility onCreate');
    // 插件 $log 回投：应用启动即全局注册，实验室页开关不影响采集
    pluginHost.registerLogHandler(onPluginLog);
    // 全局崩溃采集：注册失败不影响启动
    try {
      errorManager.on('error', crashObserver);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'errorManager register failed: %{public}s', 'ignored');
    }
    TranslateUseCase.bootstrap(this.context).then((): void => {
      // 应用持久化的深色模式偏好（'system' | 'light' | 'dark'）
      const mode = settingsStore.getColorModePref();
      const appCtx = this.context.getApplicationContext();
      if (mode === 'dark') {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      } else if (mode === 'light') {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
      } else {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      }
      Ux.applySystemBarStyle(EntryAbility.isDark());
      // 翻译页启动时读取默认引擎/语言对
      AppStorage.setOrCreate('pref_engine_id', settingsStore.getEngineId());
      AppStorage.setOrCreate('pref_from_lang', settingsStore.getFromLang());
      AppStorage.setOrCreate('pref_to_lang', settingsStore.getToLang());
      // 开发者模式 + 日志系统：读持久化开关并桥接 AppStorage
      AppStorage.setOrCreate('dev_mode', settingsStore.getDevMode());
      AppStorage.setOrCreate(PLUGIN_LOG_TEXT_KEY, '');
      devLogStore.init(this.context);
    });
  }

  /** 结合偏好与系统深浅状态，推断系统栏应为暗色还是亮色 */
  private static isDark(): boolean {
    const mode = settingsStore.getColorModePref();
    if (mode === 'dark') {
      return true;
    }
    if (mode === 'light') {
      return false;
    }
    return Ux.systemDark;
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbility onWindowStageCreate');
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading content.');
      // 沉浸式：全屏布局 + 避让区监听 + 透明系统栏
      const win = windowStage.getMainWindowSync();
      Ux.setupWindow(win);
      Ux.systemDark = this.context.config?.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      Ux.applySystemBarStyle(EntryAbility.isDark());
    });
  }

  /** 系统深浅模式变化（跟随系统模式下同步系统栏外观） */
  onConfigurationUpdate(newConfig: Configuration): void {
    Ux.systemDark = newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    Ux.applySystemBarStyle(EntryAbility.isDark());
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbility onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbility onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbility onBackground');
    // 退后台立即落盘，防止日志随进程被杀丢失
    devLogStore.flush();
  }
}
