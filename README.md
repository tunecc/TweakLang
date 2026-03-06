# TweakLang

`TweakLang` 是一个越狱插件，用来为 iPhone `设置.app` 里的各个越狱插件设置页单独指定显示语言。

它的目标不是修改系统全局语言，也不是修改某个 App 本体界面的语言，而是只处理越狱插件在 `设置.app` 中的偏好面板语言。

## 项目作用

- 为不同 tweak 的设置页单独指定语言
- 不直接替换目标插件文件，尽量通过运行时拦截本地化读取来生效
- 支持 `rootless` 和 `roothide` 两种打包方式
- 自带自己的设置面板，可以直接在 `设置.app` 里管理

## 适用范围

`TweakLang` 适用于这类插件：

- 目标 tweak 的设置页使用了标准 `.lproj` / `.strings` 本地化资源
- 或者它通过 `NSBundle` 正常读取本地化字符串和资源

## 不适用的情况

以下情况通常无法切换语言，或者需要额外定向适配：

- 目标 tweak 的文字是硬编码在代码里的，没有语言包
- 目标 tweak 没有 `.lproj` 资源，只提供单一语言
- 目标 tweak 使用了非常规的字符串读取方式，没有走 `NSBundle` 常规本地化流程

这也是为什么有些插件能识别并切换，有些插件即使显示在列表里也不会真正变更语言。

## 功能说明

- 在 `设置.app` 中扫描已安装的 tweak 设置面板
- 为每个 tweak 单独保存一个语言覆盖值
- 支持跟随系统或指定某个已存在的本地化语言
- 修改后重新进入对应 tweak 设置页即可看到效果
- `TweakLang` 自己的设置界面支持中英文切换

## 使用方法

1. 安装 `TweakLang`
2. 打开 `设置.app`
3. 进入 `TweakLang`
4. 在列表里点进某个 tweak
5. 选择你要让它显示的语言
6. 返回后重新进入那个 tweak 的设置页

如果没有立即生效，先完全退出 `设置.app`，再重新进入。

## 安装包

当前项目默认产出两种包：

- `rootless`：`com.tune.tweaklang_<version>_iphoneos-arm64.deb`
- `roothide`：`com.tune.tweaklang_<version>_iphoneos-arm64e.deb`

生成后的文件位于：

```bash
packages/
```

## 构建说明

详细构建方法见：

- [BUILDING.md](/Users/tune/Downloads/untitled%20folder/PrefLangOverride/BUILDING.md)

构建前请注意：

- 不要在带空格的路径下直接构建
- 默认需要分别准备 `rootless` Theos 和 `roothide` Theos
- 每次发布建议同时构建 `rootless` 与 `roothide`

如果只是日常构建，默认入口是：

```bash
./build_packages.sh
```

## 项目结构

- [Tweak.x](/Users/tune/Downloads/untitled%20folder/PrefLangOverride/Tweak.x)
  主 tweak 逻辑，负责在 `设置.app` 中拦截本地化读取
- [tweaklangprefs/TLRootListController.m](/Users/tune/Downloads/untitled%20folder/PrefLangOverride/tweaklangprefs/TLRootListController.m)
  设置界面逻辑
- [layout/Library/PreferenceLoader/Preferences/TweakLang.plist](/Users/tune/Downloads/untitled%20folder/PrefLangOverride/layout/Library/PreferenceLoader/Preferences/TweakLang.plist)
  PreferenceLoader 入口配置
- [control](/Users/tune/Downloads/untitled%20folder/PrefLangOverride/control)
  Debian 包信息
- [build_packages.sh](/Users/tune/Downloads/untitled%20folder/PrefLangOverride/build_packages.sh)
  一键构建 `rootless` 和 `roothide` 包

## 偏好与清理

- 偏好域：`com.tune.tweaklang`
- 卸载时会通过脚本清理偏好文件

## 依赖

- iOS 越狱环境
- `PreferenceLoader`
- `mobilesubstrate`
- `Theos`
- 构建 `roothide` 包时需要 `roothide/theos`

## 当前定位

这是一个偏开发中的项目，重点是：

- 验证不同 tweak 设置页的本地化覆盖能力
- 兼容更多 PreferenceBundle 结构
- 逐步完善 UI、图标、文档和打包流程

## License

MIT
