import { AbilityConstant, UIAbility, Want, ConfigurationConstant, Configuration } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { TranslateUseCase } from '../services/TranslateUseCase';
import { settingsStore } from '../services/SettingsStore';
import { Ux } from '../common/Ux';

const DOMAIN = 0x0000;
const TAG = 'TransHarmony';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbility onCreate');
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
  }
}
