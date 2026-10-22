# 开发笔记 / 踩坑记录

这份文档记录实现细节和真机踩过的坑，接手或二次开发前建议先读。

## 1. 整体结构

| 文件 | 职责 |
|---|---|
| `entry/src/main/ets/pages/Index.ets` | 全部 UI + 相机会话 + 帧采样 + 测光状态 |
| `entry/src/main/ets/common/Metering.ets` | 纯算法：EV 计算、1/3 档档位表、曝光组合 |

数据流：

```
CameraKit 预览 ──► XComponent（显示）
              └──► ImageReceiver（取 Y 平面）──► 亮度统计 ──┐
onIsoInfoChange / onExposureInfoChange ──► ISO、快门 ──► ev100From
                                                        │
                          EV = ev100 + 2.2·log2(局部亮度/基准亮度) + 校准 + 曝光补偿
                                                        │
                                              1/3 档光圈/快门组合表
```

## 2. 相机

### 2.1 双路预览必须用 `getComponent(ComponentType.JPEG)`

最隐蔽的坑。第二路 PreviewOutput 挂到 ImageReceiver 后，取帧要用 **JPEG** 分量：

```ts
const receiver = image.createImageReceiver(size, image.ImageFormat.JPEG, 8);
nextImage.getComponent(image.ComponentType.JPEG, (err, comp) => {
  // comp.byteBuffer 就是 Y 平面，rowStride === width
  nextImage.release();   // 每帧必须释放
});
```

用 `ComponentType.YUV_Y` 时应用进程**静默消失**（无任何崩溃日志）。即便相机流是 `CAMERA_FORMAT_YUV_420_SP`，也要用 JPEG 取。

诊断方法：在帧回调里打点。回调没打印 = 崩在 `getComponent`；打印了 = 崩在别处。

### 2.2 AE 参数只能从回调拿

- `getIso()` / `getExposureDuration()` 只返回应用自己 `set` 过的值，AUTO 下返回 0
- 真实值来自 `onExposureInfoChange`（微秒）与 `onIsoInfoChange`
- `getExposureValue()` 返回的是**曝光补偿值**，不是场景 EV
- `getPhysicalAperture()` / `getSupportedPhysicalApertures()` 在测试机型上恒为 0 / 空数组，光圈只能当常量

### 2.3 前后台切换必须处理

```ts
onApplicationBackground: () => { this.shutdown(); },
onApplicationForeground: () => { if (!this.session) this.reopenCamera(); }
```

不处理会导致：锁定后切后台、再切回来解除锁定时画面卡死（相机资源被回收，`start()` 静默失败）。
`shutdown()` 里不要重置锁定标记，重建后要重新 `setExposureMode(LOCKED)` + `stop()` 恢复冻结。

## 3. 测光算法

```
EV100 = log2(N² / t) - log2(ISO / 100)
EV    = EV100 + 2.2·log2(局部亮度 / 基准亮度) + 校准 + 曝光补偿
```

- `2.2` 是 gamma 近似
- 基准亮度取准星同心的较大区域（相机 AE 收敛后它接近 18% 灰），两路亮度比可消掉绝对曝光，因此不需要硬件标定
- 点测：准星圈内均值；矩阵：12×16 分区均值，分区范围 = 当前取景框可见区域
- 组合：给定 EV100、胶片 ISO、光圈，取最近的 1/3 档快门；误差上限 1/6 档

### 坐标换算链

```
屏幕触摸 (x,y) → 归一化 (px/w, py/h)
             → 相机 API setMeteringPoint({ y/h, 1 - x/w })
             → 传感器帧采样 cx = w×meterY, cy = h×(1-meterX)
```

任何一环搞错，准星和实际测光区就对不上，且现象隐蔽。

## 4. UI 坑

- `Stack` 里子组件的 `.align()` **无效**，位置由 Stack 的 `alignContent` 决定 → 用 `Column` + `Blank`
- 空 `Row()` / `Column()` 不渲染，画线要用 `Circle` / `Rect`
- `InputType.Number` 不吃小数点（`1.8` 变 `18`），要用 `NUMBER_DECIMAL`
- 预览 profile 要选 4:3 中分辨率最高的，曾误选 640×480 导致画面发虚
- `TextPicker` 只显示选中项时，是缺了 `.defaultPickerItemHeight()`
- `PickerTextStyle` 只有 `color` 和 `font`，字号写 `font: { size: 14 }`，写 `fontSize` 会编译报 `No overload matches this call`
- `TextPicker` 的 `selected` 不跟随程序化改动，算法算出新值时推不动滚轮，要用 `value: $$this.xxx` 双向绑定
- 同一个组件挂两个 `bindSheet` 会互相顶掉（点了没反应）
- `bindSheet` 的拖拽手势会和滚轮抢事件，滚轮上一滑面板就被拖关 → 改用 `CustomDialog`
- `CustomDialog` 的「完成」不要依赖对话框内注入的 controller，改为页面侧持引用主动 `close()`
- 页面跟着系统栏留白时：`setWindowLayoutFullScreen(true)` + `getWindowAvoidArea()` 自己加 padding，否则底部导航栏会露出白边

## 5. 构建坑

1. 工程路径**不能含中文**，hvigor 直接报 `00306003 Specification Limit Violation`
2. `jbr/bin` 必须进 `PATH`，否则打包阶段 `spawn java ENOENT`
3. `compatibleSdkVersion` 写 `"26.0.0"`，不能写 `"26.0.0(26)"`（带括号是老格式）

安装调试：

- 同 bundleName 反复覆盖安装（模块结构变化）可能让应用启动卡在「窗口未挂载」（进程活着但 `onCreate` 不执行），需要 `hdc uninstall` 后重装
- 卸载重装后相机权限被重置，权限弹窗有时不出现，需在系统设置里手动授权
- 开发者模式 + 锁屏状态下 `aa start` 会失败，先唤醒解锁
