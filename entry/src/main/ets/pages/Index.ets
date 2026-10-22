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
  APERTURE_LADDER,
  SHUTTER_LADDER,
  ISO_LADDER
} from '../common/Metering';

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

@Entry
@Component
struct Index {
  @State safeTop: number = 0;
  @State safeBottom: number = 0;
  @State evText: string = '--';
  @State statusText: string = '初始化…';
  @State meterModeText: string = '--';
  @State locked: boolean = false;

  @State cropZoom: number = 1.0;
  @State meterX: number = 0.5;
  @State meterY: number = 0.5;
  @State meterMode: string = 'spot';
  @State matrixY: number = 0;

  // 胶片 ISO
  @State filmIso: number = 100;
  @State isoIndex: number = 12;
  @State showIso: boolean = false;

  // 曝光组合：apLocked=true 表示 A 档（锁光圈），false 表示 S 档（锁快门）
  @State apLocked: boolean = true;
  @State apIndex: number = 21;
  @State shIndex: number = 20;
  @State apLabel: string = 'f/5.6';
  @State shLabel: string = '1/125';
  @State longExposure: boolean = false;
  @State outOfRange: boolean = false;
  @State errText: string = '';

  // 校准 / 曝光补偿
  @State biasEv: number = 0;
  @State showCalib: boolean = false;
  @State calibIndex: number = 50;
  @State expEv: number = 0;
  @State showExp: boolean = false;
  @State expIndex: number = 50;

  private apertureItems: string[] = [];
  private shutterItems: string[] = [];
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
  private pressStartMs: number = 0;
  private pressStartX: number = 0;
  private pressStartY: number = 0;

  private aeDurationUs: number = 0;
  private aeIso: number = 0;
  private lastRawEv: number = 0;

  private analyzeReceiver: image.ImageReceiver | undefined = undefined;
  private localY: number = 0;
  private refY: number = 0;
  private analyzerReady: boolean = false;
  private frameCount: number = 0;
  private frameSnapshot: Uint8Array | undefined = undefined;
  private snapW: number = 0;
  private snapH: number = 0;
  private enableAnalyzer: boolean = true;

  private static readonly PREVIEW_RATIO: number = 0.75;
  private static readonly PREVIEW_WIDTH: number = 0.70;
  private static readonly APERTURE: number = 2.2;
  private static readonly CAMERA_ZOOM: number = 0.8;
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

  private static readonly BLUE: string = '#4D9EFF';
  private static readonly LINE_ON: string = '#FFFFFF';
  private static readonly LINE_LOCKED: string = '#FF5C5C';

  aboutToAppear(): void {
    this.cropZoom = 1.0;
    this.locked = false;
    this.buildWheels();
    this.applySafeArea();
    this.registerAppState();
    this.loadSettings();
  }

  private buildWheels(): void {
    this.apertureItems = APERTURE_LADDER.map((v: number) => `f/${v}`);
    this.shutterItems = SHUTTER_LADDER.map((v: number) => formatShutterSecond(v));
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
    this.apLabel = `f/${APERTURE_LADDER[this.apIndex]}`;
    this.shLabel = this.shutterItems[this.shIndex];
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
      const locked = await store.get(Index.PREF_APLOCK, true) as boolean;
      this.apLocked = locked;

      const mode = await store.get(Index.PREF_METER, 'spot') as string;
      this.meterMode = mode === 'matrix' ? 'matrix' : 'spot';
      this.meterModeText = this.meterMode === 'matrix' ? '矩阵测光' : '点测光';

      const ap = await store.get(Index.PREF_AP, this.apIndex) as number;
      if (ap >= 0 && ap < APERTURE_LADDER.length) {
        this.apIndex = ap;
        this.apLabel = this.apertureItems[ap];
      }
      const sh = await store.get(Index.PREF_SH, this.shIndex) as number;
      if (sh >= 0 && sh < SHUTTER_LADDER.length) {
        this.shIndex = sh;
        this.shLabel = this.shutterItems[sh];
      }
      console.info(`[SETTINGS] loaded bias=${this.biasEv} exp=${this.expEv} iso=${this.filmIso} ` +
        `A=${this.apLocked} mode=${this.meterMode} ap=${this.apIndex} sh=${this.shIndex}`);
      this.refreshDisplay();
    } catch (e) {
      console.error('[SETTINGS] load failed');
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

  /** 退出/切后台前把当前状态记下来 */
  private saveState(): void {
    this.savePref(Index.PREF_BIAS, this.biasEv);
    this.savePref(Index.PREF_EXP, this.expEv);
    this.savePref(Index.PREF_ISO, this.filmIso);
    this.savePref(Index.PREF_APLOCK, this.apLocked);
    this.savePref(Index.PREF_METER, this.meterMode);
    this.savePref(Index.PREF_AP, this.apIndex);
    this.savePref(Index.PREF_SH, this.shIndex);
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
      await this.openCamera(ctx, this.surfaceId);

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

  private shutdown(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
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
    Column() {
      // 预览
      Stack() {
        Stack({ alignContent: Alignment.Center }) {
          XComponent({ id: 'preview', type: XComponentType.SURFACE, controller: this.xController })
            .width('100%')
            .height('100%')
            .scale({ x: this.cropZoom, y: this.cropZoom })
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
        // 变焦
        Row({ space: 8 }) {
          Text('变焦').fontSize(12).fontColor('#CCFFFFFF').width(40)
          Slider({ value: this.cropZoom, min: 1.0, max: 5.0, step: 0.1, style: SliderStyle.OutSet })
            .layoutWeight(1)
            .onChange((v: number) => {
              this.cropZoom = Math.round(v * 10) / 10;
            })
          Text(`${this.cropZoom.toFixed(1)}x`).fontSize(13).fontColor('#EEFFFFFF').width(44)
        }
        .width('100%')

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

          Button(this.locked ? '解除锁定' : '锁定曝光')
            .width(112)
            .height(56)
            .fontSize(15)
            .fontColor(Color.White)
            .backgroundColor(this.locked ? '#D9622B' : '#2E2E2E')
            .borderRadius(10)
            .onClick(() => {
              this.toggleLock();
            })
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
                TextPicker({ range: this.apertureItems, value: $$this.apLabel })
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
                    this.apIndex = index as number;
                    this.updateCombo();
                  })

                if (!this.apLocked) {
                  Column()
                    .width('100%')
                    .height(Index.PICKER_H)
                    .hitTestBehavior(HitTestMode.Block)
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
                TextPicker({ range: this.shutterItems, value: $$this.shLabel })
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

          Text(this.errText).fontSize(10).fontColor('#88FFFFFF')
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
    this.meterModeText = mode === 'matrix' ? '矩阵测光' : '点测光';
    this.applyMeterMode();
    this.savePref(Index.PREF_METER, mode);
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
      s.setMeteringPoint({ x: this.meterY, y: 1 - this.meterX });
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
      combo = comboFor(ev, this.filmIso, APERTURE_LADDER[this.apIndex]);
      if (combo.shutterIndex !== this.shIndex) {
        this.shIndex = combo.shutterIndex;
        this.shLabel = this.shutterItems[this.shIndex];
      }
    } else {
      combo = comboFromShutter(ev, this.filmIso, SHUTTER_LADDER[this.shIndex]);
      if (combo.apertureIndex !== this.apIndex) {
        this.apIndex = combo.apertureIndex;
        this.apLabel = this.apertureItems[this.apIndex];
      }
    }
    this.longExposure = combo.longExposure;
    this.outOfRange = combo.outOfRange;
    this.errText = combo.outOfRange ? '超出范围，换一档' : '误差 ≤1/6 档';
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
        s.setExposureMode(camera.ExposureMode.EXPOSURE_MODE_LOCKED);
        await s.stop();
      } else {
        await s.start();
        s.setExposureMode(camera.ExposureMode.EXPOSURE_MODE_AUTO);
        s.setZoomRatio(Index.CAMERA_ZOOM);
      }
      this.locked = next;
      this.statusText = next ? '画面与曝光已锁定' : '测光中';
      console.info(`[LOCK] ${next}`);
    } catch (e) {
      console.error(`[LOCK] failed code=${(e as BusinessError).code}`);
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

  private async openCamera(ctx: common.UIAbilityContext, surfaceId: string): Promise<void> {
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

    const cap = manager.getSupportedOutputCapability(dev, camera.SceneMode.NORMAL_PHOTO);
    if (cap.previewProfiles.length === 0) {
      this.statusText = '没有可用预览档位';
      return;
    }

    let profile: camera.Profile = cap.previewProfiles[0];
    let bestArea: number = -1;
    for (const p of cap.previewProfiles) {
      const r = p.size.width / p.size.height;
      if (Math.abs(r - 4 / 3) < 0.01) {
        const area = p.size.width * p.size.height;
        if (area > bestArea) {
          bestArea = area;
          profile = p;
        }
      }
    }

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
      }
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

    try {
      s.setZoomRatio(Index.CAMERA_ZOOM);
    } catch (e) {
      console.error(`[ZOOM] failed ${(e as BusinessError).code}`);
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
  }

  private async createAnalyzer(manager: camera.CameraManager,
    cap: camera.CameraOutputCapability, displayProfile: camera.Profile): Promise<camera.PreviewOutput | undefined> {
    const displayRatio = displayProfile.size.width / displayProfile.size.height;
    const profileWidth = displayProfile.size.width;

    let picked: camera.Profile | undefined = undefined;
    const sorted = cap.previewProfiles.slice()
      .sort((a, b) => Math.abs(a.size.width - profileWidth) - Math.abs(b.size.width - profileWidth));
    for (const pf of sorted) {
      const r = pf.size.width / pf.size.height;
      if (pf.format === displayProfile.format && Math.abs(r - displayRatio) <= 0.01) {
        picked = pf;
        break;
      }
    }
    if (picked === undefined) {
      return undefined;
    }

    try {
      const receiver = image.createImageReceiver(displayProfile.size, image.ImageFormat.JPEG, 8);
      const sid = await receiver.getReceivingSurfaceId();
      this.analyzeReceiver = receiver;
      this.listenFrames(receiver, displayProfile.size.width, displayProfile.size.height);
      this.analyzerReady = true;
      return manager.createPreviewOutput(picked, sid);
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[ANA] failed code=${err.code}`);
      return undefined;
    }
  }

  private listenFrames(receiver: image.ImageReceiver, w: number, h: number): void {
    receiver.on('imageArrival', () => {
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
    this.frameCount++;
    this.computeSample(buf, w, h, stride);
    if (this.frameCount % 3 === 0) {
      this.saveSnapshot(buf, w, h, stride);
    }
  }

  private saveSnapshot(buf: ArrayBuffer, w: number, h: number, stride: number): void {
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
    const src = new Uint8Array(buf);
    for (let y = 0; y < sh; y++) {
      const rowOff = (y * STEP) * stride;
      const dst = y * sw;
      for (let x = 0; x < sw; x++) {
        const idx = rowOff + x * STEP;
        snap[dst + x] = idx < src.length ? src[idx] : 0;
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
    let raw = ev100From(Index.APERTURE, shutterSec, iso);

    let screenW = 0;
    try {
      screenW = display.getDefaultDisplaySync().width;
    } catch (e) {
      screenW = 1272;
    }
    const ringPx = vp2px(Index.RING_VP);
    const previewW = screenW * Index.PREVIEW_WIDTH;
    const ringRatio = previewW > 0 ? ringPx / previewW : 0.2;
    const ringR = Math.max(1, (ringRatio * this.snapW / this.cropZoom) / 2);

    const scx = this.snapW * this.meterY;
    const scy = this.snapH * (1 - this.meterX);
    const localY = this.meterMode === 'matrix'
      ? this.matrixY
      : this.regionMeanSnap(scx, scy, ringR);

    if (this.refY > 2 && localY > 2) {
      const ratio = Math.min(16, Math.max(0.0625, localY / this.refY));
      raw += 2.2 * Math.log2(ratio);
    }

    this.lastRawEv = raw;
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

  private computeSample(buf: ArrayBuffer, w: number, h: number, stride: number): void {
    const data = new Uint8Array(buf);
    const cx = w * this.meterY;
    const cy = h * (1 - this.meterX);
    let screenW = 0;
    try {
      screenW = display.getDefaultDisplaySync().width;
    } catch (e) {
      screenW = 1272;
    }
    const ringPx = vp2px(Index.RING_VP);
    const previewW = screenW * Index.PREVIEW_WIDTH;
    const ringRatio = previewW > 0 ? ringPx / previewW : 0.2;
    const ringR = Math.max(2, (ringRatio * w / this.cropZoom) / 2);
    const refR = Math.max(4, 0.079 * w);
    this.localY = this.regionMean(data, w, h, stride, cx, cy, ringR);
    this.refY = this.regionMean(data, w, h, stride, cx, cy, refR);
    if (this.meterMode === 'matrix') {
      this.matrixY = this.matrixMean(data, w, h, stride);
    }
  }

  private matrixMean(data: Uint8Array, w: number, h: number, stride: number): number {
    const COLS = 12;
    const ROWS = 16;
    const zoom = this.cropZoom > 0.1 ? this.cropZoom : 1;
    const visW = w / zoom;
    const visH = h / zoom;
    const x0 = (w - visW) / 2;
    const y0 = (h - visH) / 2;
    const cellW = visW / COLS;
    const cellH = visH / ROWS;

    let total = 0;
    let cells = 0;
    for (let r = 0; r < ROWS; r++) {
      for (let c = 0; c < COLS; c++) {
        const ccx = x0 + (c + 0.5) * cellW;
        const ccy = y0 + (r + 0.5) * cellH;
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
    if (this.locked) {
      return;
    }

    const s = this.session;
    if (s) {
      try {
        if (Math.abs(s.getZoomRatio() - Index.CAMERA_ZOOM) > 0.03) {
          s.setZoomRatio(Index.CAMERA_ZOOM);
        }
      } catch (e) {
        // 忽略，下轮再试
      }
    }

    const iso = this.aeIso;
    const durationUs = this.aeDurationUs;
    if (!(iso > 0) || !(durationUs > 0)) {
      this.statusText = '等待 AE 回调…';
      return;
    }

    const shutterSec = durationUs / 1000000;
    let raw = ev100From(Index.APERTURE, shutterSec, iso);

    const sampleY = this.meterMode === 'matrix' ? this.matrixY : this.localY;
    let corrected = false;
    if (this.analyzerReady && sampleY > 2 && this.refY > 2) {
      const ratio = Math.min(16, Math.max(0.0625, sampleY / this.refY));
      raw += 2.2 * Math.log2(ratio);
      corrected = true;
    }

    this.lastRawEv = raw;
    this.evText = this.displayEv().toFixed(1);
    this.updateCombo();

    const key = `${iso}|${durationUs}|${this.localY.toFixed(0)}`;
    if (key === this.lastKey) {
      this.stableCount++;
    } else {
      this.stableCount = 0;
      this.lastKey = key;
    }
    if (this.stableCount >= 2) {
      this.statusText = corrected ? '读数稳定（局部测光）' : '读数稳定';
    }
  }
}
