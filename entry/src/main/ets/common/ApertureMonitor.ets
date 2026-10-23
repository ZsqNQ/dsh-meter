// 轻测光 · Light Meter for HarmonyOS
// Copyright (C) 2026 南秋 (nanqiu)
// SPDX-License-Identifier: AGPL-3.0-or-later

import { camera } from '@kit.CameraKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ShotReader, ShotMeta } from './ShotAperture';

/**
 * 光圈 / 镜头监视器（v1.2 需求 2、3）
 *
 * 两条数据分支：
 *   (1) 机型 API 能读光圈（getPhysicalAperture() > 0）→ 直接读，不拍照；
 *   (2) API 恒 0（本机 MRT-AL10 就是）→ 每 0.5s 静默拍一张低分辨率照片读 EXIF，
 *       读完立刻释放不落盘；按下锁定瞬间补拍一张；锁定期间停轮询，解除后恢复。
 *
 * 保护层（两条路共用，即使 (1) 可用也不跳过）：
 *   - 只接受 >0、有限、落在 [0.9, 45] 的光圈值，其余丢掉；
 *   - EV 永远只用「最近一次通过校验的读数」，拿不到就沿用上一次 / 退回常量，绝不喂 0 给 log2；
 *   - 跨帧突变超过 1 档、或等效焦距跳变时判定为「疑似陈旧」，补拍一张取后一张；
 *   - API 与 EXIF 都有值时互相校验（差 >1 档记 [AP] mismatch，采用 EXIF，因为它是拍摄那一刻的真实值）。
 */

export interface ApReading {
  aperture: number;
  /** EXIF FocalLength 物理焦距（mm）——真正能区分镜头的字段 */
  focal: number;
  /** EXIF FocalLengthIn35mmFilm：实测 = 24 × 当前 zoom，只反映数码变焦，不能用来认镜头 */
  focal35: number;
  ts: number;
}

export const APERTURE_MIN: number = 0.9;
export const APERTURE_MAX: number = 45;
/**
 * 兜底轮询间隔。
 *
 * 文档写的是「每 0.5 秒左右拍一次」，但实测这么拍会把预览拖卡（不管变没变焦），
 * 原因是每次静默拍照都要让 HAL 在预览/拍照之间重配一次，代价远大于读 EXIF。
 * 所以改成：变焦停稳后必拍一张 + 平时 2 秒兜底一次。
 * 光圈实际只在换镜头时变；可变光圈随 AE 变时曝光时间会同步补偿，算出的 EV 不会因此跑偏。
 */
export const POLL_INTERVAL_MS: number = 2000;

export function isApertureSane(v: number): boolean {
  return Number.isFinite(v) && v >= APERTURE_MIN && v <= APERTURE_MAX;
}

export class ApertureMonitor {
  private reader: ShotReader = new ShotReader();
  private session: camera.PhotoSession | undefined = undefined;
  private last: ApReading | undefined = undefined;
  /** 还没测到任何值时用的兜底光圈（f/2.2，旧版常量） */
  private fallbackAperture: number = 2.2;
  private polling: boolean = false;
  private busy: boolean = false;
  private timer: number = -1;
  private shotCount: number = 0;
  private pollIntervalMs: number = POLL_INTERVAL_MS;
  /** 上次成功 capture 的时刻：相机两次拍照之间要留够间隔，否则被拒 7400102 */
  private lastShotMs: number = 0;
  private static readonly MIN_SHOT_GAP_MS: number = 400;
  private warmedUp: boolean = false;
  private onUpdate: (r: ApReading) => void = (r: ApReading) => {};

  /** 建 PhotoOutput（调用方要把它 addOutput 进 session） */
  async prepare(manager: camera.CameraManager,
    cap: camera.CameraOutputCapability): Promise<camera.PhotoOutput | undefined> {
    return this.reader.prepare(manager, cap);
  }

  bind(session: camera.PhotoSession, onUpdate: (r: ApReading) => void): void {
    this.session = session;
    this.onUpdate = onUpdate;
  }

  /** 当前可用光圈：只认通过校验的最近一次读数 */
  aperture(): number {
    const r = this.last;
    if (r !== undefined && isApertureSane(r.aperture)) {
      return r.aperture;
    }
    return this.fallbackAperture;
  }

  focal(): number {
    const r = this.last;
    return r === undefined ? 0 : r.focal;
  }

  reading(): ApReading | undefined {
    return this.last;
  }

  isPolling(): boolean {
    return this.polling;
  }

  /** 标定阶段已经成功拍过照，等价于热机完成，省掉一次空拍 */
  noteWarmed(): void {
    this.warmedUp = true;
  }

  isWarmed(): boolean {
    return this.warmedUp;
  }

  setPollInterval(ms: number): void {
    this.pollIntervalMs = Math.max(200, ms);
  }

  /** 首次真正要拍照前热机一次（不重复跑） */
  async warmUp(): Promise<void> {
    if (this.warmedUp || this.busy) {
      return;
    }
    this.busy = true;
    try {
      const meta = await this.reader.shoot();
      this.warmedUp = meta !== undefined;
      console.info(`[EXIF] warmUp ${this.warmedUp ? 'ok' : 'failed'}`);
    } finally {
      this.busy = false;
    }
  }

  startPolling(): void {
    if (this.polling) {
      return;
    }
    this.polling = true;
    console.info(`[AP] polling start (${this.pollIntervalMs}ms)`);
    // 第一张尽快拍，但要和上一张拉开最小间隔，否则相机直接拒（7400102）
    const since: number = Date.now() - this.lastShotMs;
    const delay: number = since >= ApertureMonitor.MIN_SHOT_GAP_MS ?
      0 : ApertureMonitor.MIN_SHOT_GAP_MS - since;
    this.schedule(delay);
  }

  stopPolling(): void {
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    if (this.polling) {
      console.info('[AP] polling stop');
    }
    this.polling = false;
  }

  /**
   * 连拍若干张、只收集等效35mm焦距（不改变既有读数），用于首启标定「1x 对应多少 mm」。
   */
  async sampleFocal35(times: number, gapMs: number): Promise<number[]> {
    const out: number[] = [];
    for (let i = 0; i < times; i++) {
      if (i > 0) {
        await this.delay(gapMs);
      }
      if (this.busy) {
        continue;
      }
      this.busy = true;
      try {
        const meta = await this.reader.shoot();
        if (meta !== undefined && meta.focal35 > 0) {
          out.push(meta.focal35);
        }
      } catch (e) {
        // ignore
      } finally {
        this.busy = false;
      }
      this.lastShotMs = Date.now();
    }
    console.info(`[BASE] f35 samples=[${out.join(',')}]`);
    return out;
  }

  /**
   * 立刻拍一张并采用（锁定瞬间 / 解除锁定后校准用）。
   * 如果正好有一次轮询在拍，先等它结束（最多 800ms），否则锁定那一张会被静默丢掉。
   */
  async shootNow(): Promise<void> {
    const deadline: number = Date.now() + 800;
    while (this.busy && Date.now() < deadline) {
      await this.delay(40);
    }
    if (this.busy) {
      console.error('[AP] shootNow skipped: still busy');
      return;
    }
    await this.pollOnce();
    const r = this.last;
    if (r !== undefined) {
      console.info(`[AP] fixed reading f/${r.aperture} focal=${r.focal}mm`);
    }
  }

  /** 页面销毁 / 切后台：停轮询并释放接收端 */
  stopAll(): void {
    this.stopPolling();
    this.reader.release();
    this.session = undefined;
  }

  private schedule(delay: number): void {
    if (!this.polling) {
      return;
    }
    this.timer = setTimeout(() => {
      this.tick();
    }, delay);
  }

  private async tick(): Promise<void> {
    if (!this.polling) {
      return;
    }
    try {
      await this.pollOnce();
    } finally {
      // 用「跑完再排下一次」而不是 setInterval，避免拍照慢时任务堆积
      this.schedule(this.pollIntervalMs);
    }
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  private async pollOnce(): Promise<void> {
    if (this.busy) {
      return;
    }
    const s = this.session;
    if (s === undefined) {
      return;
    }
    this.busy = true;
    try {
      let meta: ShotMeta | undefined = await this.reader.shoot();
      if (meta === undefined) {
        return;
      }
      this.lastShotMs = Date.now();
      if (this.suspicious(meta)) {
        // EXIF 有帧延迟：变焦/换镜头后第一张可能带着上一颗镜头的值，补拍一张取后者
        await this.delay(120);
        const second: ShotMeta | undefined = await this.reader.shoot();
        if (second !== undefined) {
          meta = second;
        }
      }
      this.accept(meta, s);
    } catch (e) {
      console.error(`[AP] poll failed E${(e as BusinessError).code}`);
    } finally {
      this.busy = false;
    }
  }

  /** 判据：值不合理、或与上一次差得离谱（光圈突变超 1 档 / 等效焦距跳变） */
  private suspicious(m: ShotMeta): boolean {
    if (!isApertureSane(m.aperture)) {
      return true;
    }
    const last = this.last;
    if (last === undefined) {
      return false;
    }
    if (m.focal > 0 && last.focal > 0 && Math.abs(m.focal - last.focal) > 0.5) {
      // 物理焦距跳了 = 换镜头了，这一张可能还带着旧镜头的光圈
      return true;
    }
    return Math.abs(Math.log2(m.aperture / last.aperture)) > 1;
  }

  private accept(m: ShotMeta, s: camera.PhotoSession): void {
    this.shotCount++;

    let apiValue: number = 0;
    try {
      apiValue = s.getPhysicalAperture();
    } catch (e) {
      apiValue = 0;
    }

    if (!isApertureSane(m.aperture)) {
      console.error(`[AP] reject exif aperture=${m.aperture} f35=${m.focal35} api=${apiValue}`);
      return;
    }

    if (isApertureSane(apiValue)) {
      const diff: number = Math.abs(Math.log2(apiValue / m.aperture));
      if (diff > 1) {
        console.warn(`[AP] mismatch api=${apiValue} exif=${m.aperture} ` +
          `diff=${diff.toFixed(2)}stop -> 采用 EXIF`);
      }
    }

    const reading: ApReading = {
      aperture: m.aperture,
      focal: m.focal,
      focal35: m.focal35,
      ts: Date.now()
    };
    this.last = reading;
    console.info(`[AP] got f/${m.aperture} focal=${m.focal}mm f35=${m.focal35} ` +
      `api=${apiValue} shots=${this.shotCount}`);
    this.onUpdate(reading);
  }
}
