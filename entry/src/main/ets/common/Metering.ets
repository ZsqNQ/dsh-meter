// 轻测光 · Light Meter for HarmonyOS
// Copyright (C) 2026 南秋 (nanqiu)
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * 测光核心算法（ArkTS 版）
 *
 * 目标路径：entry/src/main/ets/common/Metering.ets
 * 来源：reference/metering.mjs，已用 24 项用例在 Node 上验证过。
 *
 * 记号约定：
 *   N     光圈 f 值（物理值，如 5.657）
 *   t     快门时间，单位秒
 *   iso   感光度
 *   EV100 以 ISO100 为基准的曝光值 = log2(N²/t) - log2(iso/100)
 *
 * ⚠ 标称档位 ≠ 物理值。镜头刻 f/2.8，物理是 2.828；机身刻 1/125，物理是 1/128。
 *   算 EV 用物理值，给人看用标称值。
 */

export interface Stop {
  nominal: number;
  exact: number;
}

export interface ExposureRow {
  /** 光圈标称值，给用户看 */
  aperture: number;
  /** 快门标称显示，如 "1/125" */
  shutter: string;
  /** 快门物理秒数 */
  shutterExact: number;
  /** 该组合所需的理论（精确）快门秒数 */
  exactSeconds: number;
  /** 取整到最近档后残留的误差，单位：档 */
  errorStops: number;
  /** true 表示所需快门超出档位表范围，该组合拍不出来 */
  outOfRange: boolean;
}

const SQ2: number = Math.sqrt(2);

export const APERTURE_STOPS: Stop[] = [
  { nominal: 1.4, exact: SQ2 },
  { nominal: 2, exact: 2 },
  { nominal: 2.8, exact: 2 * SQ2 },
  { nominal: 4, exact: 4 },
  { nominal: 5.6, exact: 4 * SQ2 },
  { nominal: 8, exact: 8 },
  { nominal: 11, exact: 8 * SQ2 },
  { nominal: 16, exact: 16 },
  { nominal: 22, exact: 16 * SQ2 },
];

export const SHUTTER_STOPS: Stop[] = [
  { nominal: 1 / 8000, exact: 1 / 8192 },
  { nominal: 1 / 4000, exact: 1 / 4096 },
  { nominal: 1 / 2000, exact: 1 / 2048 },
  { nominal: 1 / 1000, exact: 1 / 1024 },
  { nominal: 1 / 500, exact: 1 / 512 },
  { nominal: 1 / 250, exact: 1 / 256 },
  { nominal: 1 / 125, exact: 1 / 128 },
  { nominal: 1 / 60, exact: 1 / 64 },
  { nominal: 1 / 30, exact: 1 / 32 },
  { nominal: 1 / 15, exact: 1 / 16 },
  { nominal: 1 / 8, exact: 1 / 8 },
  { nominal: 1 / 4, exact: 1 / 4 },
  { nominal: 1 / 2, exact: 1 / 2 },
  { nominal: 1, exact: 1 },
  { nominal: 2, exact: 2 },
  { nominal: 4, exact: 4 },
  { nominal: 8, exact: 8 },
  { nominal: 15, exact: 16 },
  { nominal: 30, exact: 32 },
];

/** 把秒数格式化成摄影师看的写法：1/125、1/2、2"、15" */
export function formatShutter(t: number): string {
  if (t >= 1) {
    return Number.isInteger(t) ? `${t}"` : `${t.toFixed(1)}"`;
  }
  return `1/${Math.round(1 / t)}`;
}

/** 由实测的 (光圈物理值, 快门秒数, ISO) 反算 EV100 */
export function ev100From(apertureExact: number, shutterSeconds: number, iso: number): number {
  if (!(apertureExact > 0) || !(shutterSeconds > 0) || !(iso > 0)) {
    throw new Error('ev100From: 参数必须为正数');
  }
  return Math.log2((apertureExact * apertureExact) / shutterSeconds) - Math.log2(iso / 100);
}

/** 给定 EV100、光圈物理值、ISO，算理论快门秒数 */
export function shutterSecondsFor(ev100: number, apertureExact: number, iso: number): number {
  return (apertureExact * apertureExact) / (Math.pow(2, ev100) * (iso / 100));
}

/** 在快门档位里找物理值最接近的档 */
export function nearestShutterStop(shutterSeconds: number): Stop {
  const target: number = Math.log2(shutterSeconds);
  let best: Stop = SHUTTER_STOPS[0];
  let bestDist: number = Number.MAX_VALUE;
  for (const s of SHUTTER_STOPS) {
    const d: number = Math.abs(Math.log2(s.exact) - target);
    if (d < bestDist) {
      bestDist = d;
      best = s;
    }
  }
  return best;
}

/** 在光圈档位里找物理值最接近的档（传入物理值） */
export function nearestApertureStop(apertureExact: number): Stop {
  const target: number = Math.log2(apertureExact);
  let best: Stop = APERTURE_STOPS[0];
  let bestDist: number = Number.MAX_VALUE;
  for (const n of APERTURE_STOPS) {
    const d: number = Math.abs(Math.log2(n.exact) - target);
    if (d < bestDist) {
      bestDist = d;
      best = n;
    }
  }
  return best;
}

/** 测光表的正经输出：给定 EV100 与胶片 ISO，为每个光圈给出应使用的快门档 */
export function exposureTable(ev100: number, iso: number, stops: Stop[] = APERTURE_STOPS): ExposureRow[] {
  const fastest: number = SHUTTER_STOPS[0].exact;
  const slowest: number = SHUTTER_STOPS[SHUTTER_STOPS.length - 1].exact;
  const rows: ExposureRow[] = [];
  for (const s of stops) {
    const exactSeconds: number = shutterSecondsFor(ev100, s.exact, iso);
    const stop: Stop = nearestShutterStop(exactSeconds);
    rows.push({
      aperture: s.nominal,
      shutter: formatShutter(stop.nominal),
      shutterExact: stop.exact,
      exactSeconds: exactSeconds,
      errorStops: Math.abs(Math.log2(exactSeconds / stop.exact)),
      outOfRange: exactSeconds < fastest || exactSeconds > slowest,
    });
  }
  return rows;
}

/** 一次性校准偏置：手机 AE 曲线与标准测光表的系统偏差（正数=读数偏高） */
export function applyCalibration(ev100: number, biasEv: number = 0): number {
  return ev100 + biasEv;
}

/**
 * 1/3 档档位表（路线文档第 6 条）
 * 光圈 f/0.5~f/64、快门 1/16000s~60s、ISO 6~6400，全部按 1/3 档递进。
 * 标称值即档位刻字，算 EV 时直接用这些值（与 1/3 档序列的物理值差 <0.05 档，可忽略）。
 */
export const APERTURE_LADDER: number[] = [
  0.5, 0.56, 0.63, 0.7, 0.8, 0.9, 1, 1.1, 1.2, 1.4, 1.6, 1.8, 2, 2.2, 2.5, 2.8,
  3.2, 3.5, 4, 4.5, 5, 5.6, 6.3, 7.1, 8, 9, 10, 11, 13, 14, 16, 18, 20, 22, 25, 29,
  32, 36, 40, 45, 50, 57, 64
];

export const SHUTTER_LADDER: number[] = [
  1 / 16000, 1 / 12800, 1 / 10000, 1 / 8000, 1 / 6400, 1 / 5000, 1 / 4000, 1 / 3200,
  1 / 2500, 1 / 2000, 1 / 1600, 1 / 1250, 1 / 1000, 1 / 800, 1 / 640, 1 / 500,
  1 / 400, 1 / 320, 1 / 250, 1 / 200, 1 / 160, 1 / 125, 1 / 100, 1 / 80,
  1 / 60, 1 / 50, 1 / 40, 1 / 30, 1 / 25, 1 / 20, 1 / 15, 1 / 13,
  1 / 10, 1 / 8, 1 / 6, 1 / 5, 1 / 4, 1 / 3, 0.4, 0.5,
  0.6, 0.8, 1, 1.3, 1.6, 2, 2.5, 3,
  4, 5, 6, 8, 10, 13, 15, 20,
  25, 30, 40, 50, 60
];

export const ISO_LADDER: number[] = [
  6, 8, 10, 12, 16, 20, 25, 32, 40, 50, 64, 80, 100, 125, 160, 200,
  250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400
];

/** 一个可直接照抄的曝光组合 */
export interface Combo {
  /** 光圈标称值 */
  aperture: number;
  /** 光圈在档位表里的下标 */
  apertureIndex: number;
  /** 快门秒数（取档位表里的值） */
  shutter: number;
  /** 快门在档位表里的下标 */
  shutterIndex: number;
  /** 快门显示：1/125 或 2s */
  shutterText: string;
  /** 取整到 1/3 档后残留误差，单位档 */
  errorStops: number;
  /** 理论需求值：A 档是所需快门秒数，S 档是所需光圈 f 值；用于判断超出哪一端 */
  exact: number;
  /** 所需快门超出 1/16000~60s */
  outOfRange: boolean;
  /** 慢于 1s：胶片会倒易律失效 */
  longExposure: boolean;
}

/** 快门显示规则：快于 1s 写分数，1s 及更慢写 Xs */
export function formatShutterSecond(t: number): string {
  if (t >= 1) {
    return Number.isInteger(t) ? `${t}s` : `${t.toFixed(1)}s`;
  }
  // 0.4~1s 之间用小数（1/1、1/2 这种写法会误导），更快才用分数
  if (t >= 0.4) {
    return `${t.toFixed(1)}s`;
  }
  return `1/${Math.round(1 / t)}`;
}

/** 在升序档位表里按对数距离找最近的档，返回下标 */
export function nearestIndexByLog(value: number, ladder: number[]): number {
  if (!(value > 0) || ladder.length === 0) {
    return 0;
  }
  const target: number = Math.log2(value);
  let best: number = 0;
  let bestDist: number = Number.MAX_VALUE;
  for (let i = 0; i < ladder.length; i++) {
    const d: number = Math.abs(Math.log2(ladder[i]) - target);
    if (d < bestDist) {
      bestDist = d;
      best = i;
    }
  }
  return best;
}

/** 给定 EV100、胶片 ISO、光圈，算出该组合的快门（取最近的 1/3 档） */
export function comboFor(ev100: number, iso: number, aperture: number): Combo {
  const exactSeconds: number = (aperture * aperture) / (Math.pow(2, ev100) * (iso / 100));
  const fastest: number = SHUTTER_LADDER[0];
  const slowest: number = SHUTTER_LADDER[SHUTTER_LADDER.length - 1];
  const outOfRange: boolean = !(exactSeconds > 0) || exactSeconds < fastest || exactSeconds > slowest;

  const idx: number = nearestIndexByLog(exactSeconds, SHUTTER_LADDER);
  const shutterIndex: number = Math.min(SHUTTER_LADDER.length - 1, Math.max(0, idx));
  const shutter: number = SHUTTER_LADDER[shutterIndex];
  const errorStops: number = exactSeconds > 0 ? Math.abs(Math.log2(exactSeconds / shutter)) : 0;

  return {
    aperture: aperture,
    apertureIndex: Math.max(0, APERTURE_LADDER.indexOf(aperture)),
    shutter: shutter,
    shutterIndex: shutterIndex,
    shutterText: formatShutterSecond(shutter),
    errorStops: errorStops,
    exact: exactSeconds,
    outOfRange: outOfRange,
    longExposure: shutter > 1
  };
}

/**
 * S 档方向：给定 EV100、胶片 ISO、快门，反算光圈。
 * 和 comboFor 互为镜像，用于「锁快门、算光圈」。
 */
export function comboFromShutter(ev100: number, iso: number, shutter: number): Combo {
  const exactAperture: number = Math.sqrt(shutter * Math.pow(2, ev100) * (iso / 100));
  const apertureIndex: number = nearestIndexByLog(exactAperture, APERTURE_LADDER);
  const aperture: number = APERTURE_LADDER[apertureIndex];

  const fastest: number = SHUTTER_LADDER[0];
  const slowest: number = SHUTTER_LADDER[SHUTTER_LADDER.length - 1];
  const outOfRange: boolean = !(exactAperture > 0) || aperture <= APERTURE_LADDER[0] ||
    aperture >= APERTURE_LADDER[APERTURE_LADDER.length - 1];

  const exactSeconds: number = (aperture * aperture) / (Math.pow(2, ev100) * (iso / 100));
  const errorStops: number = exactSeconds > 0 ? Math.abs(Math.log2(exactSeconds / shutter)) : 0;

  return {
    aperture: aperture,
    apertureIndex: apertureIndex,
    shutter: shutter,
    shutterIndex: Math.max(0, SHUTTER_LADDER.indexOf(shutter)),
    shutterText: formatShutterSecond(shutter),
    errorStops: errorStops,
    exact: exactAperture,
    outOfRange: outOfRange || shutter < fastest || shutter > slowest,
    longExposure: shutter > 1
  };
}


/** EV 分档文案 */
export function describeEv(ev100: number): string {
  if (ev100 >= 15) return '烈日 / 雪地海边';
  if (ev100 >= 13) return '晴天顺光';
  if (ev100 >= 11) return '薄云晴天 / 阴天明亮';
  if (ev100 >= 9) return '阴天 / 树荫';
  if (ev100 >= 7) return '室内明亮 / 傍晚';
  if (ev100 >= 5) return '室内一般照明 / 夜景街道';
  if (ev100 >= 3) return '昏暗室内';
  if (ev100 >= 1) return '弱光 / 烛光附近';
  return '极弱光';
}

// ---------------- 变焦滑条映射（v1.2 原生 zoom） ----------------

/**
 * 手机 zoom 范围（测试机 MRT-AL10 是 0.55~100）直接线性铺在滑条上，1x 会挤在最左边
 * 0.5% 的位置，没法用；纯对数刻度能拖，但 10x 以上的数字变焦会白占 44% 行程。
 *
 * 所以分两段：
 *   光学/混合段  min ~ 10x  占 75% 行程，对数分布（每翻一倍一样长）
 *   数字变焦段  10x ~ max   占 25% 行程，同样对数分布
 * 设备上限本来就 <=10x 时只有一段，退化成纯对数刻度。
 * 与 reference/metering.mjs 同一套实现，那边有 43 项 Node 用例把关。
 */
export const ZOOM_SPLIT_RATIO: number = 10;
export const ZOOM_OPTICAL_SHARE: number = 0.75;

export function zoomToSliderPos(ratio: number, minRatio: number, maxRatio: number,
  span: number = 1000): number {
  if (!(minRatio > 0) || !(maxRatio > minRatio)) {
    return 0;
  }
  const r: number = Math.min(maxRatio, Math.max(minRatio, ratio));
  const split: number = Math.min(Math.max(ZOOM_SPLIT_RATIO, minRatio), maxRatio);
  if (split >= maxRatio) {
    const t: number = Math.log(r / minRatio) / Math.log(maxRatio / minRatio);
    return Math.round(t * span);
  }
  if (r <= split) {
    const t: number = Math.log(r / minRatio) / Math.log(split / minRatio);
    return Math.round(t * span * ZOOM_OPTICAL_SHARE);
  }
  const t: number = Math.log(r / split) / Math.log(maxRatio / split);
  return Math.round((ZOOM_OPTICAL_SHARE + (1 - ZOOM_OPTICAL_SHARE) * t) * span);
}

export function sliderPosToZoom(pos: number, minRatio: number, maxRatio: number,
  span: number = 1000): number {
  if (!(minRatio > 0) || !(maxRatio > minRatio)) {
    return 1;
  }
  const t: number = Math.min(1, Math.max(0, pos / span));
  const split: number = Math.min(Math.max(ZOOM_SPLIT_RATIO, minRatio), maxRatio);
  if (split >= maxRatio) {
    return minRatio * Math.pow(maxRatio / minRatio, t);
  }
  if (t <= ZOOM_OPTICAL_SHARE) {
    return minRatio * Math.pow(split / minRatio, t / ZOOM_OPTICAL_SHARE);
  }
  return split * Math.pow(maxRatio / split, (t - ZOOM_OPTICAL_SHARE) / (1 - ZOOM_OPTICAL_SHARE));
}

/** 变焦显示：>=10 取整，1~10 一位小数，<1 保留两位（0.55x 不能显示成 0.6x） */
export function formatZoom(ratio: number): string {
  if (!(ratio > 0)) {
    return '--';
  }
  if (ratio >= 10) {
    return `${Math.round(ratio)}x`;
  }
  if (ratio >= 1) {
    return `${ratio.toFixed(1)}x`;
  }
  return `${Math.round(ratio * 100) / 100}x`;
}
