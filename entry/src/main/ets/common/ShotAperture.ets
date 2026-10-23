// 轻测光 · Light Meter for HarmonyOS
// Copyright (C) 2026 南秋 (nanqiu)
// SPDX-License-Identifier: AGPL-3.0-or-later

import { camera } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 静默拍一张、读 EXIF 里的光圈与焦距（v1.2）
 *
 * 为什么要有它：MRT-AL10 上 getPhysicalAperture() 恒 0、getSupportedPhysicalApertures() 空数组，
 * 光圈只能从照片 EXIF 拿。EXIF 的 FocalLengthIn35mmFilm 还能顺带说明此刻在工作的是哪颗镜头
 * （这台机器镜头组是 13 / 24 / 88mm 等效）。
 *
 * 拍出来的图不给用户看也不落库：PhotoOutput 直接输出到 ImageReceiver 的 surface，
 * 读完立刻 release，等同「读完就删」。用最小可用的 4:3 拍照档，避免轮询把预览拖卡。
 *
 * 注意 EXIF 值不是标准 a/b 格式，厂商给的是 "f/2.2"、"1.8 mm"、"1/100 sec." 这种，
 * 解析必须容忍前后缀（第一版就栽在这，光圈一直读成 0）。
 */

export interface ShotMeta {
  /** EXIF FNumber，读不到给 0 */
  aperture: number;
  /** EXIF FocalLengthIn35mmFilm（等效焦距，mm），读不到给 0 */
  focal35: number;
  /** EXIF FocalLength（物理焦距，mm），读不到给 0 */
  focal: number;
}

/**
 * 抽数字：有 "/" 且能抽到两个数就做除法（"1/100 sec." → 0.01），否则取第一个数（"f/2.2" → 2.2）。
 */
function parseRational(text: string): number {
  const nums: number[] = [];
  let cur: string = '';
  for (let i = 0; i < text.length; i++) {
    const ch: string = text.charAt(i);
    const digit: boolean = ch >= '0' && ch <= '9';
    if (digit || (ch === '.' && cur.length > 0)) {
      cur += ch;
    } else if (cur.length > 0) {
      const v: number = Number(cur);
      if (Number.isFinite(v)) {
        nums.push(v);
      }
      cur = '';
    }
  }
  if (cur.length > 0) {
    const v: number = Number(cur);
    if (Number.isFinite(v)) {
      nums.push(v);
    }
  }
  if (nums.length === 0) {
    return 0;
  }
  if (text.indexOf('/') >= 0 && nums.length >= 2) {
    return nums[1] > 0 ? nums[0] / nums[1] : 0;
  }
  return nums[0];
}

export class ShotReader {
  private ReceiverNote: string = '';
  private rawKey: string = '';
  private receiver: image.ImageReceiver | undefined = undefined;
  private output: camera.PhotoOutput | undefined = undefined;
  private sizeText: string = '';

  /** 建接收端和 PhotoOutput（调用方负责把它 addOutput 进 session） */
  async prepare(manager: camera.CameraManager,
    cap: camera.CameraOutputCapability): Promise<camera.PhotoOutput | undefined> {
    let picked: camera.Profile | undefined = undefined;
    let bestArea: number = Number.MAX_VALUE;
    for (const p of cap.photoProfiles) {
      const r = p.size.width / p.size.height;
      if (Math.abs(r - 4 / 3) > 0.02) {
        continue;
      }
      const area = p.size.width * p.size.height;
      if (area < bestArea) {
        bestArea = area;
        picked = p;
      }
    }
    if (picked === undefined) {
      console.error('[EXIF] no 4:3 photo profile');
      return undefined;
    }
    try {
      this.receiver = image.createImageReceiver(picked.size, image.ImageFormat.JPEG, 2);
      const sid = await this.receiver.getReceivingSurfaceId();
      this.output = manager.createPhotoOutput(picked, sid);
      this.sizeText = `${picked.size.width}x${picked.size.height}`;
      console.info(`[EXIF] photo profile ${this.sizeText}`);
      return this.output;
    } catch (e) {
      console.error(`[EXIF] prepare failed E${(e as BusinessError).code}`);
      return undefined;
    }
  }

  /** 预热：某些机型第一次 capture 到 surface 很慢/直接丢，先空打一张把管道捂热 */
  async warmUp(): Promise<void> {
    const meta = await this.shoot();
    console.info(`[EXIF] warmUp ${meta === undefined ? 'failed' : 'ok'}`);
  }

  /** 拍一张并解析 EXIF；1.5s 没等到图就放弃，绝不让调用方卡死 */
  async shoot(): Promise<ShotMeta | undefined> {
    const out = this.output;
    const rec = this.receiver;
    if (out === undefined || rec === undefined) {
      return undefined;
    }

    let settled: boolean = false;
    let resolveFn: (v: image.Image | undefined) => void = (v: image.Image | undefined) => {};
    const waiting: Promise<image.Image | undefined> =
      new Promise<image.Image | undefined>((resolve: (v: image.Image | undefined) => void) => {
        resolveFn = resolve;
      });

    const timerId: number = setTimeout(() => {
      if (!settled) {
        settled = true;
        console.error('[EXIF] shot timeout');
        resolveFn(undefined);
      }
    }, 1500);

    try {
      rec.readNextImage((err: BusinessError, img: image.Image) => {
        if (settled) {
          if (img !== undefined) {
            img.release();
          }
          return;
        }
        settled = true;
        clearTimeout(timerId);
        if (err || img === undefined) {
          resolveFn(undefined);
        } else {
          resolveFn(img);
        }
      });
      await out.capture();
    } catch (e) {
      settled = true;
      clearTimeout(timerId);
      console.error(`[EXIF] capture failed E${(e as BusinessError).code}`);
      return undefined;
    }

    const img = await waiting;
    if (img === undefined) {
      return undefined;
    }

    let meta: ShotMeta = { aperture: 0, focal35: 0, focal: 0 };
    let source: image.ImageSource | undefined = undefined;
    try {
      const comp: image.Component = await img.getComponent(image.ComponentType.JPEG);
      if (comp.byteBuffer === undefined) {
        console.error('[EXIF] empty buffer');
        return undefined;
      }
      source = image.createImageSource(comp.byteBuffer);
      const fNum: string = await source.getImageProperty(image.PropertyKey.F_NUMBER);
      const f35: string = await source.getImageProperty(image.PropertyKey.FOCAL_LENGTH_IN_35_MM_FILM);
      const fl: string = await source.getImageProperty(image.PropertyKey.FOCAL_LENGTH);
      meta = { aperture: parseRational(fNum), focal35: parseRational(f35), focal: parseRational(fl) };
      // 原始串只在变化时打一行，便于核对解析有没有歪（厂商写法五花八门）
      const rawKey: string = `${fNum}|${f35}|${fl}`;
      if (rawKey !== this.rawKey) {
        this.rawKey = rawKey;
        console.info(`[EXIF] raw FNumber="${fNum}" FocalLengthIn35mmFilm="${f35}" FocalLength="${fl}"`);
      }
    } catch (e) {
      console.error(`[EXIF] read props failed E${(e as BusinessError).code}`);
    } finally {
      try {
        if (source !== undefined) {
          await source.release();
        }
      } catch (e) {
        // ignore
      }
      try {
        await img.release();
      } catch (e) {
        // ignore
      }
    }
    return meta;
  }

  release(): void {
    if (this.receiver !== undefined) {
      try {
        this.receiver.release();
      } catch (e) {
        // ignore
      }
      this.receiver = undefined;
    }
    this.output = undefined;
  }
}
