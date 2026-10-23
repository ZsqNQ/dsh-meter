# 交接文档 · 轻测光

> 当前版本：**v1.2.0**（versionCode 1020000，包名 `com.nanqiu.meter`）
> 验证设备：HUAWEI MRT-AL10 / HarmonyOS 7.0.0.109 / API 26
> 这份文档除了讲"现在是什么样"，更重点写"为什么是这样"——包括走错的路，避免下一版重踩。

## 0. 仓库结构

```
AppScope/app.json5                     包名、版本、图标、应用名
AppScope/resources/base/media/app_icon.png   应用图标（1024×1024，白底黑光圈）
entry/src/main/ets/
  pages/Index.ets             全部 UI + 相机会话 + 取帧 + 状态（主战场，约 2200 行）
  common/Metering.ets         纯算法：EV、1/3 档档位表、曝光组合、变焦滑条映射
  common/ApertureMonitor.ets  光圈/镜头监测（EXIF 轮询、校验、锁定联动、轮询节流）
  common/ShotAperture.ets     静默拍照读 EXIF 的底层实现
  entryability/EntryAbility.ets  窗口全屏 + 系统栏配色
docs/                          本文件、用户手册、截图
release/                       构建产物（不入库，走 GitHub Releases）
```

公开仓库**不含签名材料**：`build-profile.json5` 里的 `signingConfigs` 已删除，
构建前用 DevEco Studio → File → Project Structure → Signing Configs → 自动生成签名即可。
`reference/` 下的算法 JS 版本与 Node 用例只在本地工作区，不在仓库里（用作算法回归）。

---

## 1. 项目定位

给胶片摄影师用的鸿蒙原生测光 App（ArkTS / ArkUI，`.hap` 侧载）。

原理：手机相机自动曝光会把画面压到 18% 灰，所以 `ISO + 快门 + 光圈` 反算出的 EV 就是场景的反射式测光值。App 测出它，再换算成胶片机镜头上能拧出来的光圈/快门组合。

---

## 2. 代码结构

```
entry/src/main/ets/
  pages/Index.ets            全部 UI + 相机会话 + 帧采样 + 状态（约 1100 行）
  common/Metering.ets        纯算法：EV、1/3 档档位表、组合计算、快门格式化
  entryability/EntryAbility.ets   窗口全屏 + 系统栏配色
  entrybackupability/...
AppScope/app.json5           版本号（versionName / versionCode）
```

### 数据流

```
CameraKit 双路预览 ──► XComponent（显示）
                  └──► ImageReceiver（取 Y 平面）──► 亮度统计（点测圈 / 12×16 矩阵）
onIsoInfoChange / onExposureInfoChange ──► ISO、曝光时长 ──► ev100From()
                    ↓
EV100 = log2(N²/t) − log2(ISO/100)
EV    = EV100 + 2.2·log2(局部亮度 / 基准亮度) + 校准 + 曝光补偿
                    ↓
显示（当前胶片 ISO 下的 EV = EV100 + log2(filmIso/100)）
                    ↓
comboFor()：给定 EV100 + 胶片 ISO + 光圈 → 最近 1/3 档快门
comboFromShutter()：给定 EV100 + 胶片 ISO + 快门 → 最近 1/3 档光圈
```

---

## 3. 核心设计决策

### 3.1 为什么是"软件测光"

相机自带 `SPOT` 测光面积固定为传感器的 2.5%，且 `MATRIX` 永远针对完整传感器画面，不受 UI 裁切影响。要满足"测光区域随变焦倍率变化"，只能用第二路预览取帧自己算亮度。

### 3.2 为什么变焦是"裁切放大"而不是真 zoom

早期版本把硬件 `zoomRatio` 锁在 0.8（落在超广角段），因为主摄物理光圈拿不到，锁定焦段可以让光圈成为恒定常量。放大靠 `XComponent.scale()` + 父容器 `.clip(true)`，这样物理光圈不变，EV 计算只用 f/2.2。

**代价**：画面是裁切插值，放大会糊；且 `setZoomRatio()` 是异步的（设完立即读仍是旧值，约 1 秒后才变）。

### 3.3 A/S 两种用法

- **A 档**（锁光圈）：光圈由用户滚轮决定，快门由算法算 → 光圈蓝色、快门白色
- **S 档**（锁快门）：快门由用户滚轮决定，光圈由算法算 → 快门蓝色、光圈白色

只允许调"蓝色"那个滚轮，另一个滚轮盖一层 `hitTestBehavior(HitTestMode.Block)` 的透明层挡住滚动。

### 3.4 1/3 档档位表

`Metering.ets` 里三张表：

| 表 | 范围 | 数量 |
|---|---|---|
| `APERTURE_LADDER` | f/0.5 ~ f/64 | 43 档 |
| `SHUTTER_LADDER` | 1/16000s ~ 60s | 61 档 |
| `ISO_LADDER` | 6 ~ 6400 | 31 档 |

组合取"最近 1/3 档"，因此误差上限 **1/6 档**，界面直接写「误差 ≤1/6 档」。

快门显示规则（`formatShutterSecond`）：

- `t ≥ 1` → `2s`、`1.5s`；慢于 1s 时数值标红（倒易律失效提醒）
- `0.4 ≤ t < 1` → `0.8s`
- `t < 0.4` → `1/125`

> 为什么 0.4~1s 用小数：早期直接 `1/${round(1/t)}`，0.8s 会显示成 `1/1`，明显是错的。

### 3.5 持久化

`@kit.ArkData` 的 `preferences`，`meter_settings` 一个文件，键：

```
biasEv（校准）  expEv（曝光补偿）  filmIso  apLocked（A/S）  meterMode  apIndex  shIndex
```

写入时机：二级菜单点「完成」时；切 A/S、切测光模式时；`onApplicationBackground` 和 `aboutToDisappear` 里整体 `saveState()`。

---

## 4. 试错记录（重点）

这一段是给下一版的自己看的，每条都写"现象 → 原因 → 结论"。

### 4.1 双路预览：曾误判为"设备不支持"

**现象**：同一 session 加第二路 PreviewOutput，应用进程无任何日志直接消失。

**当时的错误归因**：以为机型不支持双路预览，一度放弃了"测光区域随倍率变化"这个需求。

**真实原因**：取帧用了 `getComponent(ComponentType.YUV_Y)`。改用 `ComponentType.JPEG` 后完全正常，即使相机流是 `CAMERA_FORMAT_YUV_420_SP`。

**教训**：
- 静默消失（无崩溃日志、初始化日志全部打印完后进程没了）优先怀疑 native/框架层断言，而不是"设备不支持"。
- 在帧回调里打点能定位得很准：回调没打印 = 崩在 `getComponent`；打印了 = 崩在别处。

### 4.2 全量迁移到 C API：做了、验证了、最后回退

**动机**：路线设想是"用 CApi 直接读 AE 算出的场景 EV，精度更高"。

**做了什么**：用 `ohcamera` 把整个相机会话搬到 native（`CreateCameraInput` → `CreateCaptureSession` → 两路 `CreatePreviewOutput` → `CommitConfig` → `Start`），注册 `RegisterExposureInfoChangeCallback` / `RegisterIsoChangeCallback` / `RegisterExposureStateChangeCallback`，ArkTS 只留 UI 与 surfaceId 传递。

**结论（探针实测）**：`OH_CaptureSession_GetExposureValue()` 在 AUTO 下**恒返回 0**，和 `GetExposureBias()` 一模一样——它读的是曝光补偿量，不是场景 EV。也就是说"C API 能拿到真值"这个前提不成立。

**另外两个坑**：
- native 日志 domain 用了 `0xD00420`，超出应用可用区间（0x0000~0xFFFF），hilog 直接丢弃，排查时什么都看不到。改 `0x0420` 才有输出。
- napi 导出的键名必须和 `index.d.ts` 一致。曾经键名写成 `createSession`、d.ts 里叫 `prepare`，调用抛异常被 `catch` 吞掉，表现为"画面全黑但 UI 正常"，很难定位。

**现状**：已整体回退到纯 ArkTS 实现。**如果下一版还想做 native**，唯一有实际收益的点是 AE 收敛状态（`OH_CAMERA_EXPOSURE_STATE_CONVERGED`，API 26）和帧统计性能，而不是 EV 真值。

### 4.3 物理光圈：三条路都试过了

| 尝试 | 结果 |
|---|---|
| ArkTS `getPhysicalAperture()` | 恒返回 0 |
| ArkTS `getSupportedPhysicalApertures()` | 空数组 |
| native `OH_CaptureSession_GetPhysicalAperture()` | 同 ArkTS |
| `setPhysicalAperture(0.5)` / `setPhysicalAperture(99)` | **不报错，也不生效**（空实现） |

**结论**：测试机型对第三方应用不开放光圈，读不到也写不了。光圈只能当常量（当前 f/2.2）。换机型可能不同，值得在目标机型上重测。

唯一能拿到真实光圈的路子是拍照后读 EXIF `FNumber`，但只能"事后"，且静默拍照会复位 zoom、打断连续对焦——不要放进正常测光流程。

### 4.4 滚轮：连续七次迭代，六次是错的

这是本项目花时间最多、也最该记住的部分。

| 版本 | 做法 | 结果 |
|---|---|---|
| 1 | `TextPicker` | 能用，选中项不放大、有黑线、首尾循环 |
| 2 | 加 `defaultPickerItemHeight`、`divider(null)`、`canLoop(false)` | 样式好了 |
| 3 | 想让算法算出的值推动滚轮 | `selected` 不跟随程序化改动 → 必须用 `value: $$this.xxx` 双向绑定 |
| 4 | 滚轮上长按切 A/S（`.gesture` 挂在包着标题+滚轮的 `Column`） | 长按能触发，但**滚轮拖不动了**：父容器的 gesture 会把子组件的拖动吃掉 |
| 5 | 改 `parallelGesture` / `priorityGesture` / `onTouch` / `onTouchIntercept` + 定时器 | 各种收不到事件；定时器方案还会"轻点一下就切档"（因为抬手事件被 `TextPicker`/`List` 吞掉，等不到 Up） |
| 6 | 换自写 `List` + `scrollSnapAlign` | 滚动 OK，长按仍收不到；且首尾占位项会被当成吸附目标，滚到底停在空白 |
| 7 | 自写 `translate` 滚轮（PanGesture + LongPressGesture） | 长按不生效、初始高亮错乱——又一批新问题 |

**最终决定（v1.1.0）**：回到 `TextPicker`，**彻底删掉长按切换功能**，A/S 只由按钮切换。

**结论（很重要）**：
- `TextPicker` 会独占自己子树内的触摸，父级 `onTouch` / `gesture` 都收不到；`List` 同理。
- 在 ArkUI 里给滚动类组件加"长按 + 拖动"两个手势，代价远高于收益。要么只做拖动（用原生 picker），要么完全自绘并自己处理所有手势——不要试图在原生滚动组件上叠手势。
- 现在滚轮的完整正确配置：

```ts
TextPicker({ range: this.apertureItems, value: $$this.apLabel })  // $$ 才能被程序推动
  .canLoop(false)                       // 关掉首尾循环
  .defaultPickerItemHeight(30)          // 不设只显示选中项
  .divider(null)                        // 去掉自带黑线
  .textStyle({ color: '#88FFFFFF', font: { size: 13 } })       // 注意是 font:{size}
  .selectedTextStyle({ color: ..., font: { size: 22 } })
  .height(90)                           // 90 = 3 档，正好显示 3 个
```

左右两条标线是绝对定位的 `Rect`（`.position({ x:'8%', y:44 })`），故意做得很小，避免变成遮罩挡住手势。

### 4.5 二级菜单：`bindSheet` → `CustomDialog`

- `bindSheet` 的拖拽手势和滚轮抢事件：在滚轮上滑一下，整块面板被拖关，参数根本调不了。
- 同一个组件上挂两个 `bindSheet` 会互相顶掉（点第二个没反应）。
- 换 `CustomDialog` 后又遇到：「完成」按钮没反应——原因是关窗依赖对话框内部注入的 `controller`，运行时为 `null`。

**最终做法**：页面侧持一个 `activeDialog: CustomDialogController`，在 `onDone` 回调里主动 `close()`。

### 4.6 全屏与白边

一开始页面上下有白边（底部导航栏露白）。做法：

```ts
// EntryAbility
win.setWindowLayoutFullScreen(true);
win.setWindowSystemBarProperties({ statusBarColor: '#00000000', navigationBarColor: '#00000000', ... });

// Index
const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
const nav = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
this.safeTop = px2vp(sys.topRect.height);
this.safeBottom = px2vp(nav.bottomRect.height);
```

页面根容器加 `padding({ top: safeTop, bottom: safeBottom })`。这样状态栏不被内容遮挡，底部也不露白。

### 4.7 坐标换算（隐蔽但致命）

```
屏幕触摸 (x,y) → 归一化 (px/w, py/h)
             → 相机 API setMeteringPoint({ y/h, 1 - x/w })     ← 文档坐标系是转置的
             → 传感器帧采样 cx = w×meterY, cy = h×(1-meterX)
```

另外：预览缩到 76% 屏宽后，准星在传感器上对应的半径比例要按**预览宽度**算，而不是屏宽——否则测光圈和准星对不上，读数会偏。

### 4.8 真机调试踩的坑

- **`uitest dumpLayout` 的坐标和截图不一致**：按 dump 的 bounds 去点按钮经常点不中，用截图像素换算反而准。调试脚本别盲信 dump。
- **覆盖安装可能让应用"启动卡死"**：模块结构变化后（比如加了/删了 native 库）同 bundleName 覆盖安装，进程活着但 `onCreate` 不执行、UI 空白。需要 `hdc uninstall` 后重装。
- **卸载重装后相机权限被重置**，权限弹窗有时不出现，要去系统设置手动授权。
- **开发者模式 + 锁屏状态下 `aa start` 会失败**，先唤醒解锁。
- **hilog 缓冲很小**：应用启动时的日志几分钟内就被系统日志冲掉，验证要用"清缓冲 → 触发 → 立刻抓"的顺序。

---

## 5. 已知问题与限制

1. **EV 未与真实测光表比对**：建议下一版用 18% 灰卡或已知 EV 场景标定一次「校准 EV」。
2. **光圈硬编码 f/2.2**：测试机型上读不到；换机型需重测。
3. **矩阵模式是简单平均**，没有做中心加权（真实相机的多分区测光会加权）。
4. **锁定后切后台恢复的是"重建时重新冻结的那一帧"**，不是切走前那一帧（原帧随相机释放丢失）。
5. **长曝光只做了标红提示**，没有做倒易律补偿计算。
6. **测光稳定性**：AE 未收敛时读数会跳；目前靠"连续两次相同才显示稳定"粗略处理，没有接 `ExposureState`（API 26 有 `CONVERGED` 回调）。
7. **只在 MRT-AL10 验证过**，其他机型/系统版本未测试。

---

## 6. 下一版可以做什么（按性价比排序）

1. **接 AE 收敛状态再读数**：`exposureStateChange`（API 26）收敛后再采样，读数会稳很多，改动很小。
2. **灰卡标定流程**：界面上引导用户"把灰卡放进取景框 → 点标定 → 自动算 biasEv 存下来"，比手动调滚轮靠谱。
3. **真 zoom 实验**：把硬件 `zoomRatio` 放开给滑条（同时要删掉 `readOnce` 里那句每 400ms 把 zoom 拉回 0.8 的防御代码，否则拖动无效），实测不同焦段的光圈与视场变化，再决定是否替换裁切放大。
4. **矩阵测光中心加权**：中间 4×4 分区权重 2.0，边缘 1.0，比现在简单平均更接近相机行为。
5. **多点记忆**：存高光/阴影两个读数，显示动态范围估值。
6. **长曝光倒易律补偿**：按胶片型号查表（如 Provia/T-Max）给出补偿后的快门。

---

## 7. 构建 / 调试 / 发布

### 构建

```bash
ohpm install
export DEVECO_SDK_HOME=/path/to/DevEco/sdk
export PATH=/path/to/DevEco/jbr/bin:/path/to/DevEco/tools/node:$PATH
hvigorw assembleHap --mode module -p product=default -p buildMode=release --no-daemon
```

三个必踩的坑：

1. 工程路径**不能含中文**，hvigor 报 `00306003 Specification Limit Violation`；
2. `jbr/bin` 必须进 `PATH`，否则打包阶段 `spawn java ENOENT`；
3. `compatibleSdkVersion` 写 `"26.0.0"`，不能写 `"26.0.0(26)"`。

### 调试命令

```bash
HDC=/path/to/sdk/default/openharmony/toolchains/hdc.exe
$HDC install -r entry/build/default/outputs/default/entry-default-signed.hap
$HDC shell aa force-stop com.nanqiu.meter
$HDC shell aa start -a EntryAbility -b com.nanqiu.meter
$HDC shell hilog -r                                   # 清缓冲
$HDC shell "hilog -x | grep 'JSAPP'"                  # 抓日志（-x 是快照，别用不带 -x 的，会挂住）
$HDC shell snapshot_display -f /data/local/tmp/s.jpeg
$HDC file recv /data/local/tmp/s.jpeg s.jpeg
$HDC shell uitest uiInput click 640 1200              # 点击 / longClick / swipe / drag / keyEvent Home
```

> Git Bash 下调用 hdc 记得 `export MSYS_NO_PATHCONV=1`，否则 `/data/local/tmp/...` 会被改写成 Windows 路径。

### 版本发布

1. 改 `AppScope/app.json5` 的 `versionName` / `versionCode`（versionCode 必须递增）；
2. 构建 release hap，重命名成 `DSH-Meter-vX.Y.Z.hap` 放到 `release/`；
3. 更新 `CHANGELOG.md`、`docs/HANDOVER.md`（这份）；
4. 提交 → push main → 打 tag `vX.Y.Z` → 建 release 并把 hap 作为 asset 上传；
5. release 正文要注明"作者调试证书签名，其他设备请自行签名构建"。

> 这台机器到 GitHub 的网络不稳：`git push` 可能报 408/502，加 `-c http.version=HTTP/1.1 -c http.postBuffer=524288000` 重试通常能过；实在不行用 REST API 直接建 tag / release / 传 asset。

### 签名注意

- 仓库**不含任何签名材料**，`build-profile.json5` 里没有 `signingConfigs`；
- DevEco Studio → Project Structure → Signing Configs 生成自己的证书即可；
- 调试证书签的 hap 一般只能装在已注册设备上，发布给别人必须用正式证书或让对方自行构建。

---

## 8. 一句话给下一版的自己

**这个项目的难点不在算法，在 HarmonyOS 相机与 ArkUI 的隐藏行为。** 改 UI 组件之前先在真机上确认"它会不会吃掉触摸"，改手势之前先想清楚"谁在争抢这一下"，不要在一个原生滚动组件上叠手势——已经用过六种写法证明这样不划算。

---

## 9. v1.2 变更（v1.2.0 已发版）

> 需求来源：桌面 `v1.2需求文档.txt`。本节记录已在真机验证过的部分，避免下一版重复试错。

### 9.1 光圈：API 彻底走不通，EXIF 是唯一来源

- 主摄（zoom=1.0，不是旧的 0.8）下复测：`getPhysicalAperture()` 恒 **0**、`getSupportedPhysicalApertures()` **空数组且不抛错**；
  zoom 0.55 / 1 / 1.5 / 2 / 3 / 5 / 10 / 100 全段一致。旧版在 0.8 测不出来不是焦段问题。
- 静默拍照读 EXIF 可行，字段齐全：`FNumber`、`FocalLength`、`FocalLengthIn35mmFilm`。
- **大坑**：厂商 EXIF 值不是标准 `a/b`：`"f/2.2"`、`"1.8 mm"`、`"1/100 sec."`。
  按 `a/b` 解析会把光圈读成 0。解析器必须「抽数字、有斜杠才做除法」（见 `common/ShotAperture.ets` 的 `parseRational`）。
- **另一个坑**：EXIF 有帧延迟。变焦/换镜头后第一张可能带上一颗镜头的元数据，需要补拍一张取后者。

### 9.2 「当前用哪颗镜头」没有 API，只能靠 EXIF 的物理焦距

| 候选 | 实测 |
|---|---|
| `session.getFocalLength()` | 恒 5.75mm（主摄物理焦距），0.55x~10x 都不变 |
| `CameraDevice.isLogicalCamera` / `constituentCameraDevices` | `undefined`，厂商没填 |
| `lensEquivalentFocalLength` | 有：`[13, 24, 88]`，但只是镜头清单，不代表当前 |
| native `OH_CaptureSession_*` | 只有 `GetFocalLength`，没有 ActivePhysicalCameraId |
| EXIF `FocalLengthIn35mmFilm` | **实测 = 24 × zoom**（0.55x→13、100x→2400），只反映数码变焦，认不出镜头 |
| EXIF `FocalLength`（物理） | **可用**：超广 1.8mm / 主摄 5.8mm / 长焦 14.6mm，换镜头会跳变 |

结论：物理焦距只能当**事实展示**（界面显示 `f/2.2 · 14.6mm`），
**不能用来推断"当前是哪颗镜头"**：高倍率下离得近，手机照样可能留在主摄上。
实测同一 zoom（f35=1029）下 focal 从 5.8mm 跳到 14.6mm，说明倍率与镜头没有固定对应。
所以界面去掉了「主摄/长焦」这类标签，只报光圈和物理焦距。

### 9.3 光圈监测（需求 2、3）落地

- 常驻一个低分辨率（640×480）`PhotoOutput`，直接输出到 `ImageReceiver` 的 surface，读完即 `release`，不落盘。
- 每 **500ms** 拍一张；判定「疑似陈旧」（物理焦距跳变 / 光圈突变 >1 档）时补拍一张取后者。
- 轮询与倍率**无关**：不管多少倍都照常 0.5s 一拍（高倍率近距离仍可能主摄，不能靠倍率省拍）。
- 按下锁定瞬间补拍一张再停轮询；锁定期间不拍；解除锁定后先补拍一张再恢复 0.5s 轮询。
  若按下锁定时正好有一次轮询在拍，`shootNow()` 会等它结束（最多 800ms）再补拍，不会静默丢掉锁定那一张。
- 保护层（与 API/EXIF 来源无关）：只接受 `0.9~45` 且有限的光圈；EV 只用「最近一次通过校验的读数」，
  拿不到沿用上一次，绝不把 0 喂给 `log2`；API 若可用则与 EXIF 交叉校验，差 >1 档打 `[AP] mismatch` 并采用 EXIF。
- 实测：轮询期间取帧仍 30fps 到达 / 15fps 处理，预览 30fps 不受影响；拍照不复位 zoom、不打断预览。
- 首次 `capture` 拿不到图，必须先空拍一张热机（`ShotReader.warmUp()`）。
- 本机实测数据：超广 f/2.2·1.8mm；主摄 f/2.0~f/1.4·5.8mm（可变光圈，会自己变）；长焦 f/2.2·14.6mm。
  镜头切换点在 6x~11x 之间（不是常见的 3.5x），别写死阈值。

### 9.4 原生变焦（需求 2 前半）

- 删掉 `XComponent.scale()` 裁切放大与每 400ms 把 zoom 拉回 0.8 的防御代码，改 `session.setZoomRatio()`。
- 变焦范围首启 `getZoomRatioRange()` 读一次存 preferences（`zoomMin`/`zoomMax`），之后永远用缓存，升级版本也不重读。
- 滑条用两段对数映射：光学段 `min~10x` 占 75% 行程、数字段 `10x~max` 占 25%；
  纯线性时 1x 会挤在最左 0.5%，没法用。算法在 `Metering.ets`，`reference/metering.mjs` 有 Node 用例。
- 冷启动默认 1x；**回前台恢复用户当前倍率**（`openCamera(ctx, sid, isResume=true)`）。
- 真变焦后测光数学不再二次裁切：点测圈半径、12×16 矩阵都按整帧算。

### 9.5 变焦手感与锁定延迟（定稿）

**关键实测结论**：本机 `setSmoothZoom` 每次调用都由系统给一个**固定 433~933ms 的过渡**（与目标距离无关）。
所以在拖动中每 60~100ms 连续调用它，相机永远在追上一个半秒前的目标——表现就是「不顺、不跟手」。
那个 API 不是不能用，是**不能连续重定向**。

现在的分工：

- **拖滑条**：自己插值——每 60ms 推进剩余行程的 25%（对数空间），用 `setZoomRatio` 立即下发。
  单步位移小 → 画面连续；由自己控制节拍 → 跟手。
- **点滑条轨道**：一次性跳档，这时不需要跟手，才用 `setSmoothZoom`（系统 433ms 平滑动画）。
- 两种路径都要等「收敛」后再结束变焦态补测（`endZooming` 里 `zoomAnimating()` 二次确认）。

**锁定延迟**：原来要「prefetch → 拍一张 → 停会话」串行做完才定格，体感 1 秒多。现在拆成两段：

1. 立刻定格：锁曝光 + 停显示预览输出（实测 **5~8ms** 完成，实测画面差异 0 确认冻结）；
2. 后台补数据：开取帧流 → 存快照 → 必要时补拍 → `remeter()`。
   有现成快照时 EV **同帧就出**；冷启动没有任何数据时约 **230ms** 出数（日志 `[LOCK] measure done`）。

### 9.5.1 早期变焦手感记录（方案 1+2）

- 拖动下发改用 `setSmoothZoom(target, SmoothZoomMode.NORMAL)`（系统贝塞尔平滑，实测系统给 430~970ms 过渡时长，
  可通过 `on('smoothZoomInfoAvailable')` 拿到）；厂商没实现时第一次失败就永久退回 `setZoomRatio`。
  每次拖动最多 100ms 下发一次，松手（End/Click）必发一次终值。
- **变焦期间不测光**：一触发滑条就停 0.5s EXIF 轮询、EV 显示 `XX`、底部状态写「测光停止」，
  后处理（`sampleFrame`）直接跳过省 CPU——变焦过程中的读数本来不可靠。
- 停稳 450ms（松手 220ms）后：补拍一张拿光圈 → 恢复轮询 → 立即重算一次 EV。
  **补测期间 EV 继续保持 XX**，否则会先拿旧光圈显示一帧。
- 锁定态拖动：相机会话已 `stop()`，只记录目标倍率不下发、不拍照，停稳后 `remeter()` 恢复锁定读数，
  解锁时 `applyZoom()` 统一下发。
- 若真机上仍觉得「变焦慢半拍」，原因是每次 `setSmoothZoom` 都会按距离重新给一个 400~900ms 的过渡，
  连续重定向会拖在手指后面；届时把拖动中的下发改成 `setZoomRatio`（立即到位）+ 松手用 `setSmoothZoom` 收尾即可。

### 9.6 后台取帧降本（需求 4）

- 取帧档位从「跟显示档同宽」改成挑最接近 **640×480** 的同比例档。
- 修了老 bug：`ImageReceiver` 原本按显示档尺寸创建、实际流是另一档，整帧错位。
- 后处理加 50ms 节流（30fps 流上等于隔帧取，约 15fps）。
- 帧率实测：预览 30fps（`setFrameRate(30,30)` 后 `getActiveFrameRate()`=30-30，档位支持 `1-30` 和 `60-60`）；
  处理流 30fps 到达 / 15fps 处理，快照 320×240。

### 9.7 交互模型：按住测光 / 按下定格（按用户要求，减少常态负载）

- **默认不测光**：不拍照、不轮询、不做后端亮度处理；**后端取帧那一路直接 `PreviewOutput.stop()` 关掉**
  （显示预览保持 30fps）。
  EV 与「算出来的那一侧」（A 档的快门 / S 档的光圈）显示 `XX`，用户自己设的那一侧照常显示可调。
- **双击「启动测光」= 连续测光**（再次双击退出）：锁存状态由 `meteringContinuous` 表示，双击判定窗口 420ms
  （实测指纹：`[METER] tap gap=314ms` 触发）。连续测光期间按钮文案变「连续测光中」并高亮，
  按锁定会强制退出连续态。
- **首启等效焦距标定**：首次启动在 1.0x 连拍 3 张读 `FocalLengthIn35mmFilm`，取其中**最大值**作为基准
  （近距离时手机会自动切超广角，会读到 13mm 这种偏小值），存 preferences 的 `baseFocal35`，之后不再重标。
  滑条右侧显示「当前倍数 · 等效焦距」，等效值 = 基准 × 当前倍率（与相机自己报的 `24×zoom` 一致）。
- **超出档位表的显示**：不再弹「超出范围，换一档」这类文字。做法是**两套滚轮列表**：
  - 用户自己滚的那一侧（A 档光圈 / S 档快门）用纯档位表，没有空白项，永远选不到空白；
  - 算出来的那一侧（A 档快门 / S 档光圈）用「首尾各加一个空白位」的列表，所需值越过两端时
    直接把 label 设成首/尾空白（`BLANK_TOP` / `BLANK_BOTTOM` 用不同的不可见字符区分，
    否则 `value` 绑定会撞车）。
  切 A/S 时必须把两侧 label 重新对齐到真实档位（`setExposureModeLock` 里做），否则从「计算侧停在空白」
  切过去会留一个空值。**不要**再用「盖一层色块」的写法——那版和 onChange 打架，真机上会把进程拖死。

- **焦距按钮 / 手动设焦**：滑条右侧那个「倍数·mm」是 88px 宽的小按钮（白描边=未锁，红描边+红字=锁定，靠颜色区分、不写“锁”字），点开二级页可
  直接输入等效 35mm 毫米数，并切换「锁定焦距」。锁定后滑条 `.enabled(false)` 且代码里也拦截下发；
  状态与毫米数存 preferences（`zoomLock` / `zoomLockMm`），**重启后恢复锁定状态与同一焦段**。
- **采样频率**：测光期间 400ms 一张（文档原话 0.5s 甚至更高）。实测 **300ms 会被相机拒（7400102）**，
  400ms 稳定；`ApertureMonitor` 里另有 `MIN_SHOT_GAP_MS=400` 兜底，避免快速开停时连拍被拒。
- **按住「启动测光」**：`PreviewOutput.start()` 开回取帧 + 500ms 一次 EXIF 拍照（第一次立刻拍，不等周期），实时出读数；
  启动后 1.2 秒会先空拍一张热机，否则第一次按住的那 1.5 秒全耗在首次 `capture` 上；
  **松手**立即停拍、停取帧流、EV 与计算侧回到 `XX`。实现是 `Button.onTouch` 的 Down/Up/Cancel，不是 onClick。
- ⚠ **踩过的坑（别再犯）**：曾经想用「不测光就把取帧那路 `setFrameRate(5,5)` 降频」省带宽，
  结果同一 session 里两路 preview 共享帧率档，**显示预览跟着掉到 5fps**，取景卡死。
  正确姿势是：两路都钉 30fps，空闲时把取帧那一路 `stop()`（实测 arrival=0、预览仍 30-30）。
- **按下「锁定曝光」**（无论之前是否在测）：`prefetchFrame()` 先取一帧存快照（空闲态没在取帧）→
  光圈读数不新鲜就补拍一张 → 锁曝光 + 停后台取帧流 + **停显示预览输出**（surface 保留最后一帧）定格 →
  用快照 `remeter()` 算出结果，同时**锁死变焦滑条**。
  - ⚠ **不要用 `session.stop()` 定格**：拍照刚结束那一下它会间歇性报 `7400201` 且实际上没停，
    表现就是「UI 显示已锁定、画面却还在动」。停 `PreviewOutput` 稳定得多（连续三轮实测画面差异为 0）。
  - 解锁用 `PreviewOutput.start()` 恢复，失败才退回 `reopenCamera()`。
  - 连续两次 `capture` 之间至少隔 500ms，否则会被拒 `7400102`；锁定前优先复用「1.5 秒内的新鲜读数」。
- 锁定态仍可切点测/矩阵、仍可拖动测光点：切模式走 `setMeterMode()` 里的 `remeter()`，
  拖点走 `onMeterMoved()` → `remeter()`，两者都基于冻结帧快照，不需要相机在跑。
- 解锁：恢复 5fps、EV 与计算侧回 `XX`、变焦滑条解锁并按当前倍率恢复。
- 注意：锁定态切到矩阵测光时，矩阵均值用的是定格前最后一帧算出的 `matrixY`（没有实时帧可算），
  点测则是对快照重新取均值，精度不受影响。

### 9.8 启动黑屏过渡

- 黑屏页（`booting`）盖住整页：黑底 + 「鸿蒙测光表」+「启动中」+ 转圈，完成初始化后 220ms 淡出。
- 放行条件三项齐备：`settingsLoaded`（preferences 读完）、`cameraReady`（相机会话起来、变焦范围就绪）、
  `warmAndCalibDone`（热机 / 首启焦距标定跑完）。最短黑屏 450ms，避免一闪而过；兜底 20 秒强制放行。
- 实测耗时：常规启动 **~0.65s**；首启（含权限弹窗 + 焦距标定）**~7s**，其中标定阶段相机会连拒前几次
  capture（7400102），代码里用 5 秒窗口重试到拿到 2 个样本。
- 非首启不再等热机：热机改到黑屏结束后 1.2s 后台进行，避免为一次空拍多黑屏一秒。

### 9.9 更名「轻测光」与图标（2026-10-23）

- 应用名：`AppScope/resources/base/element/string.json` 的 `app_name`、`entry` 的 `EntryAbility_label`/`EntryAbility_desc`
  全部改为「轻测光」；启动页标题同步为「轻测光」。`bundleName` 不变（`com.nanqiu.meter`），用户数据与权限不受影响。
- 图标：用户提供的白底黑光圈图，处理成 1024×1024（留 4% 白边）后放到
  `AppScope/resources/base/media/app_icon.png` 与 `entry/src/main/resources/base/media/app_icon.png`，
  `app.json5` / `module.json5` 的 `icon` 与 `startWindowIcon` 都改指向 `$media:app_icon`，
  不再使用 `layered_image`（原图层文件保留未删）。桌面实测图标与名称都正确。
- 启动页淡出只淡文字，不淡黑底：否则那 200ms 会透出下面的页面（一度看起来像启动页错位）。

### 9.10 许可选择（2026-10-23）

- 项目以 **GNU AGPL v3.0** 开源（OSI 认可的开源许可，GitHub 可识别）。
- 选它的原因：AGPL 是强 copyleft —— 允许任何人（含公司）使用甚至商用，但**衍生作品必须同样以 AGPL 开源**，
  且有「网络条款」（提供服务时须向使用者提供源码），因此挡住了「改成闭源产品再卖」这条最常见的挪用路径；
  若对方愿意同样开源，则无需额外授权。
- 对比：MIT/Apache 允许闭源商用（挡不住）；PolyForm Noncommercial 虽禁商用但不算 OSI 开源，且作者一开始
  想要的是「开源」；AGPL 是两者的折中。
- 若将来要允许闭源商用，可改用双许可（AGPL + 商业许可），届时在 README 增加授权联系方式即可。
- 改许可时要同步四处：`LICENSE`、`README.md`「许可」、`docs/USER_GUIDE.md` §9、`CHANGELOG.md`。

### 9.11 发布记录：v1.2.0（2026-10-23）

- 版本号：`1.2.0` / `1020000`；产物 `release/轻测光-v1.2.0.hap`（约 640KB）。
- 工程已初始化为 git 仓库并提交首个 commit，准备开源（MIT）。
- 公开仓库不含签名材料：`build-profile.json5` 的 `signingConfigs` 已删除，构建前用 DevEco 自动生成签名；
  本机原配置备份在工作区 `tmp/build-profile.signed.json5.bak`（不要外传）。
- 新增文档：`README.md`、`docs/USER_GUIDE.md`、`docs/HANDOVER.md`、`CHANGELOG.md`、`LICENSE`、`.gitignore`；
  截图在 `docs/images/`。
- 上线前待办：`git remote add origin <你的仓库>` → `git push -u origin main` → 建 tag `v1.2.0` →
  把 hap 作为 Release asset 上传（说明里注明"调试证书签名，其他设备请自行构建"）。

### 9.12 尚未做

- 需求 3（首启各焦段标定表）：不做。文档前提是「主摄光圈可经 API 获取」，本机不成立；
  而且标定表本质是「按焦段查表」，与"倍率不能代表镜头"的事实冲突（高倍率近距离仍走主摄），
  按焦段查表会把推断错误固化进数据，宁可一直定时实拍。
- 快门声/拍照对 AE 的影响未在真机上听/测过，若 0.5s 轮询有快门声，需要改成「变焦停稳后再拍」。
- 变焦时预览有小卡顿（用户已确认可接受，暂不优化）。
