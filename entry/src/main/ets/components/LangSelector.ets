/**
 * 语言选择条：官方 Select 下拉（源/目标）+ 圆形交换按钮。
 * 源语言含「自动检测」；检测到源语言时在源 Select 下方展示提示。
 */

import { AUTO_DETECT, LangCode, LANGUAGE_LIST, LanguageItem, langLabel } from '../models/TranslationTypes';

/** 源语言选项清单（自动检测 + 全部语言） */
const FROM_CODES: LangCode[] = [AUTO_DETECT].concat(LANGUAGE_LIST.map((it: LanguageItem): LangCode => it.code));

@Component
export struct LangSelector {
  @Link fromLang: LangCode;
  @Link toLang: LangCode;
  /** 识别到源语言时展示在源 Select 下方（auto 时） */
  detectedFrom: LangCode = '';
  onPickFrom: (code: LangCode) => void = (code: LangCode): void => {};
  onPickTo: (code: LangCode) => void = (code: LangCode): void => {};
  onSwap: () => void = (): void => {};

  private fromIndex(): number {
    const idx = FROM_CODES.indexOf(this.fromLang);
    return idx >= 0 ? idx : 0;
  }

  private toIndex(): number {
    const idx = LANGUAGE_LIST.findIndex((it: LanguageItem): boolean => it.code === this.toLang);
    return idx >= 0 ? idx : 0;
  }

  private fromText(): string {
    return this.fromLang === AUTO_DETECT ? '自动检测' : langLabel(this.fromLang);
  }

  private fromCaption(): string {
    if (this.fromLang !== AUTO_DETECT) {
      return '原文';
    }
    return this.detectedFrom.length > 0 ? '已识别：' + langLabel(this.detectedFrom) : '待输入';
  }

  private fromOptions(): SelectOption[] {
    const opts: SelectOption[] = [];
    for (const code of FROM_CODES) {
      opts.push({ value: code === AUTO_DETECT ? '自动检测' : langLabel(code) });
    }
    return opts;
  }

  private toOptions(): SelectOption[] {
    const opts: SelectOption[] = [];
    for (const it of LANGUAGE_LIST) {
      opts.push({ value: it.label });
    }
    return opts;
  }

  build() {
    // 上下两行：上行 Select 与交换按钮同排垂直居中（按钮对齐 Select 中心），
    // 下行两个小字说明分别对齐到各自 Select 正下方（列宽与上行完全一致）
    Column({ space: 5 }) {
      Row({ space: 10 }) {
        Column() {
          Select(this.fromOptions())
            .selected(this.fromIndex())
            .value(this.fromText())
            .font({ size: 15, weight: FontWeight.Medium })
            .fontColor($r('app.color.font_primary'))
            .selectedOptionFont({ size: 14 })
            .optionFont({ size: 14 })
            .width('100%')
            .onSelect((index: number): void => {
              if (index >= 0 && index < FROM_CODES.length) {
                this.onPickFrom(FROM_CODES[index]);
              }
            })
        }
        .layoutWeight(1)

        Stack() {
          Circle()
            .width(32)
            .height(32)
            .fill($r('app.color.emphasize_bg_light'))
          SymbolGlyph($r('sys.symbol.arrow_left_arrow_right'))
            .fontSize(15)
            .fontColor([$r('app.color.brand')])
        }
        .width(32)
        .height(32)
        .onClick(() => {
          this.onSwap();
        })

        Column() {
          Select(this.toOptions())
            .selected(this.toIndex())
            .value(langLabel(this.toLang))
            .font({ size: 15, weight: FontWeight.Medium })
            .fontColor($r('app.color.font_primary'))
            .selectedOptionFont({ size: 14 })
            .optionFont({ size: 14 })
            .width('100%')
            .onSelect((index: number): void => {
              if (index >= 0 && index < LANGUAGE_LIST.length) {
                this.onPickTo(LANGUAGE_LIST[index].code);
              }
            })
        }
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: 10 }) {
        Text(this.fromCaption())
          .fontSize(11)
          .fontColor($r('app.color.font_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Blank()
          .width(32)
        Text('译文')
          .fontSize(11)
          .fontColor($r('app.color.font_tertiary'))
          .maxLines(1)
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
  }
}
