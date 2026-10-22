# 鸿蒙测光表（DSH Meter）

给胶片摄影师用的鸿蒙原生测光 App（ArkTS / ArkUI，`.hap` 侧载）。

手机相机在自动曝光下会把画面拉到 18% 灰，因此「当前 ISO + 快门 + 光圈」反算出的曝光值，就是场景的反射式测光值。本应用测出这个 EV，再换算成胶片机镜头上能拧出来的光圈/快门组合。

## 功能

- **双路预览**：一路显示，一路给 ImageReceiver 取帧做软件测光（点测圈 / 12×16 矩阵）
- **点测 / 矩阵**切换，点测准星可拖动，测量区域随变焦倍率缩放
- **变焦**：裁切放大 1.0×~5.0×（不动硬件 zoom，保证物理光圈恒定）
- **曝光组合**：A/S 两种用法——锁光圈算快门，或锁快门算光圈；1/3 档步进
- **胶片 ISO**：6~6400，1/3 档递进，可持久化
- **校准 EV / 曝光补偿**：两级二级菜单，滚轮调节，写入本地存储
- **曝光锁定**：冻结画面与读数，锁定中仍可拖动测光点重新测光
- **长曝光提示**：快门慢于 1s 时数值标红（倒易律失效提醒）

## 环境

- DevEco Studio 6.x，HarmonyOS SDK **API 26**（`compatibleSdkVersion: "26.0.0"`）
- 真机验证机型：HUAWEI MRT-AL10 / HarmonyOS 7.0.0.109 / API 26
- 相机 API 24+ 才能读到手动曝光参数，低版本无法使用

## 构建

```bash
# 1) 依赖（本工程只有一个本地 native 类型包，无网络依赖）
ohpm install

# 2) 命令行构建
export DEVECO_SDK_HOME=/path/to/DevEco/sdk
export PATH=/path/to/DevEco/jbr/bin:/path/to/DevEco/tools/node:$PATH
hvigorw assembleHap --mode module -p product=default -p buildMode=release --no-daemon
```

产物在 `entry/build/default/outputs/default/`。

> **签名**：本仓库**不包含任何签名材料**。`build-profile.json5` 里已移除 `signingConfigs`，请用 DevEco Studio 的
> Project Structure → Signing Configs 生成自己的证书（或使用自动签名），再自行构建安装包。
> `release/` 下的 `.hap` 是作者用个人调试证书签名的版本，仅用于直接侧载试用。

安装到真机：

```bash
hdc install -r release/DSH-Meter-v1.1.0.hap
hdc shell aa start -a EntryAbility -b com.nanqiu.meter
```

## 目录

```
AppScope/                 应用级配置（包名、版本、图标）
entry/src/main/ets/
  pages/Index.ets         主页面：相机、测光、UI 全在这里
  common/Metering.ets     测光算法纯函数（EV、1/3 档表、组合计算）
entry/src/main/resources/
docs/HANDOVER.md          技术细节与踩坑记录（强烈建议先读）
release/                  签名后的安装包
```

## 已知限制

- 物理光圈读不到（`getPhysicalAperture()` 在测试机型上恒为 0，`getSupportedPhysicalApertures()` 返回空），光圈按固定 f/2.2 处理；这与设备/系统有关，不同机型可能不同
- EV 未与真实测光表做过比对，建议用灰卡配合「校准 EV」自行标定
- 测光依赖预览帧亮度，强噪点/强逆光场景下读数会抖
- 只在 MRT-AL10 上验证过，其他机型未测试

## 许可

MIT，见 [LICENSE](LICENSE)。
