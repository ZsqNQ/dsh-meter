// 轻测光 · Light Meter for HarmonyOS
// Copyright (C) 2026 南秋 (nanqiu)
// SPDX-License-Identifier: AGPL-3.0-or-later

import { camera } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import { display, window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  ev100From,
  Combo,
  comboFor,
  comboFromShutter,
  formatShutterSecond,
  zoomToSliderPos,
  sliderPosToZoom,
  formatZoom,
  APERTURE_LADDER,
  SHUTTER_LADDER,
  ISO_LADDER
} from '../common/Metering';
import { ApertureMonitor, ApReading } from '../common/ApertureMonitor';

/**
 * 测光表 v10
 *
 * 布局（自上而下）：
 *   预览（屏宽 70%）
 *   变焦滑条
 *   EV 大字（当前胶片 ISO 下的 EV）| 锁定曝光
 *   测光模式 | A/S 档 | 胶片 ISO 入口
 *   曝光组合框：光圈 / 快门 两个滚轮，中间数值上下各一条线
 *   校准 EV | 曝光补偿
 */

/** 二级菜单：标题 + 数值 + 滚轮 + 完成。用 CustomDialog 而不是 bindSheet，
 *  因为 bindSheet 的拖拽手势会和滚轮抢事件，滑一下滚轮面板就关了。 */
const DIALOG_ITEM_H: number = 34;
const DIALOG_WHEEL_H: number = 102;
const SCROLLER_SPACER: number = 34;

@CustomDialog
struct WheelDialog {
  controller?: CustomDialogController;
  title: string = '';
  suffix: string = '';
  items: string[] = [];
  startIndex: number = 0;
  onPick: (i: number) => void = (i: number) => {};
  onDone: (i: number) => void = (i: number) => {};

  @State idx: number = 0;
  aboutToAppear(): void {
    this.idx = this.startIndex;
  }

  build() {
    Column({ space: 14 }) {
      Text(this.title).fontSize(16).fontColor(Color.White)
      Text(`${this.items.length > this.idx ? this.items[this.idx] : '--'}${this.suffix}`)
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
      Stack() {
        TextPicker({ range: this.items, selected: this.idx })
          .canLoop(false)
          .defaultPickerItemHeight(DIALOG_ITEM_H)
          .divider(null)
          .textStyle({ color: '#99FFFFFF', font: { size: 14 } })
          .selectedTextStyle({ color: Color.White, font: { size: 22 } })
          .disappearTextStyle({ color: '#55FFFFFF', font: { size: 12 } })
          .height(DIALOG_WHEEL_H)
          .width('100%')
          .onChange((value: string | string[], index: number | number[]) => {
            const i: number = index as number;
            this.idx = i;
            this.onPick(i);
          })

        Rect().width(30).height(2).fill(Color.White).position({ x: '8%', y: 50 })
        Rect().width(30).height(2).fill(Color.White).position({ x: '82%', y: 50 })
      }
      .width('100%')
      .height(DIALOG_WHEEL_H)
      Button('完成')
        .width('60%')
        .height(44)
        .backgroundColor('#7FB2FF')
        .fontColor('#101010')
        .onClick(() => {
          this.onDone(this.idx);
        })
    }
    .width('86%')
    .padding(20)
    .backgroundColor('#161616')
    .borderRadius(16)
    .alignItems(HorizontalAlign.Center)
  }
}

@CustomDialog
struct FocalDialog {
  controller?: CustomDialogController;
  startMm: string = '';
  startLocked: boolean = false;
  maxMm: number = 0;
  onDone: (mm: number, locked: boolean) => void = (mm: number, locked: boolean) => {};

  @State text: string = '';
  @State locked: boolean = false;

  aboutToAppear(): void {
    this.text = this.startMm;
    this.locked = this.startLocked;
  }

  build() {
    Column({ space: 16 }) {
      Text('焦距（等效 35mm）').fontSize(16).fontColor(Color.White)
      TextInput({ text: this.text, placeholder: '输入毫米数，如 50' })
        .type(InputType.Number)
        .height(46)
        .width('100%')
        .backgroundColor('#222222')
        .fontColor(Color.White)
        .placeholderColor('#66FFFFFF')
        .borderRadius(10)
        .onChange((v: string) => {
          this.text = v;
        })

      Row() {
        Column({ space: 2 }) {
          Text('锁定焦距').fontSize(14).fontColor('#EEFFFFFF')
          Text('锁定后变焦滑块不可拖动').fontSize(11).fontColor('#88FFFFFF')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.locked })
          .onChange((on: boolean) => {
            this.locked = on;
          })
      }
      .width('100%')

      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .height(44)
          .backgroundColor('#2E2E2E')
          .fontColor(Color.White)
          .onClick(() => {
            this.onDone(-1, this.locked);
          })
        Button('完成')
          .layoutWeight(1)
          .height(44)
          .backgroundColor('#7FB2FF')
          .fontColor('#101010')
          .onClick(() => {
            const v: number = Number(this.text);
            this.onDone(Number.isFinite(v) ? v : -1, this.locked);
          })
      }
      .width('100%')
    }
    .width('86%')
    .padding(20)
    .backgroundColor('#161616')
    .borderRadius(16)
    .alignItems(HorizontalAlign.Center)
  }
}

@Entry
@Component
struct Index {
  /** 启动黑屏过渡：true 时只显示启动页，后台把各项初始化跑完 */
  @State booting: boolean = true;
  @State splashAlpha: number = 1;
  @State safeTop: number = 0;
  @State safeBottom: number = 0;
  @State evText: string = '--';
  @State statusText: string = '初始化…';
  @State locked: boolean = false;
  /**
   * 「算出来的那一侧」是否已有有效读数。
   * 必须是 @State：它决定 XX 遮罩的 if 分支，之前用普通字段 lastRawEv 判断，
   * 冷启动后第一次锁定/测光时遮罩的 if 不会重算 → EV 出来了、快门/光圈还盖着 XX。
   */
  @State evKnown: boolean = false;

  // 原生变焦：zoomMin/zoomMax 来自设备（首启读一次存 preferences），zoomPos 是滑条位置 0~1000
  @State zoomMin: number = 0.55;
  @State zoomMax: number = 100;
  @State zoomRatio: number = 1.0;
  @State zoomPos: number = 0;
  @State zoomCached: boolean = false;
  /** 首启标定：1.0x 对应的等效 35mm 焦距（例如 24） */
  @State baseFocal35: number = 0;
  /** 焦距锁：锁定后变焦滑块不可拖动，且重启后保持 */
  @State zoomLocked: boolean = false;
  /** 当前光圈与镜头，来自 ApertureMonitor（API 或 EXIF） */
  @State apText: string = '光圈识别中…';
  /** 拖动变焦期间：不测光、EV 显示 XX、底部提示「测光停止」 */
  @State zooming: boolean = false;
  /** 测光进行中（按住，或双击进了连续测光） */
  @State meteringOn: boolean = false;
  /** 双击「启动测光」后的连续测光锁存状态 */
  @State meteringContinuous: boolean = false;
  @State meterX: number = 0.5;
  @State meterY: number = 0.5;
  @State meterMode: string = 'spot';
  @State matrixY: number = 0;

  // 胶片 ISO
  @State filmIso: number = 100;
  @State isoIndex: number = 12;
  /** 设置页是否打开（整页浮层，盖住主界面） */
  @State showSettings: boolean = false;
  /** 变焦模式：'normal' 真变焦 | 'compat' 裁切放大（硬件 zoom 钉在最小值） */
  @State zoomMode: string = 'normal';
  /** 兼容模式的固定光圈 / 物理焦距（首启拍一张读到后存 preferences，之后不再拍） */
  @State compatAp: number = 0;
  @State compatFocal: number = 0;

  // 曝光组合：apLocked=true 表示 A 档（锁光圈），false 表示 S 档（锁快门）
  @State apLocked: boolean = true;
  @State apIndex: number = 21;
  @State shIndex: number = 20;
  @State apLabel: string = 'f/5.6';
  @State shLabel: string = '1/125';
  @State outOfRange: boolean = false;

  // 校准 / 曝光补偿
  @State biasEv: number = 0;
  @State calibIndex: number = 50;
  @State expEv: number = 0;
  @State expIndex: number = 50;

  /** 纯档位列表（用户自己滚的那一侧用，没有空白项） */
  private apertureItems: string[] = [];
  private shutterItems: string[] = [];
  /** 两端带空白位的列表（算出来的那一侧用，超范围时停在空白档） */
  private apertureItemsComputed: string[] = [];
  private shutterItemsComputed: string[] = [];
  private isoItems: string[] = [];
  private biasItems: string[] = [];

  private xController: XComponentController = new XComponentController();
  private session: camera.PhotoSession | undefined = undefined;
  private timer: number = -1;
  private lastKey: string = '';
  private stableCount: number = 0;
  private started: boolean = false;
  private surfaceId: string = '';

  private activeDialog: CustomDialogController | undefined = undefined;

  private aeDurationUs: number = 0;
  private aeIso: number = 0;
  private lastRawEv: number = 0;

  private analyzeReceiver: image.ImageReceiver | undefined = undefined;
  private localY: number = 0;
  private refY: number = 0;
  private analyzerReady: boolean = false;
  private frameCount: number = 0;
  private lastSampleMs: number = 0;

  // 帧率统计（只用于实测：取帧流真实到达率 vs 后处理接受率）
  private previewOutput: camera.PreviewOutput | undefined = undefined;
  private analyzeOutput: camera.PreviewOutput | undefined = undefined;
  private arrivalCount: number = 0;
  private processedCount: number = 0;
  private fpsArrPrev: number = 0;
  private fpsProcPrev: number = 0;
  private fpsMs: number = 0;
  private fpsTimer: number = -1;
  private frameSnapshot: Uint8Array | undefined = undefined;
  private snapW: number = 0;
  private snapH: number = 0;
  /** 点测圈半径 / 预览宽度 的比例：屏幕尺寸固定，算一次缓存（原来每帧都查屏幕再 vp2px） */
  private ringRatioCache: number = 0;
  private enableAnalyzer: boolean = true;
  private device: camera.CameraDevice | undefined = undefined;
  private apMonitor: ApertureMonitor = new ApertureMonitor();
  /** 滑条给的目标倍率 */
  private zoomTarget: number = 1.0;
  /** 已经下发给相机的倍率（平滑逼近的当前值） */
  private zoomAnim: number = 1.0;
  private zoomAnimTimer: number = -1;
  private zoomSettleTimer: number = -1;
  private lastZoomProbeMs: number = 0;
  /** 锁定前临时取一帧用：空闲态没在取帧，sampleFrame 需要放行 */
  private lockPrep: boolean = false;
  /** 上一次「启动测光」按下的时间，用于识别双击 */
  private lastMeterTapMs: number = 0;
  /** 上一个会话锁定时的毫米数，等相机就绪后再套用 */
  private pendingLockMm: number = 0;
  // ---- 启动阶段标记：三项都完成才收黑屏 ----
  private bootStartMs: number = 0;
  private settingsLoaded: boolean = false;
  private cameraReady: boolean = false;
  private warmAndCalibDone: boolean = false;
  private bootFinished: boolean = false;
  /** setSmoothZoom 是否可用：第一次失败后就不再尝试，避免每帧抛异常 */
  private smoothZoomOk: boolean = true;

  private static readonly PREVIEW_RATIO: number = 0.75;
  private static readonly PREVIEW_WIDTH: number = 0.70;
  private static readonly APERTURE: number = 2.2;
  private static readonly RING_VP: number = 56;
  private static readonly PICKER_H: number = 90;
  private static readonly ITEM_H: number = 30;

  private static readonly PREF_NAME: string = 'meter_settings';
  private static readonly PREF_BIAS: string = 'biasEv';
  private static readonly PREF_EXP: string = 'expEv';
  private static readonly PREF_ISO: string = 'filmIso';
  private static readonly PREF_APLOCK: string = 'apLocked';
  private static readonly PREF_METER: string = 'meterMode';
  private static readonly PREF_AP: string = 'apIndex';
  private static readonly PREF_SH: string = 'shIndex';
  /** 首次启动实测到的设备变焦范围，长期保存；升级版本也不再重读 */
  private static readonly PREF_ZOOM_MIN: string = 'zoomMin';
  private static readonly PREF_ZOOM_MAX: string = 'zoomMax';
  /** 启动默认倍率 */
  private static readonly DEFAULT_ZOOM: number = 1.0;
  /** 首启标定得到的「1x 等效 35mm 焦距」 */
  private static readonly PREF_BASE_F35: string = 'baseFocal35';
  /** 焦距锁与锁定的毫米数（重启后恢复） */
  private static readonly PREF_ZOOM_LOCK: string = 'zoomLock';
  private static readonly PREF_ZOOM_MM: string = 'zoomLockMm';
  /** 变焦模式：normal = 真变焦（默认），compat = 裁切放大（v1.1 的假变焦） */
  private static readonly PREF_ZOOM_MODE: string = 'zoomMode';
  private static readonly MODE_NORMAL: string = 'normal';
  private static readonly MODE_COMPAT: string = 'compat';
  /** 兼容模式最多放到 5x（显示倍率，等于等效视场；硬件钉在变焦最小值上） */
  private static readonly COMPAT_MAX_ZOOM: number = 5;
  /** 兼容模式首启拍照读到的固定光圈 / 物理焦距，存下来后不再拍 */
  private static readonly PREF_COMPAT_AP: string = 'compatAperture';
  private static readonly PREF_COMPAT_FOCAL: string = 'compatFocal';

  /** 算出来那一侧的空白档：首尾各一个，用不同的不可见字符区分，避免 value 绑定撞车 */
  private static readonly BLANK_TOP: string = ' ';
  private static readonly BLANK_BOTTOM: string = '  ';

  private static readonly BLUE: string = '#4D9EFF';
  private static readonly LINE_ON: string = '#FFFFFF';
  private static readonly LINE_LOCKED: string = '#FF5C5C';

  aboutToAppear(): void {
    this.bootStartMs = Date.now();
    this.zoomRatio = Index.DEFAULT_ZOOM;
    this.zoomTarget = Index.DEFAULT_ZOOM;
    this.zoomAnim = Index.DEFAULT_ZOOM;
    this.zoomPos = zoomToSliderPos(this.zoomRatio, this.zoomMin, this.zoomMax);
    this.locked = false;
    this.buildWheels();
    this.applySafeArea();
    this.registerAppState();
    this.loadSettings();
    // 兜底：任何一步卡住，20 秒也放行进主界面（首启还可能要等权限弹窗）
    setTimeout(() => {
      if (!this.bootFinished) {
        console.error('[BOOT] timeout, force enter');
        this.warmAndCalibDone = true;
        this.cameraReady = true;
        this.settingsLoaded = true;
        this.maybeFinishBoot();
      }
    }, 20000);
  }

  /** 档位下标 → 滚轮显示文本（首尾各有一个空白位） */
  private apLabelFor(index: number): string {
    return (index >= 0 && index < this.apertureItems.length) ? this.apertureItems[index] : '';
  }

  private shLabelFor(index: number): string {
    return (index >= 0 && index < this.shutterItems.length) ? this.shutterItems[index] : '';
  }

  private buildWheels(): void {
    this.apertureItems = APERTURE_LADDER.map((v: number) => `f/${v}`);
    this.shutterItems = SHUTTER_LADDER.map((v: number) => formatShutterSecond(v));
    this.apertureItemsComputed = [Index.BLANK_TOP]
      .concat(this.apertureItems).concat([Index.BLANK_BOTTOM]);
    this.shutterItemsComputed = [Index.BLANK_TOP]
      .concat(this.shutterItems).concat([Index.BLANK_BOTTOM]);
    this.isoItems = ISO_LADDER.map((v: number) => `${v}`);
    const bias: string[] = [];
    for (let i = 0; i <= 100; i++) {
      const v: number = (i - 50) / 10;
      bias.push(`${v > 0 ? '+' : ''}${v.toFixed(1)}`);
    }
    this.biasItems = bias;
    this.isoIndex = Math.max(0, ISO_LADDER.indexOf(100));
    this.filmIso = ISO_LADDER[this.isoIndex];
    this.apIndex = Math.max(0, APERTURE_LADDER.indexOf(5.6));
    this.shIndex = Math.max(0, SHUTTER_LADDER.indexOf(1 / 125));
    this.apLabel = this.apLabelFor(this.apIndex);
    this.shLabel = this.shLabelFor(this.shIndex);
  }

  /** 全屏布局下自己留出状态栏/导航栏高度 */
  private async applySafeArea(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win = await window.getLastWindow(ctx);
      const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const nav = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      this.safeTop = px2vp(sys.topRect.height);
      this.safeBottom = px2vp(nav.bottomRect.height);
    } catch (e) {
      this.safeTop = 36;
      this.safeBottom = 20;
    }
  }

  private async loadSettings(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const store = await preferences.getPreferences(ctx, Index.PREF_NAME);

      const bias = await store.get(Index.PREF_BIAS, 0) as number;
      if (typeof bias === 'number' && Number.isFinite(bias)) {
        this.biasEv = Math.round(bias * 10) / 10;
        this.calibIndex = Math.round(this.biasEv * 10) + 50;
      }
      const exp = await store.get(Index.PREF_EXP, 0) as number;
      if (typeof exp === 'number' && Number.isFinite(exp)) {
        this.expEv = Math.round(exp * 10) / 10;
        this.expIndex = Math.round(this.expEv * 10) + 50;
      }
      const iso = await store.get(Index.PREF_ISO, 100) as number;
      const isoIdx = ISO_LADDER.indexOf(iso as number);
      if (isoIdx >= 0) {
        this.isoIndex = isoIdx;
        this.filmIso = ISO_LADDER[isoIdx];
      }
      const base = await store.get(Index.PREF_BASE_F35, 0) as number;
      if (typeof base === 'number' && Number.isFinite(base) && base > 0) {
        this.baseFocal35 = base;
        console.info(`[BASE] loaded f35@1x=${base}mm`);
      }

      const zl = await store.get(Index.PREF_ZOOM_LOCK, false) as boolean;
      this.zoomLocked = zl === true;
      const zmm = await store.get(Index.PREF_ZOOM_MM, 0) as number;
      if (typeof zmm === 'number' && Number.isFinite(zmm) && zmm > 0) {
        this.pendingLockMm = zmm;
      }
      console.info(`[SETTINGS] zoomLock=${this.zoomLocked} mm=${this.pendingLockMm}`);

      const locked = await store.get(Index.PREF_APLOCK, true) as boolean;
      this.apLocked = locked;

      const mode = await store.get(Index.PREF_METER, 'spot') as string;
      this.meterMode = mode === 'matrix' ? 'matrix' : 'spot';

      const zm = await store.get(Index.PREF_ZOOM_MODE, Index.MODE_NORMAL) as string;
      this.zoomMode = zm === Index.MODE_COMPAT ? Index.MODE_COMPAT : Index.MODE_NORMAL;
      const cap = await store.get(Index.PREF_COMPAT_AP, 0) as number;
      if (typeof cap === 'number' && Number.isFinite(cap) && cap > 0) {
        this.compatAp = cap;
      }
      const cfocal = await store.get(Index.PREF_COMPAT_FOCAL, 0) as number;
      if (typeof cfocal === 'number' && Number.isFinite(cfocal) && cfocal > 0) {
        this.compatFocal = cfocal;
      }
      console.info(`[SETTINGS] zoomMode=${this.zoomMode} compatAp=${this.compatAp}`);

      const ap = await store.get(Index.PREF_AP, this.apIndex) as number;
      if (ap >= 0 && ap < APERTURE_LADDER.length) {
        this.apIndex = ap;
        this.apLabel = this.apLabelFor(ap);
      }
      const sh = await store.get(Index.PREF_SH, this.shIndex) as number;
      if (sh >= 0 && sh < SHUTTER_LADDER.length) {
        this.shIndex = sh;
        this.shLabel = this.shLabelFor(sh);
      }
      console.info(`[SETTINGS] loaded bias=${this.biasEv} exp=${this.expEv} iso=${this.filmIso} ` +
        `A=${this.apLocked} mode=${this.meterMode} ap=${this.apIndex} sh=${this.shIndex}`);
      this.settingsLoaded = true;
      this.refreshDisplay();
      this.maybeFinishBoot();
    } catch (e) {
      console.error('[SETTINGS] load failed');
      this.settingsLoaded = true;
      this.maybeFinishBoot();
    }
  }

  private async savePref(key: string, value: number | string | boolean): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const store = await preferences.getPreferences(ctx, Index.PREF_NAME);
      await store.put(key, value);
      await store.flush();
    } catch (e) {
      console.error(`[SETTINGS] save ${key} failed`);
    }
  }

  // ---------------- 原生变焦（v1.2） ----------------

  /**
   * 首次启动读设备变焦范围并存 preferences，之后永远用存下来的这份：
   * 需求明确「更新版本也不需要再读一次」，也让同一台机器上的滑条刻度和手感保持一致。
   */
  private async initZoomRange(s: camera.PhotoSession, applyDefault: boolean): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const store = await preferences.getPreferences(ctx, Index.PREF_NAME);
      const savedMin = await store.get(Index.PREF_ZOOM_MIN, 0) as number;
      const savedMax = await store.get(Index.PREF_ZOOM_MAX, 0) as number;
      if (savedMin > 0 && savedMax > savedMin) {
        this.zoomMin = savedMin;
        this.zoomMax = savedMax;
        this.zoomCached = true;
        console.info(`[ZOOM] range from cache ${savedMin}~${savedMax}`);
      } else {
        let range: number[] = [];
        try {
          range = s.getZoomRatioRange();
        } catch (e) {
          range = [];
          console.error(`[ZOOM] getZoomRatioRange failed ${(e as BusinessError).code}`);
        }
        if (range.length >= 2 && range[1] > range[0]) {
          this.zoomMin = range[0];
          this.zoomMax = range[1];
          store.put(Index.PREF_ZOOM_MIN, this.zoomMin);
          store.put(Index.PREF_ZOOM_MAX, this.zoomMax);
          store.flush();
          console.info(`[ZOOM] range probed ${this.zoomMin}~${this.zoomMax}`);
        } else {
          this.zoomMin = 1;
          this.zoomMax = 1;
          console.error('[ZOOM] device reported no usable range, locked to 1x');
        }
      }
      // 兼容模式：没锁焦段时和普通模式一样默认 1.0x，锁了焦段就回到锁定的那一档
      const def: number = this.isCompat() ? this.compatDefaultRatio() : Index.DEFAULT_ZOOM;
      const target: number = applyDefault ? def : this.zoomRatio;
      this.zoomRatio = Math.min(this.zoomUiMax(), Math.max(this.zoomMin, target));
      this.zoomPos = zoomToSliderPos(this.zoomRatio, this.zoomMin, this.zoomUiMax());
      console.info(`[ZOOM] ${applyDefault ? 'default' : 'resume'} ${this.zoomRatio} pos=${this.zoomPos} ` +
        `cached=${this.zoomCached} min=${this.zoomMin} max=${this.zoomMax}`);
    } catch (e) {
      this.zoomMin = 1;
      this.zoomMax = 1;
      console.error('[ZOOM] init failed');
    }
  }

  // ---------------- 变焦模式（普通 = 真变焦 / 兼容 = 裁切放大） ----------------

  private isCompat(): boolean {
    return this.zoomMode === Index.MODE_COMPAT;
  }

  /** 滑条与换算用的倍率上限：兼容模式锁到 5x（显示倍率 = 等效视场倍数） */
  private zoomUiMax(): number {
    return this.isCompat() ? Math.min(Index.COMPAT_MAX_ZOOM, this.zoomMax) : this.zoomMax;
  }

  /**
   * 兼容模式的裁切倍数（1 = 不裁）。
   * 硬件钉在最小倍率（超广角），显示倍率与它的比值就是画面要放大的倍数。
   */
  private cropScale(): number {
    if (!this.isCompat() || !(this.zoomMin > 0) || !(this.zoomRatio > 0)) {
      return 1;
    }
    return Math.max(1, this.zoomRatio / this.zoomMin);
  }

  /** 真正下发给相机的倍率：兼容模式永远钉在变焦最小值上 */
  private hwZoomOf(ratio: number): number {
    return this.isCompat() ? this.zoomMin : ratio;
  }

  /**
   * 兼容模式启动时的显示倍率：
   *   - 没锁焦段 → 1.0x（和普通模式一样，等效 24mm）；
   *   - 锁了焦段 → 用存下来的毫米数换算，下次启动停在同一焦段。
   */
  private compatDefaultRatio(): number {
    let ratio: number = 1.0;
    if (this.zoomLocked && this.pendingLockMm > 0 && this.baseFocal35 > 0) {
      ratio = this.pendingLockMm / this.baseFocal35;
    }
    return Math.min(this.zoomUiMax(), Math.max(this.zoomMin, ratio));
  }

  /** EV 用的光圈：兼容模式用「首启读一次存下来」的常量，普通模式走 0.5s 轮询 */
  private meteringAperture(): number {
    if (this.isCompat() && this.compatAp > 0) {
      return this.compatAp;
    }
    return this.apMonitor.aperture();
  }

  /** 光圈文案：兼容模式是常量，普通模式由 ApertureMonitor 回调维护 */
  private updateApText(): void {
    if (!this.isCompat()) {
      return;
    }
    if (this.compatAp > 0) {
      this.apText = `兼容模式 · 固定光圈 f/${this.compatAp.toFixed(1)}` +
        (this.compatFocal > 0 ? ` · 物理焦距 ${this.compatFocal.toFixed(1)}mm` : '');
    } else {
      this.apText = '兼容模式 · 光圈读取中…';
    }
  }

  /** 真正下发给相机会话；失败不改状态，避免 UI 和相机的倍率对不上 */
  private applyZoom(ratio: number): void {
    const clamped: number = Math.min(this.zoomUiMax(), Math.max(this.zoomMin, ratio));
    this.zoomRatio = clamped;
    const s = this.session;
    if (!s) {
      return;
    }
    const hw: number = this.hwZoomOf(clamped);
    try {
      s.setZoomRatio(hw);
      console.info(`[ZOOM] apply ${clamped.toFixed(2)}x (hw ${hw.toFixed(2)}x)`);
    } catch (e) {
      console.error(`[ZOOM] setZoomRatio(${hw}) failed ${(e as BusinessError).code}`);
    }
  }

  /**
   * 拖动时用 setSmoothZoom（系统贝塞尔平滑过渡）而不是 setZoomRatio 硬切：
   * 硬切在拖动中每 100ms 塞一条，队列一堆积画面就是「一顿一顿」。
   * 厂商若没实现这个接口会抛错，第一次失败就永久退回 setZoomRatio。
   */
  /** 拖动中的每一步：直接设倍率，立即生效（系统平滑变焦本机固定 433ms，连续重定向会滞后半秒） */
  private applyZoomDirect(ratio: number): void {
    if (this.isCompat()) {
      // 兼容模式只改裁切，相机倍率不动
      return;
    }
    const clamped: number = Math.min(this.zoomMax, Math.max(this.zoomMin, ratio));
    const s = this.session;
    if (!s || this.locked || this.zoomLocked) {
      return;
    }
    try {
      s.setZoomRatio(clamped);
    } catch (e) {
      console.error(`[ZOOM] setZoomRatio(${clamped}) failed E${(e as BusinessError).code}`);
    }
  }

  private applyZoomSmooth(ratio: number): void {
    if (this.isCompat()) {
      // 兼容模式没有相机过渡可走，裁切是即时的
      return;
    }
    const clamped: number = Math.min(this.zoomMax, Math.max(this.zoomMin, ratio));
    const s = this.session;
    if (!s) {
      return;
    }
    if (this.locked) {
      // 锁定态只记录目标倍率，解锁时 applyZoom 统一恢复
      return;
    }
    if (this.smoothZoomOk) {
      try {
        s.setSmoothZoom(clamped, camera.SmoothZoomMode.NORMAL);
        return;
      } catch (e) {
        this.smoothZoomOk = false;
        console.error(`[ZOOM] setSmoothZoom failed E${(e as BusinessError).code} -> 退回 setZoomRatio`);
      }
    }
    try {
      s.setZoomRatio(clamped);
    } catch (e) {
      console.error(`[ZOOM] setZoomRatio(${clamped}) failed E${(e as BusinessError).code}`);
    }
  }

  /**
   * 滑条拖动：setZoomRatio 是异步的，每帧都下发会堆积，所以移动中限流 80ms，
   * 松手（End）和点击（Click）时一定补发一次最终值。
   */
  /**
   * 滑条只负责给「目标倍率」，真正的下发交给 zoomTick() 以小步长逼近。
   *
   * 为什么不直接把目标甩给相机：
   *   - setZoomRatio 一步到位 → 画面是跳的（不顺）；
   *   - setSmoothZoom 直接给大目标 → 系统按距离给 400~900ms 的过渡，连续重定向就整体滞后。
   * 所以每 60ms 只推进剩余距离的一小部分（对数空间 25%），每次都是「短距离 + 短过渡」，
   * 系统平滑曲线能跑完，画面连续又跟手。
   */
  /**
   * 首启标定：在 1.0x 下拍几张，取其中最大的等效 35mm 焦距作为「1x 基准」。
   * 取最大值是为了避开近距离时手机自动切超广角（那会读到 13mm 这种偏小值）。
   * 只在 preferences 里没有基准时跑一次，之后永远用缓存。
   */
  private async calibrateBaseFocal35(): Promise<void> {
    if (this.baseFocal35 > 0 || this.locked || this.meteringOn || this.isCompat()) {
      // 兼容模式硬件钉在最小值，不做 1.0x 标定（等效焦距由首启那张照片反推，见 deriveBaseFocal35）
      return;
    }
    try {
      this.applyZoom(1.0);
      this.zoomTarget = 1.0;
      this.zoomAnim = 1.0;
      await this.sleepMs(700);
      // 首启时相机会话刚起，前几次 capture 常被拒，所以重试到拿到 2 个样本为止（最多 6 秒）
      const samples: number[] = [];
      const deadline: number = Date.now() + 5000;
      while (samples.length < 2 && Date.now() < deadline) {
        const got: number[] = await this.apMonitor.sampleFocal35(1, 0);
        if (got.length > 0) {
          samples.push(got[0]);
        }
        await this.sleepMs(500);
      }
      let best: number = 0;
      for (const v of samples) {
        if (v >= 12 && v <= 100 && v > best) {
          best = v;
        }
      }
      if (best > 0) {
        this.baseFocal35 = best;
        this.apMonitor.noteWarmed();
        if (this.zoomLocked && this.pendingLockMm > 0) {
          this.applyFocalMm(this.pendingLockMm);
        }
        this.savePref(Index.PREF_BASE_F35, best);
        console.info(`[BASE] calibrated f35@1x=${best}mm`);
      } else {
        console.error('[BASE] calibration failed, will retry next launch');
      }
    } catch (e) {
      console.error(`[BASE] calibration error E${(e as BusinessError).code}`);
    }
  }

  /** 点击焦距文案：弹出二级页，手动输入毫米数 + 焦距锁 */
  private openFocalDialog(): void {
    const mm: number = this.baseFocal35 > 0 ? Math.round(this.baseFocal35 * this.zoomRatio) : 0;
    const startLocked: boolean = this.zoomLocked;
    const dlg = new CustomDialogController({
      builder: FocalDialog({
        startMm: mm > 0 ? `${mm}` : '',
        startLocked: startLocked,
        onDone: (v: number, locked: boolean) => {
          this.closeDialog();
          if (v === -1) {
            // 取消：丢弃输入，锁状态也不改
            return;
          }
          this.zoomLocked = locked;
          this.savePref(Index.PREF_ZOOM_LOCK, locked);
          if (v > 0) {
            this.applyFocalMm(v);
          }
          const cur: number = this.baseFocal35 > 0 ? Math.round(this.baseFocal35 * this.zoomRatio) : 0;
          this.savePref(Index.PREF_ZOOM_MM, locked ? cur : 0);
          console.info(`[ZOOM] focal set ${v}mm -> ${this.zoomRatio.toFixed(2)}x lock=${locked}`);
        }
      }),
      autoCancel: true,
      customStyle: true,
      alignment: DialogAlignment.Center
    });
    this.activeDialog = dlg;
    dlg.open();
  }

  /** 把等效 35mm 毫米数换算成倍率并立刻下发 */
  private applyFocalMm(mm: number): void {
    if (!(this.baseFocal35 > 0) || !(mm > 0)) {
      return;
    }
    const ratio: number = Math.min(this.zoomUiMax(), Math.max(this.zoomMin, mm / this.baseFocal35));
    this.zoomTarget = ratio;
    this.zoomAnim = ratio;
    this.zoomRatio = ratio;
    this.zoomPos = zoomToSliderPos(ratio, this.zoomMin, this.zoomUiMax());
    this.applyZoom(ratio);
  }

  /** 当前倍率对应的等效 35mm 焦距文案 */
  private zoomCaption(): string {
    const z: string = formatZoom(this.zoomRatio);
    if (!(this.baseFocal35 > 0)) {
      return z;
    }
    return `${z}·${Math.round(this.baseFocal35 * this.zoomRatio)}mm`;
  }

  private onZoomSlider(v: number, mode: SliderChangeMode): void {
    this.zoomTarget = sliderPosToZoom(v, this.zoomMin, this.zoomUiMax());
    this.beginZooming();

    if (mode === SliderChangeMode.Click) {
      // 点轨道跳档：这里才用系统的平滑变焦（本机固定 433ms 过渡），一次性动画，不用跟手
      this.zoomAnim = this.zoomTarget;
      if (this.isCompat()) {
        // 兼容模式裁切即时生效，不用等相机过渡
        this.zoomRatio = this.zoomTarget;
        this.applyZoomSmooth(this.zoomTarget);
        this.scheduleZoomSettle(150);
        return;
      }
      this.applyZoomSmooth(this.zoomTarget);
      this.scheduleZoomSettle(700);
      return;
    }

    this.startZoomAnimator();
    const released: boolean = mode === SliderChangeMode.End;
    this.scheduleZoomSettle(released ? 200 : 400);
  }

  private startZoomAnimator(): void {
    if (this.zoomAnimTimer !== -1) {
      return;
    }
    this.zoomAnimTimer = setInterval(() => {
      this.zoomTick();
    }, 60);
  }

  private stopZoomAnimator(): void {
    if (this.zoomAnimTimer !== -1) {
      clearInterval(this.zoomAnimTimer);
      this.zoomAnimTimer = -1;
    }
  }

  private zoomTick(): void {
    const target: number = this.zoomTarget;
    const current: number = this.zoomAnim;
    if (this.session === undefined) {
      // 会话没了就别再逼近，直接对齐，免得 endZooming 一直等下去
      this.zoomAnim = target;
      this.zoomRatio = target;
      this.stopZoomAnimator();
      return;
    }
    if (!(target > 0) || !(current > 0)) {
      return;
    }
    const gap: number = Math.abs(Math.log2(target / current));
    if (gap < 0.01) {
      this.zoomAnim = target;
      this.zoomRatio = target;
      this.stopZoomAnimator();
      return;
    }
    // 对数空间插值：每步吃掉剩余行程的 20%，步长小 → 系统给的过渡时长短、画面更连续
    const next: number = current * Math.pow(target / current, 0.25);
    this.zoomAnim = next;
    this.zoomRatio = next;
    this.applyZoomDirect(next);
  }

  private zoomAnimating(): boolean {
    const target: number = this.zoomTarget;
    const current: number = this.zoomAnim;
    if (!(target > 0) || !(current > 0)) {
      return false;
    }
    return Math.abs(Math.log2(target / current)) >= 0.01;
  }

  /**
   * 两路 preview 都钉在 30fps。
   *
   * 教训：曾经「不测光就把后台取帧降到 5fps」来省电/省带宽，结果显示预览也跟着变成 5fps ——
   * 同一 session 里的 preview 输出共享一个帧率档，调低任何一路都会把整条流拖慢。
   * 所以帧率永远保持 30；不测光时只是「不处理」帧，而不是让相机少出帧。
   */
  /** 后台取帧开关：不测光时把这一路 stop 掉，省出带宽给显示预览 */
  private setAnalyzerStream(on: boolean): void {
    const a = this.analyzeOutput;
    if (a === undefined) {
      return;
    }
    try {
      if (on) {
        a.start().then(() => {
          console.info('[ANA] stream start');
        }).catch((err: BusinessError) => {
          console.error(`[ANA] stream start failed E${err.code}`);
        });
      } else {
        a.stop().then(() => {
          console.info('[ANA] stream stop');
        }).catch((err: BusinessError) => {
          if (err.code === 7400201) {
            console.info('[ANA] stream stop skipped (session already stopped)');
          } else {
            console.error(`[ANA] stream stop failed E${err.code}`);
          }
        });
      }
    } catch (e) {
      console.error(`[ANA] stream toggle failed E${(e as BusinessError).code}`);
    }
  }

  private pinPreviewFrameRate(): void {
    try {
      const p = this.previewOutput;
      if (p !== undefined) {
        p.setFrameRate(30, 30);
      }
    } catch (e) {
      // 会话刚起时偶发 7400101，隔 500ms 再钉一次
      console.info(`[FPS] display setFrameRate busy E${(e as BusinessError).code}, retry`);
      setTimeout(() => {
        try {
          const p2 = this.previewOutput;
          if (p2 !== undefined) {
            p2.setFrameRate(30, 30);
            console.info(`[FPS] display setFrameRate retry ok -> ${this.rateText(p2)}`);
          }
        } catch (e2) {
          console.error(`[FPS] display setFrameRate retry failed E${(e2 as BusinessError).code}`);
        }
      }, 500);
    }
    try {
      const a = this.analyzeOutput;
      if (a !== undefined) {
        a.setFrameRate(30, 30);
      }
    } catch (e) {
      console.error(`[FPS] analyze setFrameRate failed E${(e as BusinessError).code}`);
    }
    console.info(`[FPS] pinned preview=${this.rateText(this.previewOutput)} ` +
      `analyze=${this.rateText(this.analyzeOutput)}`);
  }

  /** 算出来的那一侧（A 档的快门 / S 档的光圈）是否有确定值 */
  private computedKnown(): boolean {
    if (this.zooming) {
      return false;
    }
    if (!(this.meteringOn || this.locked)) {
      return false;
    }
    // 用 @State 的 evKnown，别用普通字段 lastRawEv：后者变了不会触发 XX 遮罩重算
    return this.evKnown;
  }

  /** 唯一的 EV 写入口：顺带更新 @State 的 evKnown，保证 XX 遮罩能跟着刷新 */
  private setRawEv(v: number): void {
    this.lastRawEv = v;
    this.evKnown = v > 0;
  }

  private sleepMs(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /**
   * 锁定前先弄到一帧可用数据。
   * 空闲态取帧流是停的、也不处理帧，直接 remeter 会因为没有快照/refY 而算不出东西。
   */
  private async prefetchFrame(): Promise<void> {
    if (this.frameSnapshot !== undefined && this.refY > 2) {
      console.info('[LOCK] prefetch skipped: snapshot ready');
      return;
    }
    const before: number = this.frameCount;
    this.lockPrep = true;
    this.setAnalyzerStream(true);
    const deadline: number = Date.now() + 900;
    while (Date.now() < deadline) {
      await this.sleepMs(60);
      if (this.frameCount > before && this.refY > 2 && this.frameSnapshot !== undefined) {
        break;
      }
    }
    this.lockPrep = false;
    console.info(`[LOCK] prefetch +${this.frameCount - before}帧 refY=${this.refY.toFixed(1)}`);
  }

  /** 按下：双击 = 切换连续测光；单击 = 按住测光 */
  private onMeterButtonDown(): void {
    if (this.locked) {
      return;
    }
    const now: number = Date.now();
    console.info(`[METER] tap gap=${this.lastMeterTapMs === 0 ? -1 : now - this.lastMeterTapMs}ms`);
    if (now - this.lastMeterTapMs < 420) {
      this.lastMeterTapMs = 0;
      this.toggleContinuousMeter();
      return;
    }
    this.lastMeterTapMs = now;
    if (!this.meteringContinuous) {
      this.startLiveMeter();
    }
  }

  /** 抬起：连续测光锁存着就不停 */
  private onMeterButtonUp(): void {
    if (this.meteringContinuous) {
      return;
    }
    this.stopLiveMeter();
  }

  private toggleContinuousMeter(): void {
    this.meteringContinuous = !this.meteringContinuous;
    if (this.meteringContinuous) {
      this.startLiveMeter();
      this.statusText = '连续测光中（双击退出）';
      console.info('[METER] continuous on');
    } else {
      this.stopLiveMeter();
      this.statusText = '待测光（按住启动测光）';
      console.info('[METER] continuous off');
    }
  }

  /** 按住「启动测光」：开始轮询拍照 + 处理后端取帧 */
  private startLiveMeter(): void {
    if (this.locked || this.meteringOn) {
      return;
    }
    this.meteringOn = true;
    this.statusText = '测光中…';
    this.setAnalyzerStream(true);
    if (!this.isCompat()) {
      // 兼容模式光圈是常量、不用轮询拍照，只要取帧算亮度
      this.apMonitor.setPollInterval(400);
      setTimeout(() => {
        if (!this.meteringOn) {
          return;
        }
        if (this.apMonitor.isWarmed()) {
          this.apMonitor.startPolling();
        } else {
          this.apMonitor.warmUp().then(() => {
            if (this.meteringOn) {
              this.apMonitor.startPolling();
            }
          });
        }
      }, 180);
    }
    this.readOnce();
    console.info('[METER] live start');
  }

  /** 松手：停拍、停处理、结果清成 XX */
  private stopLiveMeter(): void {
    if (!this.meteringOn) {
      return;
    }
    this.meteringOn = false;
    this.apMonitor.stopPolling();
    this.setAnalyzerStream(false);
    this.evText = 'XX';
    this.statusText = '待测光（按住启动测光）';
    console.info('[METER] live stop');
  }

  /**
   * 启动阶段收黑屏：设置读完 + 相机会话起来 + 热机/首启标定跑完，三件事齐了才放行。
   * 任一项卡住超过 9 秒也会强制放行（见 aboutToAppear 的兜底计时器）。
   */
  private maybeFinishBoot(): void {
    if (this.bootFinished) {
      return;
    }
    if (!this.settingsLoaded || !this.cameraReady || !this.warmAndCalibDone) {
      return;
    }
    // 最短黑屏 450ms，避免一闪而过
    const elapsed: number = Date.now() - this.bootStartMs;
    if (elapsed < 450) {
      setTimeout(() => {
        this.maybeFinishBoot();
      }, 450 - elapsed + 10);
      return;
    }
    this.bootFinished = true;
    console.info(`[BOOT] ready in ${Date.now() - this.bootStartMs}ms`);
    animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
      this.splashAlpha = 0;
    });
    setTimeout(() => {
      this.booting = false;
    }, 240);
  }

  /** 启动阶段的热机 + 首启焦距标定 */
  private async runStartupWarmup(): Promise<void> {
    try {
      if (this.isCompat()) {
        // 兼容模式：硬件钉在变焦最小值，光圈只在首启拍一张读出来，之后启动不再拍
        this.warmAndCalibDone = true;
        this.maybeFinishBoot();
        // 硬件钉在最小值，但显示倍率保持启动时定下的（没锁焦段 = 1.0x，锁了就按锁定的毫米数）
        this.applyZoom(this.zoomRatio);
        this.zoomTarget = this.zoomRatio;
        this.zoomAnim = this.zoomRatio;
        this.zoomPos = zoomToSliderPos(this.zoomRatio, this.zoomMin, this.zoomUiMax());
        // 设置可能比相机会话后到，这里再兜一次「锁定的焦段」（幂等）
        if (this.zoomLocked && this.pendingLockMm > 0 && this.baseFocal35 > 0) {
          this.applyFocalMm(this.pendingLockMm);
        }
        await this.ensureCompatAperture();
        return;
      }
      if (this.baseFocal35 === 0 && !this.locked && !this.meteringOn) {
        // 首启：标定本身就要连拍几张，等于同时把管道热起来了，不用再多一次空拍
        await this.calibrateBaseFocal35();
        this.warmAndCalibDone = true;
        this.maybeFinishBoot();
        return;
      }
      // 非首启：相机可用就算启动完成，热机是后台维护，不占用黑屏时间
      this.warmAndCalibDone = true;
      this.maybeFinishBoot();
      await this.sleepMs(1200);
      if (!this.apMonitor.isWarmed()) {
        await this.apMonitor.warmUp();
        if (!this.apMonitor.isWarmed()) {
          await this.sleepMs(700);
          await this.apMonitor.warmUp();
        }
      }
    } catch (e) {
      console.error(`[BOOT] warmup error E${(e as BusinessError).code}`);
    } finally {
      this.warmAndCalibDone = true;
      this.maybeFinishBoot();
    }
  }

  /**
   * 兼容模式的光圈：只读一次。
   * 硬件已钉在变焦最小值（超广角），光圈不会再变，所以首启拍一张读 EXIF 存进 preferences，
   * 之后每次启动直接用缓存，不再拍照（也不用 0.5s 轮询）。
   */
  private async ensureCompatAperture(): Promise<void> {
    if (this.compatAp > 0) {
      this.updateApText();
      return;
    }
    const s = this.session;
    if (!s) {
      return;
    }
    try {
      // setZoomRatio 是异步的（实测要 ~1 秒才真正切到超广角），等它到位再拍，
      // 否则会读到主摄的 f/2.0（物理焦距 5.8mm），光圈就固定错了
      await this.sleepMs(900);
      let actual: number = 0;
      try {
        actual = s.getZoomRatio();
      } catch (e) {
        actual = -1;
      }
      console.info(`[COMPAT] hw zoom before aperture read = ${actual}x (want ${this.zoomMin})`);

      for (let i = 0; i < 3 && this.compatAp <= 0; i++) {
        if (!this.apMonitor.isWarmed()) {
          await this.apMonitor.warmUp();
        }
        // 两次 capture 至少隔 500ms，否则相机直接拒（7400102）
        await this.sleepMs(600);
        await this.apMonitor.shootNow();
        const r: ApReading | undefined = this.apMonitor.reading();
        if (r === undefined) {
          console.error(`[COMPAT] aperture read empty (try ${i + 1})`);
          continue;
        }
        this.compatAp = r.aperture;
        this.compatFocal = r.focal;
        this.savePref(Index.PREF_COMPAT_AP, r.aperture);
        this.savePref(Index.PREF_COMPAT_FOCAL, r.focal);
        this.deriveBaseFocal35(r);
        console.info(`[COMPAT] fixed aperture f/${r.aperture} focal=${r.focal}mm ` +
          `f35=${r.focal35} zoom=${this.zoomMin}`);
      }
      if (this.compatAp <= 0) {
        console.error('[COMPAT] aperture read failed, fallback f/2.2');
      }
    } catch (e) {
      console.error(`[COMPAT] aperture read error E${(e as BusinessError).code}`);
    }
    this.updateApText();
    this.refreshDisplay();
  }

  /**
   * 兼容模式跳过 1.0x 的焦距标定（硬件钉在最小值），
   * 用同一张照片的 FocalLengthIn35mmFilm 反推「1x 等效焦距」，界面上的 mm 才不会空着。
   */
  private deriveBaseFocal35(r: ApReading): void {
    if (this.baseFocal35 > 0 || !(r.focal35 > 0) || !(this.zoomMin > 0)) {
      return;
    }
    const base: number = Math.round(r.focal35 / this.zoomMin);
    if (base < 12 || base > 100) {
      return;
    }
    this.baseFocal35 = base;
    this.savePref(Index.PREF_BASE_F35, base);
    console.info(`[COMPAT] base f35@1x≈${base}mm (from ${r.focal35}mm @ ${this.zoomMin}x)`);
    // 首启就锁着焦段的情况：基准刚算出来，把锁定的毫米数补上
    if (this.zoomLocked && this.pendingLockMm > 0) {
      this.applyFocalMm(this.pendingLockMm);
    }
  }

  /**
   * 进入变焦态：变焦过程中读数不可靠，所以干脆停测光——
   * 停 EXIF 轮询、EV 显示 XX、底部写「测光停止」，后处理也不再算亮度。
   */
  private beginZooming(): void {
    if (this.zoomSettleTimer !== -1) {
      clearTimeout(this.zoomSettleTimer);
      this.zoomSettleTimer = -1;
    }
    if (this.zooming) {
      return;
    }
    this.zooming = true;
    this.apMonitor.stopPolling();
    this.evText = 'XX';
    this.statusText = this.meteringOn ? '测光停止' : '变焦中…';
    console.info('[ZOOM] metering paused');
  }

  private scheduleZoomSettle(delay: number): void {
    if (this.zoomSettleTimer !== -1) {
      clearTimeout(this.zoomSettleTimer);
    }
    this.zoomSettleTimer = setTimeout(() => {
      this.zoomSettleTimer = -1;
      this.endZooming();
    }, delay);
  }

  /** 停稳后立刻补拍一张拿光圈，再恢复轮询与测光 */
  private async endZooming(): Promise<void> {
    if (!this.zooming) {
      return;
    }
    if (this.zoomAnimating()) {
      // 平滑变焦还没走完，等它收敛再补测，否则测的是中间倍率
      this.scheduleZoomSettle(120);
      return;
    }
    // 兼容模式的裁切变了，给相机的测光点也要跟着挪
    this.updateMeterPoint();
    if (this.locked) {
      // 锁定态不拍照（session 已停），直接用锁定帧重算，避免 EV 卡在 XX
      this.zooming = false;
      this.remeter();
      this.statusText = '画面与曝光已锁定';
      console.info('[ZOOM] metering resumed (locked)');
      return;
    }
    if (!this.meteringOn) {
      // 空闲态变焦：不拍照、不轮询、不出数，滑条停稳就结束
      this.zooming = false;
      this.evText = 'XX';
      this.statusText = '待测光（按住启动测光）';
      console.info('[ZOOM] idle zoom settled');
      return;
    }
    // 补测期间继续显示 XX：等这张 EXIF 回来才算测光恢复，否则会先拿旧光圈显示一帧
    if (this.isCompat()) {
      // 兼容模式光圈是常量，变焦只是裁切，不用补拍
      this.zooming = false;
      this.readOnce();
      console.info('[ZOOM] compat zoom settled');
      return;
    }
    this.statusText = '补测…';
    await this.apMonitor.shootNow();
    this.zooming = false;
    this.apMonitor.startPolling();
    this.readOnce();
    console.info('[ZOOM] metering resumed');
  }

  /** 退出/切后台前把当前状态记下来 */
  private saveState(): void {
    this.savePref(Index.PREF_BIAS, this.biasEv);
    this.savePref(Index.PREF_EXP, this.expEv);
    this.savePref(Index.PREF_ISO, this.filmIso);
    this.savePref(Index.PREF_APLOCK, this.apLocked);
    this.savePref(Index.PREF_METER, this.meterMode);
    this.savePref(Index.PREF_AP, this.apIndex);
    this.savePref(Index.PREF_SH, this.shIndex);
    this.savePref(Index.PREF_ZOOM_LOCK, this.zoomLocked);
    this.savePref(Index.PREF_ZOOM_MODE, this.zoomMode);
    const curMm: number = this.baseFocal35 > 0 ? Math.round(this.baseFocal35 * this.zoomRatio) : 0;
    this.savePref(Index.PREF_ZOOM_MM, this.zoomLocked ? curMm : 0);
    console.info(`[SETTINGS] state saved A=${this.apLocked} ap=${this.apIndex} sh=${this.shIndex}`);
  }

  private registerAppState(): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      ctx.getApplicationContext().on('applicationStateChange', {
        onApplicationForeground: () => {
          if (!this.session && this.surfaceId.length > 0) {
            this.reopenCamera();
          }
        },
        onApplicationBackground: () => {
          this.saveState();
          this.shutdown();
        }
      });
    } catch (e) {
      console.error('[APP] register state listener failed');
    }
  }

  private async reopenCamera(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const ok = await this.ensurePermission(ctx);
      if (!ok) {
        this.statusText = '未授予相机权限';
        return;
      }
      this.started = true;
      await this.openCamera(ctx, this.surfaceId, true);

      if (this.locked) {
        const s = this.session;
        if (s) {
          try {
            s.setExposureMode(camera.ExposureMode.EXPOSURE_MODE_LOCKED);
            await s.stop();
            this.statusText = '画面与曝光已锁定（已恢复）';
          } catch (e) {
            console.error('[APP] restore lock failed');
          }
        }
      }
    } catch (e) {
      console.error(`[APP] reopen failed ${(e as BusinessError).code}`);
    }
  }

  aboutToDisappear(): void {
    this.saveState();
    this.shutdown();
  }

  /** 系统返回：设置页开着就先退出设置页，别直接退应用 */
  onBackPress(): boolean {
    if (this.showSettings) {
      this.closeSettings();
      return true;
    }
    return false;
  }

  private shutdown(): void {
    this.apMonitor.stopAll();
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    if (this.fpsTimer !== -1) {
      clearInterval(this.fpsTimer);
      this.fpsTimer = -1;
    }
    if (this.analyzeReceiver) {
      try {
        this.analyzeReceiver.release();
      } catch (e) {
        // ignore
      }
      this.analyzeReceiver = undefined;
    }
    if (this.session) {
      try {
        this.session.release();
      } catch (e) {
        // ignore
      }
      this.session = undefined;
    }
    this.started = false;
  }

  build() {
    Stack() {
      Column() {
      // 预览
      Stack() {
        Stack({ alignContent: Alignment.Center }) {
          XComponent({ id: 'preview', type: XComponentType.SURFACE, controller: this.xController })
            .width('100%')
            .height('100%')
            // 兼容模式：硬件倍率不动，靠居中放大 + 外层 clip 实现「假变焦」
            .scale({ x: this.cropScale(), y: this.cropScale() })
            .onLoad(() => {
              try {
                this.xController.setXComponentSurfaceRotation({ lock: true });
              } catch (e) {
                console.error('[X] lock rotation failed');
              }
              this.boot();
            })

          if (this.meterMode === 'spot') {
            Stack({ alignContent: Alignment.Center }) {
              Circle({ width: Index.RING_VP, height: Index.RING_VP })
                .fillOpacity(0)
                .stroke('#88000000')
                .strokeWidth(3.5)
              Circle({ width: Index.RING_VP, height: Index.RING_VP })
                .fillOpacity(0)
                .stroke('#F0FFFFFF')
                .strokeWidth(1.5)
              Rect({ width: 20, height: 2 }).fill('#F0FFFFFF')
              Rect({ width: 2, height: 20 }).fill('#F0FFFFFF')
            }
            .width(Index.RING_VP)
            .height(Index.RING_VP)
            .position({ x: `${this.meterX * 100}%`, y: `${this.meterY * 100}%` })
            .translate({ x: -Index.RING_VP / 2, y: -Index.RING_VP / 2 })
            .hitTestBehavior(HitTestMode.None)
          }
        }
        .width('100%')
        .height('100%')
        .gesture(
          PanGesture({ fingers: 1, distance: 0 })
            .onActionStart((event: GestureEvent) => {
              this.moveMeterTo(event);
            })
            .onActionUpdate((event: GestureEvent) => {
              this.moveMeterTo(event);
            })
            .onActionEnd(() => {
              this.onMeterMoved();
            })
        )
      }
      .width(`${Index.PREVIEW_WIDTH * 100}%`)
      .aspectRatio(Index.PREVIEW_RATIO)
      .backgroundColor(Color.Black)
      .clip(true)
      .margin({ top: 8 })

      // 数据区
      Column({ space: 8 }) {
        // 变焦：滑条独占一行，拿满宽度
        Row({ space: 8 }) {
          Text('变焦').fontSize(12).fontColor('#CCFFFFFF').width(40)
          Slider({ value: this.zoomPos, min: 0, max: 1000, step: 1, style: SliderStyle.OutSet })
            .layoutWeight(1)
            .enabled(!this.locked && !this.zoomLocked)
            .onChange((v: number, mode: SliderChangeMode) => {
              this.zoomPos = v;
              this.onZoomSlider(v, mode);
            })
        }
        .width('100%')

        // 焦距按钮 + 光圈文案同一行（拍照读 EXIF 得来，0.5s 刷新）
        Row({ space: 8 }) {
          Text(this.apText)
            .fontSize(11)
            .fontColor('#99FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          // 焦距入口：与 ISO / 校准 EV 同一套样式（深灰底 + 白字 + 蓝色箭头），锁定时文字转红
          Row({ space: 4 }) {
            Text(this.zoomCaption())
              .fontSize(13)
              .fontColor(this.zoomLocked ? '#FF5C5C' : Color.White)
              .maxLines(1)
            Text('›')
              .fontSize(14)
              .fontColor(this.zoomLocked ? '#FF5C5C' : '#7FB2FF')
          }
          .padding({ left: 10, right: 8, top: 6, bottom: 6 })
          .borderRadius(8)
          .backgroundColor('#1A1A1A')
          .onClick(() => {
            this.openFocalDialog();
          })
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)

        // EV | 锁定
        Row({ space: 12 }) {
          Row({ space: 6 }) {
            Text('EV')
              .fontSize(24)
              .fontWeight(FontWeight.Medium)
              .fontColor('#CCFFFFFF')
              .margin({ bottom: 12 })
            Text(this.evText).fontSize(52).fontWeight(FontWeight.Bold).fontColor(Color.White)
          }
          .alignItems(VerticalAlign.Bottom)
          .layoutWeight(1)

          Column({ space: 6 }) {
            Button(this.meteringContinuous ? '连续测光中' : '启动测光')
              .width(112)
              .height(44)
              .fontSize(this.meteringContinuous ? 12 : 14)
              .fontColor(this.meteringOn ? '#101010' : Color.White)
              .backgroundColor(this.meteringOn ? '#7FB2FF' : '#2E2E2E')
              .borderRadius(10)
              .enabled(!this.locked)
              .onTouch((event: TouchEvent) => {
                if (event.type === TouchType.Down) {
                  this.onMeterButtonDown();
                } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                  this.onMeterButtonUp();
                }
              })

            Button(this.locked ? '解除锁定' : '锁定曝光')
              .width(112)
              .height(44)
              .fontSize(14)
              .fontColor(Color.White)
              .backgroundColor(this.locked ? '#D9622B' : '#2E2E2E')
              .borderRadius(10)
              .onClick(() => {
                this.toggleLock();
              })
          }
          .width(112)
        }
        .width('100%')

        // 测光模式 | A/S | 胶片 ISO 入口
        Row({ space: 8 }) {
          Row({ space: 4 }) {
            Text('点测')
              .fontSize(12)
              .fontColor(this.meterMode === 'spot' ? '#101010' : '#CCFFFFFF')
              .backgroundColor(this.meterMode === 'spot' ? '#FFFFFF' : '#22FFFFFF')
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .borderRadius(6)
              .onClick(() => {
                this.setMeterMode('spot');
              })
            Text('矩阵')
              .fontSize(12)
              .fontColor(this.meterMode === 'matrix' ? '#101010' : '#CCFFFFFF')
              .backgroundColor(this.meterMode === 'matrix' ? '#FFFFFF' : '#22FFFFFF')
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .borderRadius(6)
              .onClick(() => {
                this.setMeterMode('matrix');
              })
          }

          Row({ space: 4 }) {
            Text('A')
              .fontSize(12)
              .fontColor(this.apLocked ? '#101010' : '#CCFFFFFF')
              .backgroundColor(this.apLocked ? Index.BLUE : '#22FFFFFF')
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(6)
              .onClick(() => {
                this.setExposureModeLock(true);
              })
            Text('S')
              .fontSize(12)
              .fontColor(!this.apLocked ? '#101010' : '#CCFFFFFF')
              .backgroundColor(!this.apLocked ? Index.BLUE : '#22FFFFFF')
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(6)
              .onClick(() => {
                this.setExposureModeLock(false);
              })
          }

          Blank()

          Row({ space: 4 }) {
            Text(`ISO ${this.filmIso}`).fontSize(13).fontColor(Color.White)
            Text('›').fontSize(14).fontColor('#7FB2FF')
          }
          .padding({ left: 8, right: 6, top: 6, bottom: 6 })
          .borderRadius(8)
          .backgroundColor('#1A1A1A')
          .onClick(() => {
            this.openIsoDialog();
          })
        }
        .width('100%')

        // 曝光组合：两个滚轮 + 外框
        Column({ space: 2 }) {
          Row() {
            Column({ space: 0 }) {
              Text('光圈').fontSize(11).fontColor(this.apLocked ? Index.BLUE : '#CCFFFFFF')
              Stack() {
                TextPicker({
                  range: this.apLocked ? this.apertureItems : this.apertureItemsComputed,
                  value: $$this.apLabel
                })
                  .canLoop(false)
                  .defaultPickerItemHeight(Index.ITEM_H)
                  .divider(null)
                  .textStyle({ color: '#88FFFFFF', font: { size: 13 } })
                  .selectedTextStyle({
                    color: this.apLocked ? Index.BLUE : Color.White,
                    font: { size: 22 }
                  })
                  .disappearTextStyle({ color: '#44FFFFFF', font: { size: 11 } })
                  .height(Index.PICKER_H)
                  .width('100%')
                  .onChange((value: string | string[], index: number | number[]) => {
                    if (!this.apLocked) {
                      return;
                    }
                    if (!this.apLocked) {
                      // S 档时光圈是算出来的，不接受用户改动
                      return;
                    }
                    this.apIndex = index as number;
                    this.updateCombo();
                  })

                if (!this.apLocked) {
                  Column()
                    .width('100%')
                    .height(Index.PICKER_H)
                    .hitTestBehavior(HitTestMode.Block)
                }


                if (!this.apLocked && !this.computedKnown()) {
                  Column() {
                    Text('XX').fontSize(22).fontColor('#66FFFFFF')
                  }
                  .width('100%')
                  .height(Index.PICKER_H)
                  .justifyContent(FlexAlign.Center)
                  .backgroundColor('#101010')
                  .hitTestBehavior(HitTestMode.None)
                }

                Rect()
                  .width(26)
                  .height(2)
                  .fill(this.apLocked ? Index.LINE_ON : Index.LINE_LOCKED)
                  .position({ x: '8%', y: 44 })
                Rect()
                  .width(26)
                  .height(2)
                  .fill(this.apLocked ? Index.LINE_ON : Index.LINE_LOCKED)
                  .position({ x: '82%', y: 44 })
              }
              .width('100%')
              .height(Index.PICKER_H)
            }
            .layoutWeight(1)

            Column({ space: 0 }) {
              Text('快门').fontSize(11).fontColor(this.apLocked ? '#CCFFFFFF' : Index.BLUE)
              Stack() {
                TextPicker({
                  range: this.apLocked ? this.shutterItemsComputed : this.shutterItems,
                  value: $$this.shLabel
                })
                  .canLoop(false)
                  .defaultPickerItemHeight(Index.ITEM_H)
                  .divider(null)
                  .textStyle({ color: '#88FFFFFF', font: { size: 13 } })
                  .selectedTextStyle({
                    color: this.apLocked ? Color.White : Index.BLUE,
                    font: { size: 22 }
                  })
                  .disappearTextStyle({ color: '#44FFFFFF', font: { size: 11 } })
                  .height(Index.PICKER_H)
                  .width('100%')
                  .onChange((value: string | string[], index: number | number[]) => {
                    if (this.apLocked) {
                      // A 档时快门是算出来的，不接受用户改动
                      return;
                    }
                    this.shIndex = index as number;
                    this.updateCombo();
                  })

                if (this.apLocked) {
                  Column()
                    .width('100%')
                    .height(Index.PICKER_H)
                    .hitTestBehavior(HitTestMode.Block)
                }


                if (this.apLocked && !this.computedKnown()) {
                  Column() {
                    Text('XX').fontSize(22).fontColor('#66FFFFFF')
                  }
                  .width('100%')
                  .height(Index.PICKER_H)
                  .justifyContent(FlexAlign.Center)
                  .backgroundColor('#101010')
                  .hitTestBehavior(HitTestMode.None)
                }

                Rect()
                  .width(26)
                  .height(2)
                  .fill(this.apLocked ? Index.LINE_LOCKED : Index.LINE_ON)
                  .position({ x: '8%', y: 44 })
                Rect()
                  .width(26)
                  .height(2)
                  .fill(this.apLocked ? Index.LINE_LOCKED : Index.LINE_ON)
                  .position({ x: '82%', y: 44 })
              }
              .width('100%')
              .height(Index.PICKER_H)
            }
            .layoutWeight(1)
          }
          .width('100%')

        }
        .width('100%')
        .padding({ top: 4, bottom: 6 })
        .border({ width: 1, color: '#2E2E2E' })
        .borderRadius(12)

        // 校准 | 曝光补偿
        Row({ space: 10 }) {
          Row({ space: 4 }) {
            Text('校准 EV').fontSize(12).fontColor('#CCFFFFFF')
            Text(`${this.biasEv > 0 ? '+' : ''}${this.biasEv.toFixed(1)}`).fontSize(15).fontColor(Color.White)
            Blank()
            Text('›').fontSize(14).fontColor('#7FB2FF')
          }
          .layoutWeight(1)
          .padding({ left: 10, right: 8, top: 8, bottom: 8 })
          .backgroundColor('#1A1A1A')
          .borderRadius(8)
          .onClick(() => {
            this.openCalibDialog();
          })

          Row({ space: 4 }) {
            Text('曝光补偿').fontSize(12).fontColor('#CCFFFFFF')
            Text(`${this.expEv > 0 ? '+' : ''}${this.expEv.toFixed(1)}`).fontSize(15).fontColor(Color.White)
            Blank()
            Text('›').fontSize(14).fontColor('#7FB2FF')
          }
          .layoutWeight(1)
          .padding({ left: 10, right: 8, top: 8, bottom: 8 })
          .backgroundColor('#1A1A1A')
          .borderRadius(8)
          .onClick(() => {
            this.openExpDialog();
          })
        }
        .width('100%')

        Text(this.statusText).fontSize(10).fontColor('#77FFFFFF').width('100%')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 4 })
      .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.safeTop, bottom: this.safeBottom })
      .backgroundColor('#101010')

      // 右上角：设置入口（齿轮图标）。浮在预览右侧的黑色留白里，不占布局高度
      // （页面已经很挤，加一行 40vp 的顶栏会把底部状态文字顶出屏幕）
      if (!this.booting) {
        Column() {
          Stack() {
            Image($r('app.media.ic_settings_gear'))
              .width(21)
              .height(21)
              .fillColor('#E8FFFFFF')
              .draggable(false)
          }
          .width(36)
          .height(36)
          .backgroundColor('#1AFFFFFF')
          .borderRadius(18)
          .onClick(() => {
            this.openSettings();
          })
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.End)
        .justifyContent(FlexAlign.Start)
        .padding({ top: this.safeTop + 8, right: 8 })
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // 设置页：盖住主界面，返回键也能退出
      if (this.showSettings) {
        this.settingsPage()
      }

      // 启动黑屏过渡：盖住整个页面，初始化完成后淡出
      if (this.booting) {
        // 黑底不跟着淡出，只淡出文字/转圈，否则淡出那 200ms 会透出下面页面
        Column() {
          Column({ space: 18 }) {
            Text('轻测光')
              .fontSize(30)
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.White)
            Text('启动中')
              .fontSize(14)
              .fontColor('#99FFFFFF')
            LoadingProgress()
              .width(34)
              .height(34)
              .color('#7FB2FF')
          }
          .alignItems(HorizontalAlign.Center)
          .opacity(this.splashAlpha)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#000000')
        .hitTestBehavior(HitTestMode.Block)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }

  private openIsoDialog(): void {
    const dlg = new CustomDialogController({
      builder: WheelDialog({
        title: '胶片 ISO',
        suffix: '',
        items: this.isoItems,
        startIndex: this.isoIndex,
        onPick: (i: number) => {
          this.isoIndex = i;
          this.filmIso = ISO_LADDER[i];
        },
        onDone: (i: number) => {
          this.isoIndex = i;
          this.filmIso = ISO_LADDER[i];
          this.refreshDisplay();
          this.savePref(Index.PREF_ISO, this.filmIso);
          console.info(`[DIALOG] iso done ${this.filmIso}`);
          this.closeDialog();
        }
      }),
      autoCancel: true,
      customStyle: true,
      alignment: DialogAlignment.Center
    });
    this.activeDialog = dlg;
    dlg.open();
  }

  private openCalibDialog(): void {
    const dlg = new CustomDialogController({
      builder: WheelDialog({
        title: '校准 EV（系统偏差）',
        suffix: ' EV',
        items: this.biasItems,
        startIndex: this.calibIndex,
        onPick: (i: number) => {
          this.calibIndex = i;
          this.biasEv = (i - 50) / 10;
          this.refreshDisplay();
        },
        onDone: (i: number) => {
          this.calibIndex = i;
          this.biasEv = (i - 50) / 10;
          this.refreshDisplay();
          this.savePref(Index.PREF_BIAS, this.biasEv);
          console.info(`[DIALOG] calib done ${this.biasEv}`);
          this.closeDialog();
        }
      }),
      autoCancel: true,
      customStyle: true,
      alignment: DialogAlignment.Center
    });
    this.activeDialog = dlg;
    dlg.open();
  }

  private openExpDialog(): void {
    const dlg = new CustomDialogController({
      builder: WheelDialog({
        title: '曝光补偿',
        suffix: ' EV',
        items: this.biasItems,
        startIndex: this.expIndex,
        onPick: (i: number) => {
          this.expIndex = i;
          this.expEv = (i - 50) / 10;
          this.refreshDisplay();
        },
        onDone: (i: number) => {
          this.expIndex = i;
          this.expEv = (i - 50) / 10;
          this.refreshDisplay();
          this.savePref(Index.PREF_EXP, this.expEv);
          console.info(`[DIALOG] exp done ${this.expEv}`);
          this.closeDialog();
        }
      }),
      autoCancel: true,
      customStyle: true,
      alignment: DialogAlignment.Center
    });
    this.activeDialog = dlg;
    dlg.open();
  }

  private closeDialog(): void {
    try {
      this.activeDialog?.close();
    } catch (e) {
      // ignore
    }
    this.activeDialog = undefined;
  }

  private setMeterMode(mode: string): void {
    this.meterMode = mode;
    this.applyMeterMode();
    this.savePref(Index.PREF_METER, mode);
    // 锁定态没有实时帧，要靠冻结帧重算
    if (this.locked) {
      this.remeter();
    }
  }

  private openSettings(): void {
    this.showSettings = true;
    console.info(`[SETTINGS] page open zoomMode=${this.zoomMode}`);
  }

  private closeSettings(): void {
    this.showSettings = false;
  }

  /** 切换变焦模式：立刻换变焦方式，其他测光逻辑不动 */
  private setZoomMode(mode: string): void {
    if (this.zoomMode === mode) {
      return;
    }
    this.zoomMode = mode;
    this.savePref(Index.PREF_ZOOM_MODE, mode);
    console.info(`[SETTINGS] zoomMode=${mode}`);
    this.applyZoomMode();
  }

  /**
   * 应用变焦模式：
   *   normal → 把当前显示倍率重新下发给相机（裁切归 1）；
   *   compat → 相机倍率钉到最小值，显示倍率落回最小值（裁切归 1），光圈用存量的常量。
   */
  private applyZoomMode(): void {
    this.apMonitor.stopPolling();
    const target: number = this.isCompat()
      ? this.compatDefaultRatio()
      : Math.max(this.zoomMin, Math.min(this.zoomRatio, this.zoomMax));
    this.zoomTarget = target;
    this.zoomAnim = target;
    this.zoomPos = zoomToSliderPos(target, this.zoomMin, this.zoomUiMax());
    this.applyZoom(target);
    if (this.isCompat()) {
      this.ensureCompatAperture();
    } else {
      // 切回普通模式：光圈文案要换回轮询口径，否则会一直挂着「兼容模式 · 固定光圈 …」
      const r: ApReading | undefined = this.apMonitor.reading();
      this.apText = r !== undefined
        ? `当前光圈 f/${r.aperture.toFixed(1)} · 物理焦距 ${r.focal.toFixed(1)}mm`
        : '光圈识别中…';
    }
    // 裁切变了，给相机的测光点要按新的裁切重新换算
    this.updateMeterPoint();
    this.statusText = this.isCompat() ? '兼容模式（裁切放大）' : '待测光（按住启动测光）';
    // 锁定态没在取帧，用冻结帧重算一次，避免切模式后读数对不上
    if (this.locked) {
      this.remeter();
    }
    console.info(`[ZOOM] mode applied ${this.zoomMode} ui=${target.toFixed(2)}x ` +
      `hw=${this.hwZoomOf(target).toFixed(2)}x crop=${this.cropScale().toFixed(2)}`);
  }

  /** 设置页里的单个模式选项 */
  @Builder
  zoomModeOption(mode: string, title: string, desc: string) {
    Row({ space: 10 }) {
      Column({ space: 4 }) {
        Text(title)
          .fontSize(15)
          .fontColor(this.zoomMode === mode ? Color.White : '#DDDDDD')
        Text(desc)
          .fontSize(11)
          .fontColor('#88FFFFFF')
          .maxLines(2)
          .lineHeight(15)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(this.zoomMode === mode ? '✓' : '')
        .fontSize(18)
        .fontColor(Index.BLUE)
        .width(18)
    }
    .width('100%')
    .padding({ left: 14, right: 12, top: 12, bottom: 12 })
    .backgroundColor('#1A1A1A')
    .borderRadius(10)
    .border({
      width: 1,
      color: this.zoomMode === mode ? Index.BLUE : '#2A2A2A'
    })
    .onClick(() => {
      this.setZoomMode(mode);
    })
  }

  /** 设置页（整页浮层，不新开路由，省掉一套全屏/安全区配置） */
  @Builder
  settingsPage() {
    Stack() {
      // 底层吸收点击：挡住下面的主界面，不把触摸漏给预览/按钮
      // （不能用 HitTestMode.Block 盖在内容上 —— 它会连自己的子节点一起屏蔽，卡片就点不动了）
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#0E0E0E')
        .hitTestBehavior(HitTestMode.Block)

      Column({ space: 12 }) {
        // 顶栏：返回 + 标题
        Row() {
          Text('‹ 返回')
            .fontSize(14)
            .fontColor('#7FB2FF')
            .width(64)
            .onClick(() => {
              this.closeSettings();
            })
          Text('设置')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
          Text('')
            .width(64)
        }
        .width('100%')
        .height(48)

        // 变焦模式
        Column({ space: 8 }) {
          Text('变焦模式')
            .fontSize(12)
            .fontColor('#99FFFFFF')
            .width('100%')

          this.zoomModeOption(Index.MODE_NORMAL, '普通模式',
            '相机原生变焦，画面清晰、视场真实（默认）')
          this.zoomModeOption(Index.MODE_COMPAT, '兼容模式',
            '相机锁在最广角，靠裁切放大（最多 5 倍，画面会变糊）')
        }
        .width('100%')

        Blank()
      }
      .width('100%')
      .height('100%')
      .padding({
        left: 16,
        right: 16,
        top: this.safeTop + 4,
        bottom: this.safeBottom + 8
      })
      .alignItems(HorizontalAlign.Start)
      // 空白处也吃掉点击，免得穿透到下面的主界面（子节点的 onClick 照常生效）
      .onClick(() => {
      })
    }
    .width('100%')
    .height('100%')
  }

  private applyMeterMode(): void {
    const s = this.session;
    if (!s) {
      return;
    }
    try {
      s.setExposureMeteringMode(this.meterMode === 'spot' ?
        camera.ExposureMeteringMode.SPOT : camera.ExposureMeteringMode.MATRIX);
    } catch (e) {
      // 部分机型不支持某种模式，忽略
    }
  }

  /** 切换锁定项（A 档 / S 档），只由 A/S 按钮触发 */
  private setExposureModeLock(apertureLocked: boolean): void {
    if (this.apLocked === apertureLocked) {
      return;
    }
    this.apLocked = apertureLocked;
    // 切档后两侧滚轮换用另一套列表，标签必须重新对齐到真实档位
    this.apLabel = this.apLabelFor(this.apIndex);
    this.shLabel = this.shLabelFor(this.shIndex);
    this.updateCombo();
    this.savePref(Index.PREF_APLOCK, apertureLocked);
    console.info(`[MODE] ${apertureLocked ? 'A' : 'S'}`);
  }

  private updateMeterPoint(): void {
    const s = this.session;
    if (!s) {
      return;
    }
    try {
      // 相机坐标系是转置的；兼容模式取景框只显示画面正中一块，测光点也得跟着缩进那块里，
      // 否则给相机的 AE 点会落在取景框外面（曝光按没用到的区域算，EV 就偏了）
      const crop: number = this.cropScale();
      const x: number = 0.5 + (this.meterY - 0.5) / crop;
      const y: number = 0.5 + (0.5 - this.meterX) / crop;
      s.setMeteringPoint({ x: x, y: y });
    } catch (e) {
      // 部分曝光模式不支持设点
    }
  }

  /** EV100（含校准与曝光补偿） */
  private baseEv(): number {
    return this.lastRawEv + this.biasEv + this.expEv;
  }

  /** 界面显示用：当前胶片 ISO 下的 EV */
  private displayEv(): number {
    return this.baseEv() + Math.log2(this.filmIso / 100);
  }

  private updateCombo(): void {
    if (!(this.lastRawEv > 0)) {
      return;
    }
    const ev: number = this.baseEv();
    let combo: Combo;
    if (this.apLocked) {
      // A 档：快门是算出来的，超范围就落到空白档
      combo = comboFor(ev, this.filmIso, APERTURE_LADDER[this.apIndex]);
      if (combo.outOfRange) {
        this.shLabel = combo.exact < SHUTTER_LADDER[0] ? Index.BLANK_TOP : Index.BLANK_BOTTOM;
      } else {
        // 无条件对齐：只在「下标变了」时才写 label 会留坑 ——
        // 上一轮超范围把 label 写成了空白，回到范围内但下标没变时，空白就一直留在屏幕上
        this.shIndex = combo.shutterIndex;
        this.shLabel = this.shLabelFor(this.shIndex);
      }
    } else {
      // S 档：光圈是算出来的，超范围就落到空白档
      combo = comboFromShutter(ev, this.filmIso, SHUTTER_LADDER[this.shIndex]);
      if (combo.outOfRange) {
        this.apLabel = combo.exact < APERTURE_LADDER[0] ? Index.BLANK_TOP : Index.BLANK_BOTTOM;
      } else {
        this.apIndex = combo.apertureIndex;
        this.apLabel = this.apLabelFor(this.apIndex);
      }
    }
    this.outOfRange = combo.outOfRange;
  }

  private refreshDisplay(): void {
    if (!(this.lastRawEv > 0)) {
      return;
    }
    this.evText = this.displayEv().toFixed(1);
    this.updateCombo();
  }

  private async toggleLock(): Promise<void> {
    const s = this.session;
    if (!s) {
      this.statusText = '相机已断开，正在重连…';
      await this.reopenCamera();
      return;
    }
    const next = !this.locked;
    try {
      if (next) {
        const t0: number = Date.now();
        // ① 立刻定格：先把画面钉住、把状态切过去，测量放到后台做，别让按钮有一下卡顿感
        this.zoomTarget = this.zoomRatio;
        this.zoomAnim = this.zoomRatio;
        this.stopZoomAnimator();
        this.zooming = false;
        this.apMonitor.stopPolling();
        this.meteringOn = false;
        this.meteringContinuous = false;
        this.locked = true;
        try {
          s.setExposureMode(camera.ExposureMode.EXPOSURE_MODE_LOCKED);
        } catch (e) {
          console.error(`[LOCK] setExposureMode failed E${(e as BusinessError).code}`);
        }
        // 先把取帧流异步拉起来（锁定后要用它补数据），再定格，免得定格后 start 被拒
        this.setAnalyzerStream(true);
        try {
          const pv = this.previewOutput;
          if (pv !== undefined) {
            await pv.stop();
          }
        } catch (e) {
          console.error(`[LOCK] freeze failed E${(e as BusinessError).code}`);
        }
        console.info(`[LOCK] frozen in ${Date.now() - t0}ms`);

        // ② 有现成快照和新鲜光圈就先出数，用户几乎立刻看到 EV
        const cur = this.apMonitor.reading();
        const fresh: boolean = cur !== undefined && (Date.now() - cur.ts < 1500);
        if (this.frameSnapshot !== undefined && this.refY > 2) {
          this.remeter();
          this.statusText = this.computedKnown() ? '已锁定 · 可移动测光点' : '锁定中…';
        } else {
          this.statusText = '锁定中…';
        }
        this.evText = this.computedKnown() ? this.displayEv().toFixed(1) : 'XX';
        console.info(`[LOCK] ev ready in ${Date.now() - t0}ms`);

        // ③ 缺数据再后台补：开取帧 → 存快照 → 需要时拍一张 → 重算
        if (!fresh || this.frameSnapshot === undefined || this.refY <= 2) {
          this.finishLockMeasure();
        }
      } else {
        try {
          const pv = this.previewOutput;
          if (pv !== undefined) {
            await pv.start();
          }
        } catch (e) {
          console.error(`[LOCK] resume failed E${(e as BusinessError).code}, reopen`);
          this.locked = false;
          this.setRawEv(0);
          this.evText = 'XX';
          await this.reopenCamera();
          return;
        }
        s.setExposureMode(camera.ExposureMode.EXPOSURE_MODE_AUTO);
        this.applyZoom(this.zoomRatio);
        this.locked = false;
        // 取预览输出会把取帧那一路也拉起来，用完关掉
        this.setAnalyzerStream(false);
        this.setRawEv(0);
        this.evText = 'XX';
        this.statusText = '待测光（按住启动测光）';
      }
      console.info(`[LOCK] ${next}`);
    } catch (e) {
      console.error(`[LOCK] failed code=${(e as BusinessError).code}`);
    }
  }

  /** 锁定后补数据：开取帧 → 拿快照 → 必要时补拍光圈 → 重算读数 → 关取帧 */
  private async finishLockMeasure(): Promise<void> {
    try {
      await this.prefetchFrame();

      if (!this.isCompat()) {
        // 普通模式：光圈可能随镜头变，锁定瞬间补拍一张
        const cur = this.apMonitor.reading();
        const fresh: boolean = cur !== undefined && (Date.now() - cur.ts < 1500);
        if (!fresh) {
          if (!this.apMonitor.isWarmed()) {
            await this.apMonitor.warmUp();
          }
          const afterWarm = this.apMonitor.reading();
          const nowFresh: boolean = afterWarm !== undefined && (Date.now() - afterWarm.ts < 1500);
          if (!nowFresh) {
            await this.sleepMs(150);
            await this.apMonitor.shootNow();
          }
        }
      }

      this.remeter();
      if (this.isCompat()) {
        this.updateApText();
      } else {
        const last = this.apMonitor.reading();
        if (last !== undefined) {
          this.apText = `当前光圈 f/${last.aperture.toFixed(1)} · 物理焦距 ${last.focal.toFixed(1)}mm`;
        }
      }
      this.statusText = this.computedKnown() ? '已锁定 · 可移动测光点' : '已锁定 · 无有效读数';
      console.info(`[LOCK] measure done ev=${this.evText} ap=${this.apLabel} sh=${this.shLabel} ` +
        `known=${this.computedKnown()} evKnown=${this.evKnown} oob=${this.outOfRange}`);
    } catch (e) {
      console.error(`[LOCK] measure failed E${(e as BusinessError).code}`);
    } finally {
      this.setAnalyzerStream(false);
    }
  }

  private async boot(): Promise<void> {
    if (this.started) {
      return;
    }
    this.started = true;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const ok = await this.ensurePermission(ctx);
      if (!ok) {
        this.statusText = '未授予相机权限';
        return;
      }
      const surfaceId = this.xController.getXComponentSurfaceId();
      this.surfaceId = surfaceId;
      await this.openCamera(ctx, surfaceId);
    } catch (e) {
      const err = e as BusinessError;
      this.statusText = `启动失败 code=${err.code}`;
    }
  }

  private async ensurePermission(ctx: common.UIAbilityContext): Promise<boolean> {
    const at = abilityAccessCtrl.createAtManager();
    const res = await at.requestPermissionsFromUser(ctx, ['ohos.permission.CAMERA']);
    return res.authResults.length > 0 && res.authResults[0] === 0;
  }

  private async openCamera(ctx: common.UIAbilityContext, surfaceId: string,
    isResume: boolean = false): Promise<void> {
    const manager = camera.getCameraManager(ctx);
    const devices = manager.getSupportedCameras();
    if (devices.length === 0) {
      this.statusText = '没有可用相机';
      return;
    }

    let dev: camera.CameraDevice = devices[0];
    for (const d of devices) {
      if (d.cameraPosition === camera.CameraPosition.CAMERA_POSITION_BACK &&
        d.cameraType === camera.CameraType.CAMERA_TYPE_WIDE_ANGLE) {
        dev = d;
        break;
      }
    }

    this.device = dev;
    const cap = manager.getSupportedOutputCapability(dev, camera.SceneMode.NORMAL_PHOTO);
    if (cap.previewProfiles.length === 0) {
      this.statusText = '没有可用预览档位';
      return;
    }

    // 显示档别再取最大 4:3（1920x1440）：屏幕上预览只占屏宽 70%（约 890px），
    // 2.7MP@30fps 白占 HAL 带宽，变焦时就表现成一顿一顿。改成「刚好覆盖显示宽度」的最小档。
    let screenW: number = 1272;
    try {
      screenW = display.getDefaultDisplaySync().width;
    } catch (e) {
      screenW = 1272;
    }
    const wantW: number = Math.round(screenW * Index.PREVIEW_WIDTH);

    let profile: camera.Profile = cap.previewProfiles[0];
    let bestW: number = -1;
    let fallback: camera.Profile = cap.previewProfiles[0];
    let fallbackW: number = -1;
    for (const p of cap.previewProfiles) {
      const r = p.size.width / p.size.height;
      if (Math.abs(r - 4 / 3) >= 0.01) {
        continue;
      }
      if (p.size.width >= wantW && (bestW < 0 || p.size.width < bestW)) {
        bestW = p.size.width;
        profile = p;
      }
      if (p.size.width > fallbackW) {
        fallbackW = p.size.width;
        fallback = p;
      }
    }
    if (bestW < 0) {
      profile = fallback;
    }

    const ratioList: string[] = [];
    for (const pf of cap.previewProfiles) {
      ratioList.push(`${pf.size.width}x${pf.size.height}`);
    }
    console.info(`[CAM] display profile ${profile.size.width}x${profile.size.height} ` +
      `fmt=${profile.format} all=[${ratioList.join(',')}]`);

    try {
      const disp = display.getDefaultDisplaySync();
      const surfaceH = Math.min(disp.height, Math.round(disp.width * 4 / 3));
      this.xController.setXComponentSurfaceRect({
        surfaceWidth: disp.width,
        surfaceHeight: surfaceH
      });
    } catch (e) {
      console.error('[SURFACE] setXComponentSurfaceRect failed');
    }

    const preview = manager.createPreviewOutput(profile, surfaceId);
    this.previewOutput = preview;
    const input = manager.createCameraInput(dev);
    await input.open();

    const s = manager.createSession(camera.SceneMode.NORMAL_PHOTO) as camera.PhotoSession;
    s.beginConfig();
    s.addInput(input);
    s.addOutput(preview);

    if (this.enableAnalyzer) {
      const analyze = await this.createAnalyzer(manager, cap, profile);
      if (analyze !== undefined) {
        s.addOutput(analyze);
        this.analyzeOutput = analyze;
      }
    }

    // 光圈监测用的 PhotoOutput（低分辨率，输出到 ImageReceiver，读完即弃）
    try {
      const photoOut = await this.apMonitor.prepare(manager, cap);
      if (photoOut !== undefined) {
        s.addOutput(photoOut);
      }
    } catch (e) {
      console.error(`[AP] attach photo output failed E${(e as BusinessError).code}`);
    }

    try {
      await s.commitConfig();
      await s.start();
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[SESSION] failed code=${err.code}`);
      this.statusText = `相机会话启动失败 code=${err.code}`;
      return;
    }
    this.session = s;

    try {
      s.setFocusMode(camera.FocusMode.FOCUS_MODE_CONTINUOUS_AUTO);
    } catch (e) {
      console.error(`[FOCUS] failed ${(e as BusinessError).code}`);
    }

    await this.initZoomRange(s, !isResume);
    this.applyZoom(this.zoomRatio);
    if (this.zoomLocked && this.pendingLockMm > 0 && this.baseFocal35 > 0) {
      this.applyFocalMm(this.pendingLockMm);
      console.info(`[ZOOM] restored locked focal ${this.pendingLockMm}mm`);
    }

    this.applyMeterMode();
    try {
      s.setMeteringPoint({ x: 0.5, y: 0.5 });
    } catch (e) {
      // ignore
    }

    s.onExposureInfoChange((info: camera.ExposureInfo) => {
      const t = info.exposureTime;
      if (t !== undefined && t > 0) {
        this.aeDurationUs = t;
      }
    });
    s.on('smoothZoomInfoAvailable', (err: BusinessError, info: camera.SmoothZoomInfo) => {
      if (!err && info !== undefined) {
        console.info(`[ZOOM] smooth duration=${info.duration}ms`);
      }
    });
    s.onIsoInfoChange((info: camera.IsoInfo) => {
      const v = info.iso;
      if (v !== undefined && v > 0) {
        this.aeIso = v;
      }
    });

    try {
      s.setExposureMode(camera.ExposureMode.EXPOSURE_MODE_AUTO);
      this.statusText = 'AE 收敛中…';
    } catch (e) {
      this.statusText = `设置曝光模式失败 ${(e as BusinessError).code}`;
    }

    this.timer = setInterval(() => {
      this.readOnce();
    }, 400);

    // 帧率实测：每 5 秒打一条，看取帧流真实到达率与后处理接受率
    this.fpsMs = Date.now();
    this.fpsArrPrev = this.arrivalCount;
    this.fpsProcPrev = this.processedCount;
    setTimeout(() => {
      this.probeFrameRates();
    }, 3500);

    if (this.fpsTimer === -1) {
      this.fpsTimer = setInterval(() => {
        this.logFps();
      }, 5000);
    }

    // 光圈监测：默认不拍照不处理，等用户按住「启动测光」或按下锁定才开始
    this.apMonitor.bind(s, (r: ApReading) => {
      this.apText = `${this.meteringOn || this.locked ? '当前' : '上次'}光圈 ` +
        `f/${r.aperture.toFixed(1)} · 物理焦距 ${r.focal.toFixed(1)}mm`;
      this.refreshDisplay();
    });
    this.pinPreviewFrameRate();
    this.setAnalyzerStream(false);
    this.cameraReady = true;
    // 黑屏期间把拍照管道热起来（首启还要标定 1x 等效焦距），做完才收黑屏
    setTimeout(() => {
      this.runStartupWarmup();
    }, 500);
    this.maybeFinishBoot();
    this.setRawEv(0);
    this.evText = 'XX';
    this.statusText = '待测光（按住启动测光）';
  }

  private rateText(out: camera.PreviewOutput | undefined): string {
    if (out === undefined) {
      return 'n/a';
    }
    try {
      const r: camera.FrameRateRange = out.getActiveFrameRate();
      return `${r.min}-${r.max}`;
    } catch (e) {
      return `E${(e as BusinessError).code}`;
    }
  }

  private rateList(out: camera.PreviewOutput | undefined): string {
    if (out === undefined) {
      return 'n/a';
    }
    try {
      const list: camera.FrameRateRange[] = out.getSupportedFrameRates();
      const parts: string[] = [];
      for (const r of list) {
        parts.push(`${r.min}-${r.max}`);
      }
      return `n=${list.length} [${parts.join('|')}]`;
    } catch (e) {
      return `E${(e as BusinessError).code}`;
    }
  }

  /** 档次支持哪些帧率 + 显式把预览钉到 30fps 再读回，确认前台实际帧率 */
  private probeFrameRates(): void {
    const p = this.previewOutput;
    const a = this.analyzeOutput;
    console.info(`[FPS] preview supported=${this.rateList(p)}`);
    console.info(`[FPS] analyze supported=${this.rateList(a)}`);
    if (p !== undefined) {
      try {
        p.setFrameRate(30, 30);
      } catch (e) {
        console.error(`[FPS] preview setFrameRate failed E${(e as BusinessError).code}`);
      }
    }
    setTimeout(() => {
      console.info(`[FPS] after set30: previewActive=${this.rateText(p)} analyzeActive=${this.rateText(a)}`);
    }, 1500);
  }

  private logFps(): void {
    const now: number = Date.now();
    const dt: number = (now - this.fpsMs) / 1000;
    if (dt <= 0) {
      return;
    }
    const arr: number = (this.arrivalCount - this.fpsArrPrev) / dt;
    const proc: number = (this.processedCount - this.fpsProcPrev) / dt;
    this.fpsMs = now;
    this.fpsArrPrev = this.arrivalCount;
    this.fpsProcPrev = this.processedCount;
    console.info(`[FPS] arrival=${arr.toFixed(1)}fps processed=${proc.toFixed(1)}fps ` +
      `previewRate=${this.rateText(this.previewOutput)} analyzeRate=${this.rateText(this.analyzeOutput)} ` +
      `snap=${this.snapW}x${this.snapH}`);
  }

  private async createAnalyzer(manager: camera.CameraManager,
    cap: camera.CameraOutputCapability, displayProfile: camera.Profile): Promise<camera.PreviewOutput | undefined> {
    const picked = Index.pickAnalyzerProfile(cap, displayProfile);
    if (picked === undefined) {
      console.error('[ANA] no suitable profile');
      return undefined;
    }

    try {
      // 关键：接收端尺寸必须和实际取帧流一致（旧版用的是显示档尺寸，两者不同时整帧错位）
      const receiver = image.createImageReceiver(picked.size, image.ImageFormat.JPEG, 6);
      const sid = await receiver.getReceivingSurfaceId();
      this.analyzeReceiver = receiver;
      this.listenFrames(receiver, picked.size.width, picked.size.height);
      this.analyzerReady = true;
      console.info(`[ANA] profile ${picked.size.width}x${picked.size.height} fmt=${picked.format}`);
      return manager.createPreviewOutput(picked, sid);
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[ANA] failed code=${err.code}`);
      return undefined;
    }
  }

  /**
   * 挑后台取帧档位：够算 12×16 矩阵和点测圈就行，不用跟着显示档走满分辨率。
   * 选宽度最接近 640、且不大于显示档的同比例同格式档；没有就退到最小可用档。
   * 这直接决定解码开销，也是需求 4「降后台预览分辨率」的落点。
   */
  private static pickAnalyzerProfile(cap: camera.CameraOutputCapability,
    displayProfile: camera.Profile): camera.Profile | undefined {
    const ratio: number = displayProfile.size.width / displayProfile.size.height;
    const TARGET_W: number = 640;
    let best: camera.Profile | undefined = undefined;
    let bestScore: number = Number.MAX_VALUE;

    for (const p of cap.previewProfiles) {
      if (p.format !== displayProfile.format) {
        continue;
      }
      if (Math.abs(p.size.width / p.size.height - ratio) > 0.01) {
        continue;
      }
      // 超过显示档宽度的不要（没必要）；再按与 640 的差距排序
      const oversize: number = p.size.width > displayProfile.size.width ? 100000 : 0;
      const score: number = Math.abs(p.size.width - TARGET_W) + oversize;
      if (score < bestScore) {
        bestScore = score;
        best = p;
      }
    }
    return best;
  }

  private listenFrames(receiver: image.ImageReceiver, w: number, h: number): void {
    receiver.on('imageArrival', () => {
      this.arrivalCount++;
      receiver.readNextImage((err: BusinessError, nextImage: image.Image) => {
        if (err || nextImage === undefined) {
          return;
        }
        nextImage.getComponent(image.ComponentType.JPEG, (err2: BusinessError, comp: image.Component) => {
          if (!err2 && comp !== undefined && comp.byteBuffer !== undefined) {
            this.sampleFrame(comp.byteBuffer, w, h, comp.rowStride);
          }
          nextImage.release().then(() => {
            // ok
          }).catch(() => {
            // ignore
          });
        });
      });
    });
  }

  private sampleFrame(buf: ArrayBuffer, w: number, h: number, stride: number): void {
    // 不测光 / 变焦中都不做亮度统计：省掉这一路的 CPU（锁定前预取那一帧例外）
    if (this.zooming || (!this.meteringOn && !this.locked && !this.lockPrep)) {
      return;
    }
    // 限制后处理频率（约 20fps 上限）：多出来的帧直接丢，不参与统计也不存快照
    const now: number = Date.now();
    if (now - this.lastSampleMs < 50) {
      return;
    }
    this.lastSampleMs = now;
    this.frameCount++;
    this.processedCount++;
    // 一帧只建一次视图，亮度统计与快照共用（原来各建一个）
    const data = new Uint8Array(buf);
    this.computeSample(data, w, h, stride);
    if (this.lockPrep || this.frameCount % 3 === 0) {
      this.saveSnapshot(data, w, h, stride);
    }
  }

  private saveSnapshot(src: Uint8Array, w: number, h: number, stride: number): void {
    const STEP = 2;
    const sw = Math.floor(w / STEP);
    const sh = Math.floor(h / STEP);
    if (sw < 8 || sh < 8) {
      return;
    }
    if (this.frameSnapshot === undefined || this.snapW !== sw || this.snapH !== sh) {
      this.frameSnapshot = new Uint8Array(sw * sh);
      this.snapW = sw;
      this.snapH = sh;
    }
    const snap = this.frameSnapshot;
    for (let y = 0; y < sh; y++) {
      const rowOff = (y * STEP) * stride;
      // 每行算一次上界，省掉逐像素的 length 比较
      const rowEnd: number = Math.min(src.length, rowOff + w);
      const dst = y * sw;
      for (let x = 0; x < sw; x++) {
        const idx = rowOff + x * STEP;
        snap[dst + x] = idx < rowEnd ? src[idx] : 0;
      }
    }
  }

  private regionMeanSnap(scx: number, scy: number, r: number): number {
    const snap = this.frameSnapshot;
    if (snap === undefined) {
      return 0;
    }
    const w = this.snapW;
    const h = this.snapH;
    const x0 = Math.max(0, Math.floor(scx - r));
    const x1 = Math.min(w - 1, Math.ceil(scx + r));
    const y0 = Math.max(0, Math.floor(scy - r));
    const y1 = Math.min(h - 1, Math.ceil(scy + r));
    const step = Math.max(1, Math.floor(r / 6));
    let sum = 0;
    let cnt = 0;
    for (let y = y0; y <= y1; y += step) {
      const off = y * w;
      for (let x = x0; x <= x1; x += step) {
        sum += snap[off + x];
        cnt++;
      }
    }
    return cnt > 0 ? sum / cnt : 0;
  }

  private remeter(): void {
    if (!this.locked || this.frameSnapshot === undefined || this.snapW <= 0) {
      return;
    }
    const iso = this.aeIso;
    const durationUs = this.aeDurationUs;
    if (!(iso > 0) || !(durationUs > 0)) {
      return;
    }
    const shutterSec = durationUs / 1000000;
    let raw = ev100From(this.meteringAperture(), shutterSec, iso);

    const crop: number = this.cropScale();
    const ringR = Math.max(1, (this.ringRatio() * this.snapW) / crop / 2);

    const scx = this.snapW * (0.5 + (this.meterY - 0.5) / crop);
    const scy = this.snapH * (0.5 + (0.5 - this.meterX) / crop);
    const localY = this.meterMode === 'matrix'
      ? this.matrixY
      : this.regionMeanSnap(scx, scy, ringR);

    if (this.refY > 2 && localY > 2) {
      const ratio = Math.min(16, Math.max(0.0625, localY / this.refY));
      raw += 2.2 * Math.log2(ratio);
    }

    this.setRawEv(raw);
    this.refreshDisplay();
    this.statusText = '锁定中 · 已测新点';
  }

  private moveMeterTo(event: GestureEvent): void {
    let w = 0;
    let h = 0;
    try {
      const disp = display.getDefaultDisplaySync();
      w = Math.round(disp.width * Index.PREVIEW_WIDTH);
      h = Math.round(w * 4 / 3);
    } catch (e) {
      return;
    }
    if (w <= 0 || h <= 0) {
      return;
    }
    const fingers = event.fingerList;
    if (fingers === undefined || fingers.length === 0) {
      return;
    }
    const px = this.getUIContext().vp2px(fingers[0].localX);
    const py = this.getUIContext().vp2px(fingers[0].localY);
    this.meterX = Math.min(1, Math.max(0, px / w));
    this.meterY = Math.min(1, Math.max(0, py / h));
  }

  private onMeterMoved(): void {
    this.updateMeterPoint();
    if (this.locked) {
      this.remeter();
    }
  }

  private computeSample(data: Uint8Array, w: number, h: number, stride: number): void {
    // 兼容模式实际看到的是画面正中的一块，测光也必须只在这块里取（换算见 cropScale）
    const crop: number = this.cropScale();
    const cx = w * (0.5 + (this.meterY - 0.5) / crop);
    const cy = h * (0.5 + (0.5 - this.meterX) / crop);
    const ringR = Math.max(2, (this.ringRatio() * w) / crop / 2);
    const refR = Math.max(4, 0.079 * w / crop);
    this.localY = this.regionMean(data, w, h, stride, cx, cy, ringR);
    this.refY = this.regionMean(data, w, h, stride, cx, cy, refR);
    if (this.meterMode === 'matrix') {
      this.matrixY = this.matrixMean(data, w, h, stride, crop);
    }
  }

  private matrixMean(data: Uint8Array, w: number, h: number, stride: number, crop: number): number {
    const COLS = 12;
    const ROWS = 16;
    // 原生变焦是相机端裁切，帧本身就是最终视场；兼容模式的裁切在这里按中心窗口算
    const visW = w / crop;
    const visH = h / crop;
    const ox = (w - visW) / 2;
    const oy = (h - visH) / 2;
    const cellW = visW / COLS;
    const cellH = visH / ROWS;

    let total = 0;
    let cells = 0;
    for (let r = 0; r < ROWS; r++) {
      for (let c = 0; c < COLS; c++) {
        const ccx = ox + (c + 0.5) * cellW;
        const ccy = oy + (r + 0.5) * cellH;
        let sum = 0;
        let n = 0;
        for (let dy = 0; dy < 4; dy++) {
          const py = Math.floor(ccy + (dy - 1.5) * cellH / 4);
          if (py < 0 || py >= h) {
            continue;
          }
          const rowOff = py * stride;
          for (let dx = 0; dx < 4; dx++) {
            const px = Math.floor(ccx + (dx - 1.5) * cellW / 4);
            if (px < 0 || px >= w) {
              continue;
            }
            const idx = rowOff + px;
            if (idx < data.length) {
              sum += data[idx];
              n++;
            }
          }
        }
        if (n > 0) {
          total += sum / n;
          cells++;
        }
      }
    }
    return cells > 0 ? total / cells : 0;
  }

  /** 点测圈占画面宽度的比例（缓存；屏幕尺寸变化时把 ringRatioCache 清 0 即可） */
  private ringRatio(): number {
    if (this.ringRatioCache > 0) {
      return this.ringRatioCache;
    }
    let screenW = 0;
    try {
      screenW = display.getDefaultDisplaySync().width;
    } catch (e) {
      screenW = 1272;
    }
    const previewW = screenW * Index.PREVIEW_WIDTH;
    this.ringRatioCache = previewW > 0 ? vp2px(Index.RING_VP) / previewW : 0.2;
    return this.ringRatioCache;
  }

  private regionMean(data: Uint8Array, w: number, h: number, stride: number,
    cx: number, cy: number, r: number): number {
    const x0 = Math.max(0, Math.floor(cx - r));
    const x1 = Math.min(w - 1, Math.ceil(cx + r));
    const y0 = Math.max(0, Math.floor(cy - r));
    const y1 = Math.min(h - 1, Math.ceil(cy + r));
    const step = Math.max(1, Math.floor(r / 6));
    let sum = 0;
    let cnt = 0;
    for (let y = y0; y <= y1; y += step) {
      const rowOff = y * stride;
      for (let x = x0; x <= x1; x += step) {
        const idx = rowOff + x;
        if (idx < data.length) {
          sum += data[idx];
          cnt++;
        }
      }
    }
    return cnt > 0 ? sum / cnt : 0;
  }

  private readOnce(): void {
    // 只有「按住启动测光」时才实时测；变焦中不测；锁定态走 remeter 从冻结帧算
    if (this.locked || this.zooming || !this.meteringOn) {
      return;
    }

    const iso = this.aeIso;
    const durationUs = this.aeDurationUs;
    if (!(iso > 0) || !(durationUs > 0)) {
      this.statusText = '等待 AE 回调…';
      return;
    }

    const shutterSec = durationUs / 1000000;
    let raw = ev100From(this.meteringAperture(), shutterSec, iso);

    const sampleY = this.meterMode === 'matrix' ? this.matrixY : this.localY;
    let corrected = false;
    if (this.analyzerReady && sampleY > 2 && this.refY > 2) {
      const ratio = Math.min(16, Math.max(0.0625, sampleY / this.refY));
      raw += 2.2 * Math.log2(ratio);
      corrected = true;
    }

    this.setRawEv(raw);
    this.evText = this.displayEv().toFixed(1);
    this.updateCombo();

    const key = `${iso}|${durationUs}|${this.localY.toFixed(0)}`;
    if (key === this.lastKey) {
      this.stableCount++;
    } else {
      this.stableCount = 0;
      this.lastKey = key;
    }
    if (!this.isCompat() && this.apMonitor.reading() === undefined) {
      // 普通模式下光圈还没测到，读数只是按兜底 f/2.2 估的。兼容模式光圈是常量，不用提示
      this.statusText = '测光中（光圈未定，按 f/2.2 估）';
      return;
    }
    if (this.stableCount >= 2) {
      this.statusText = corrected ? '读数稳定（局部测光）' : '读数稳定';
    }
  }
}
