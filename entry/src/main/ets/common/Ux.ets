import { window, display } from '@kit.ArkUI';

/**
 * 沉浸式窗口适配（官方方案，参考设计文档 arkts-develop-apply-immersive-effects）：
 * 1) setWindowLayoutFullScreen(true) 全屏布局，内容延伸到状态栏/导航条之下；
 * 2) getWindowAvoidArea 获取状态栏/导航条避让高度，写入 AppStorage（vp）供页面避让；
 * 3) on('avoidAreaChange') 动态监听（旋转/分屏/折叠等场景）；
 * 4) setWindowSystemBarProperties 设置透明系统栏，文字颜色随深浅模式切换。
 */
export class Ux {
  private static mainWindow: window.Window | null = null;
  /** 系统当前是否深色（跟随系统模式下用于推断系统栏外观） */
  static systemDark: boolean = false;

  static setupWindow(win: window.Window): void {
    Ux.mainWindow = win;
    win.setWindowLayoutFullScreen(true);
    Ux.refreshAvoidArea();
    Ux.refreshWindowSize();
    win.on('avoidAreaChange', (): void => {
      Ux.refreshAvoidArea();
    });
    // 旋转/分屏/自由多窗等尺寸变化：同步避让高度与窗口宽度（平板断点依据）
    win.on('windowSizeChange', (): void => {
      Ux.refreshAvoidArea();
      Ux.refreshWindowSize();
    });
  }

  static refreshAvoidArea(): void {
    const win = Ux.mainWindow;
    if (win === null) {
      return;
    }
    const density = display.getDefaultDisplaySync().densityPixels;
    const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    const nav = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
    AppStorage.setOrCreate('ux_statusBarH', sys.topRect.height / density);
    AppStorage.setOrCreate('ux_navBarH', nav.bottomRect.height / density);
  }

  /** 窗口宽度（vp）与官方横向断点写入 AppStorage。
   *  断点（官方推荐区间）：sm [320,600) 直板机/折叠态；md [600,840) 双折叠展开/阔折叠展开；
   *  lg [840,1440) 平板/三折叠双屏态；xl [1440,+∞) 三折叠全展开/大平板横屏 */
  static refreshWindowSize(): void {
    const win = Ux.mainWindow;
    if (win === null) {
      return;
    }
    const density = display.getDefaultDisplaySync().densityPixels;
    const w = win.getWindowProperties().windowRect.width / density;
    AppStorage.setOrCreate('ux_winW', w);
    let bp = 'sm';
    if (w >= 1440) {
      bp = 'xl';
    } else if (w >= 840) {
      bp = 'lg';
    } else if (w >= 600) {
      bp = 'md';
    }
    AppStorage.setOrCreate('ux_breakpoint', bp);
  }

  /** 深浅模式切换时同步系统栏文字颜色（状态栏/导航条背景保持透明，露出页面背景） */
  static applySystemBarStyle(dark: boolean): void {
    const win = Ux.mainWindow;
    if (win === null) {
      return;
    }
    win.setWindowSystemBarProperties({
      statusBarColor: '#00000000',
      statusBarContentColor: dark ? '#E5FFFFFF' : '#E5000000',
      navigationBarContentColor: dark ? '#E5FFFFFF' : '#E5000000'
    });
  }
}
