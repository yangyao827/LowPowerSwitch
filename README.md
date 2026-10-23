# LowPowerSwitch

在 iOS 10.3.3 控制中心顶部加入低电量模式开关，直接点击开启或关闭，无需进入设置。

当前版本 **0.1.4**，在 0.1.3 的基础上将电池图标整体缩小 15%，按钮大小和颜色逻辑保持一致。已在越狱 **iPhone 6 Plus / iOS 10.3.3 / ARM64** 上安装，用户已确认调整后的尺寸和外观满意。

## 功能

- 顶部显示六个开关，低电量模式位于最右侧。
- 关闭时为原生灰色圆底、黑色电池图标；开启时为黄色圆底、白色电池图标。黄色直接读取系统飞行模式按钮的选中色。
- 采用系统自带的 `CCUILowPowerModeSetting` 处理电源模式切换与状态同步，从设置页切换后也会更新按钮。
- 切换时提示“低电量模式：打开”或“低电量模式：关闭”。
- 独立插件，无需 Activator、Flipswitch 或录屏插件；不写调试日志。

## 安装

下载 [0.1.4 安装包](dist/local.lowpowercc_0.1.4_iphoneos-arm.deb)，复制到手机后通过 Filza 安装，或使用 root SSH：

```sh
dpkg -i /手机上的路径/local.lowpowercc_0.1.4_iphoneos-arm.deb
killall SpringBoard
```

安装后会注销桌面，重新打开控制中心即可使用。请先停止录屏并保存游戏进度。

依赖 MobileSubstrate 和 iOS 10.3.x。包标识为 `local.lowpowercc`，在 Cydia 中显示为 **Low Power Mode for Control Center (iOS 10.3)**。尚未验证 iOS 10.2 或其他设备，不应仅修改依赖后强制安装。

## 在 Windows 上构建

需要 Python、Zig **0.14.1**、支持 Mach-O 的 LLVM 链接器 `ld.lld.exe`，以及 iOS 10.3 SDK。工具链与 SDK 不包含在仓库中；安装现成 DEB 不需要这些工具。

```powershell
python -m pip install -r requirements.txt
git clone --depth 1 --filter=blob:none --sparse https://github.com/theos/sdks.git .toolchain/sdks
git -C .toolchain/sdks sparse-checkout set iPhoneOS10.3.sdk
```

准备好编译器和链接器，将 [toolchain.example.json](toolchain.example.json) 复制到 `.toolchain/local-tools.json`，按实际位置修改路径：

```powershell
Copy-Item toolchain.example.json .toolchain/local-tools.json
python build.py
```

配置中的相对路径以项目根目录为基准，支持绝对路径。也可用 `LOWPOWER_ZIG`、`LOWPOWER_LINKER`、`LOWPOWER_SDK` 环境变量分别指定路径，或用 `IOS_CC_TOOLCHAIN` 指定存放 `local-tools.json` 的工具链目录。

构建结果为 `build/LowPowerCC.dylib`，最低系统版本为 iOS 10.3。构建脚本会将旧 SDK 的 TAPI 接口转换成链接器可用的存根；手机运行时仍使用系统框架。项目可以独立构建，不依赖其他项目目录。

## 签名、打包与部署

手机需要处于越狱状态，装有 MobileSubstrate、SSH 服务和可运行的 `ldid`。脚本在手机上签名，生成 DEB，再安装并注销桌面：

```powershell
python tools/deploy.py
```

按提示输入手机地址和 root 密码，密码不会回显。SSH 端口默认 `2222`，OpenSSH 通常用 `22`，可通过 `IPHONE_PORT` 环境变量指定。首次连接应先用 SSH 核对并保存手机主机密钥，部署脚本读取用户的 `known_hosts`。

自动化部署支持 `IPHONE_HOST`、`IPHONE_PORT`、`IPHONE_PASSWORD` 环境变量；这些值不写入源码或安装包。Python 依赖通常由 `requirements.txt` 安装；如使用独立依赖目录，可通过 `IOS_SSH_PYTHON` 指定。

DEB 生成到 `dist/`，同时保留 0.1.3 安装包供回退；重新部署同版本会更新本地安装包文件。

## 文件

| 路径 | 用途 |
| --- | --- |
| `src/LowPowerCC.m` | 原生低电量模式按钮启用、六按钮布局、图标与提示文案 |
| `LowPowerCC.plist` | 仅加载到 SpringBoard 的注入配置 |
| `build.py` | Windows 交叉编译与链接 |
| `tools/deploy.py` | 手机签名、DEB 打包与安装 |
| `dist/` | 可直接安装的 DEB |

## 卸载

在 Cydia 中卸载本插件，或通过 root SSH：

```sh
dpkg --purge local.lowpowercc
killall SpringBoard
```

卸载后恢复原来的五个顶部开关，保留当时的系统低电量模式状态。

## 参考与许可

使用系统私有接口，接口参考 [iOS Runtime Headers](https://github.com/nst/iOS-Runtime-Headers/tree/995b3bb9011192afcd70eed8fb73f1b6688c52f2/PrivateFrameworks/ControlCenterUI.framework)。按钮绘制和构建、部署工具沿用 [ios-recoder](https://github.com/yangyao827/ios-recoder) 中的实现；该项目基于 Cole Cabral 及贡献者的 CCRecord。

MIT 许可，见 [LICENSE](LICENSE)。
