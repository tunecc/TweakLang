# 目标

让 TweakLang 能单独切换「Hello 键盘侠」（`cn.zqbb.hello.keyboard.ai`，偏好 bundle 为 `HelloKbAIPrefs.bundle`）设置页的显示语言。

该插件的设置页不使用 `.lproj` / `NSBundle` 本地化：二进制里 `localizedStringForKey:`、`NSLocalizedString`、`pathForResource:`、`CFBundleCopyLocalizedString` 全部不存在，中英文案以硬编码形式内联在代码中，运行时只做一次判定：

```objc
BOOL isChinese = [[[NSLocale preferredLanguages] firstObject] hasPrefix:@"zh"];
```

（IDA 位置 `0x46274`、`0x436D8`、`0x17874`；`-[HelloKbAIQuickStartManager localizedTextZh:en:]` @ `0xDAFB8` 即 `return self.isChinese ? zh : en`。）

因此本次通过运行时拦截 `+[NSLocale preferredLanguages]`（按调用方镜像限定作用范围）来切换语言，并让该 bundle 在没有任何 `.lproj` 的情况下也能进入 TweakLang 的扫描列表。

# 范围

- **扫描发现**：`HelloKbAIPrefs.bundle` 即使没有 `.lproj`，也允许出现在 TweakLang 列表中；驱动方式是一张内置的「硬编码双语适配器」注册表，只对注册表内的 bundle 生效。
- **语言选项**：适配器 bundle 只提供 `system` / `zh-Hans` / `en` 三个值。
- **运行时覆盖**：在 Preferences 进程内 hook `+[NSLocale preferredLanguages]`；调用方镜像属于已配置语言的适配器 bundle、且用户值不是 `system` 时，返回用户所选语言，否则 `%orig`。
- **偏好复用**：继续使用现有 `lang_<bundleKey>` 偏好键、`com.tune.tweaklang` 偏好域和 `com.tune.tweaklang/prefschanged` 通知，不引入新的偏好格式。
- **打包入口对齐规范**：把统一打包入口改造为符合《越狱插件打包规范（官方原生 rootful / rootless / roothide）》的形式——每条产物线用原生 scheme 显式构建、产物收敛到 `out/` 并按要求命名、对每个最终 deb 做架构 / 安装根 / 宿主元数据清洁性验收。

# 非目标

- 不切换 Hello 键盘侠 的键盘界面语言。`0helloKbAI.dylib` 注入 `com.apple.UIKit` / `com.apple.springboard`，而 TweakLang 的 `INSTALL_TARGET_PROCESSES = Preferences`，本项目能力范围之外。
- 不静态修改、解密或替换该插件的二进制与资源文件（其字符串运行时解密 + 控制流平坦化，静态改资源不可行）。
- 不支持 `zh-Hans` / `en` 之外的语言。
- 不让所有「无 `.lproj`」的 PreferenceBundle 无条件进入列表——只有注册表内的适配器 bundle 才进。
- 不重构 TweakLang 现有的 `.lproj` 覆盖链路。
- 不新增 rootful 产物线。发布矩阵保持 rootless + roothide（见 README），但脚本结构上允许以后加一条线。
- 不改 `Makefile`、`control`、`TweakLang.plist` 等构建配置，只改打包入口脚本本身。
- 不做真机安装验证（本环境无越狱设备）。

# 验收示例

- `A1` **列表发现**：设备已安装 Hello 键盘侠 时，TweakLang 设置页列表出现该插件条目，显示名取自 `Library/PreferenceLoader/Preferences/HelloKbAIPrefs.plist` 的 `entry.label`（「Hello 键盘侠」）；`HelloKbAIPrefs.bundle` 内没有 `.lproj` 不再成为 `bundleEntryForPath:` 返回 `nil` 的理由。
- `A2` **可选语言**：该条目只有 `system`、`zh-Hans`、`en` 三个可选值，`validValues`/`validTitles`/`values`/`titles`/`titleDictionary` 均只包含这三项，不出现其他语言。
- `A3` **语言覆写值正确**：在 Preferences 进程内，`lang_HelloKbAIPrefs` 为 `zh-Hans` 时，`+[NSLocale preferredLanguages]` 对来自 `HelloKbAIPrefs.bundle` 的调用方返回 `@[@"zh-Hans"]`（满足目标插件 `hasPrefix:@"zh"` 的中文判定）；为 `en` 时返回 `@[@"en"]`（不满足该判定）；为 `system`、键缺失、或适配器未声明的语言（如 `fr`、`zh-Hant`）时返回系统原值。作用域限定归 `A4`，本条只判覆写值本身。
- `A4` **覆盖作用域**：`+[NSLocale preferredLanguages]` 的返回值只在调用方镜像位于 `HelloKbAIPrefs.bundle` 内时被改写；Settings.app 自身调用、其他 PreferenceBundle 的调用、以及调用方镜像无法解析时都返回系统原值。
- `A5` **无回归**：对仍使用 `.lproj` 的插件，`preferredLocalizations`、`localizedStringForKey:value:table:`、`pathForResource:ofType:`（三种形式）、`CFBundleCopyLocalizedString` 的覆盖行为与本 change 之前一致。
- `A6` **兜底**：未安装 Hello 键盘侠、`dladdr` 失败、`__builtin_return_address(0)` 为空、偏好值缺失或类型非法时，hook 一律回退 `%orig`，不崩溃、不产生空白或重复列表项。
- `A7` **统一入口与显式 scheme**：`scripts/build_packages.sh` 按发布矩阵（默认 rootless + roothide）逐条构建；`THEOS_PACKAGE_SCHEME` 在每条 make 命令行上显式传入、不继承 shell 环境；每条构建前执行 `make clean` 并清空该 scheme 自己的产物目录；同一项目同一时间只允许一个打包流程（构建锁）。
- `A8` **产物收敛与命名**：最终 `.deb` 复制到 `out/`，文件名为 `TweakLang_<Version>_<scheme>_<shortArch>.deb`（`rootless`→`arm64`，`roothide`→`arm64e`）；复制后用 `dpkg-deb -f out/<deb> Package Version Architecture` 复核，版本号与架构必须与本次构建产物一致；挑选产物不使用 `find <dir> -name '*.deb' | head -n 1` 之类的方式。
- `A9` **架构与安装根**：rootless deb 包头 `Architecture: iphoneos-arm64`，解包后安装根为 `var/jb`；roothide deb 包头 `Architecture: iphoneos-arm64e`，解包后安装根为 `Library` 等 roothide 语义目录且不出现 `var/jb`。
- `A10` **包内容清洁性**：最终 `.deb` 及其解包目录中不存在 `.DS_Store`、`._*`、`__MACOSX`；一旦发现即净化并以 `--root-owner-group` 重打包。
- `A11` **不引入规范废弃做法**：脚本不手工把 rootless 包树 lift 成 roothide、不改 `DEBIAN/control` 架构伪装产物线、不维护静态 `Package_roothide` 模板、不把 staging 中间目录当作最终 deb 语义。
- `A12` **stock bash 兼容**：`scripts/build_packages.sh` 在 macOS 自带 `/bin/bash` 3.2 下能从第一条 scheme 跑到 `Done` 并退出码 0，`out/` 两条产物齐全；脚本内不存在「`$var` 紧跟多字节字符」的写法（一律 `${var}`）。
- `A13` **rootful 明确拦下**：把 `rootful` 加进 `SCHEMES` 时，脚本在开始构建前就以明确原因退出，不会静默产出架构不符的 rootful deb。

# 约束与不变量

- 不改动 TweakLang 现有的 `.lproj` 覆盖链路（`Tweak.x` 中 `preferredLocalizations` / `localizedStringForKey:` / `pathForResource:` / `CFBundleCopyLocalizedString` 四个 hook 与 `localizedResourcePath` / `localizedStrings` / `preferredLocalizationDirectory` 的行为）。
- `+[NSLocale preferredLanguages]` 的 hook 必须按调用方镜像限定，不得影响 Settings.app 自身或其它 PreferenceBundle 的语言判定。
- 不得把 TweakLang 注入 Preferences 以外的进程（`Makefile` 的 `INSTALL_TARGET_PROCESSES = Preferences` 保持不变）。
- hook 内部必须快速失败：`dladdr` 失败、路径为空、返回地址不可用等一律安全回退 `%orig`，不得抛异常或死循环。
- 适配器注册表必须是数据驱动：新增一个适配器只加一条表项，不改扫描逻辑和拦截逻辑。
- 语言映射与插件自身的判定语义对齐：`zh-Hans` → `@[@"zh-Hans"]`（`hasPrefix:@"zh"` 命中），`en` → `@[@"en"]`，`system` → 不拦截。
- 读取 `lang_*` 偏好值必须校验 `CFString` 类型，类型不符的键直接忽略，不得让 `%ctor` 崩溃。
- 镜像路径标记（`/<bundleName>.bundle/`）的格式全项目只能有一处定义，由 `TLAdapters.h` 的 `TLAdapterImageMarker` 提供，运行时查找表与列表扫描共用。
- `bundleName` 必须等于 bundle 真实目录名（即偏好键 `bundleKey`），否则会出现「列表里能选、实际不生效」的条目。

# 决策

- **工作区**：当前目录（`isolation = current`，`change_branch = main`）。用户已有的未提交清理改动（`.gitignore`、`Tweak.x`、`TLRootListController.m`）原样保留，不纳入本 change。
- **拦截点**：`+[NSLocale preferredLanguages]`。已用 IDA 确认这是 Hello 键盘侠 唯一的地理/语言判定入口（`localizedStringForKey:` / `NSLocalizedString` / `pathForResource:` / `CFBundleCopyLocalizedString` / `AppleLanguages` / `currentLocale` / `localeIdentifier` 在两个 Mach-O 中均不存在）。
- **作用范围限定方式**：`__builtin_return_address(0)` + `dladdr()` 取调用方镜像路径，判断是否落在注册表 bundle 的可执行文件内；不按进程全局改写，避免影响 Settings 本体。
- **发现方式**：内置适配器注册表，首个条目为 `HelloKbAIPrefs`（匹配 bundle 名 / `CFBundleIdentifier` 尾段 / PreferenceLoader `bundle` 引用），只让注册表内的 bundle 在无 `.lproj` 时也进列表，语言集合固定为 `zh-Hans` + `en`。
- **图标/文案来源**：沿用现有 `TLBundleInfoDisplayName` 与 `settingsDisplayNamesByLookupKey`，不新增名称解析路径。
- **打包入口路径**：落在 `scripts/build_packages.sh`（规范 §5 / §11 两次指名该路径）。仓库根原有的未跟踪 `build_packages.sh` 由规范版脚本取代，不再保留两份入口。
- **THEOS**：默认 `/opt/theos`。上游 Theos 2.5.0 自带 `vendor/mod/roothide`，同一份 theos 即可构建 rootless 与 roothide，原脚本里 `ROOTHIDE_THEOS` 的三级探测（`~/Develop/theos-roothide`、`~/Developer/theos-roothide`、`/tmp/theos-roothide`）全部作废。
- **发布矩阵**：保持 rootless + roothide，不新增 rootful 线。`rootful` 当前**不可用**——项目 `control` 声明 `Architecture: iphoneos-arm64`、`Makefile` 是 `ARCHS = arm64 arm64e`，而上游 Theos 没有 rootful vendor 模块不会把架构改成 `iphoneos-arm`，空 scheme 实测产出的 deb 架构仍是 `iphoneos-arm64`，不符合规范 §10.1。入口脚本会在构建前明确拦下并说明，不会静默产出不合规包；`SCHEMES` 仍做成可覆盖变量。
- **bash 兼容性**：入口脚本必须能在 macOS 自带 `/bin/bash` 3.2 下跑通。3.2 在 UTF-8 locale 下会把「`$var` 紧跟多字节字符」的首字节吞进变量名导致 `set -u` 退出，因此脚本内所有这类位置一律写 `${var}`；验收时用 `/bin/bash` 而不是 homebrew bash 5.x 跑。
- **产物目录**：每条 scheme 一个独立目录 `packages/<scheme>/`，构建前清空，避免旧 deb 被误复制（规范 §11.2）。
- **`out/` 清理策略**：只按命名覆写本次产物，不主动删除 `out/` 下其它历史文件。
- **宿主元数据策略**：不在用户源码树上删 `.DS_Store`；只清 staging 残留，并对最终 deb 做「解包 → 净化 → `--root-owner-group` 重打包」兜底（规范 §10.5）。

# 待解决问题

无。目标、范围、验收项和非目标已由用户确认。

# 后续待办（不作为归档验收项）

- **实机可见切换**：在已安装 Hello 键盘侠 的越狱设备上，为该条目选择 `en` 后重新进入其设置页，确认页面的中文案变为英文；改选 `zh-Hans` 后变回中文。本环境无越狱设备，故不列为验收判据；机制部分已在本机尽可能验证，详见规格「已知限制」。
- **R1**：`TLAdapterForBundle` 的 `bundleIdTail` 兜底未强制执行目录名不变量，建议后续把 id-tail 分支改为命中后仍要求目录名与 `bundleName` 一致（或直接删除该兜底）。当前注册表只有一条且目录名精确匹配，不会实际发生。

# 验证预期

- **构建**：`THEOS=/opt/theos make clean && THEOS=/opt/theos make` 通过，`TweakLang`（`Tweak.x`）与 `TweakLangPrefs`（`TLRootListController.m`）两个 target 均无 error。
- **打包入口**：`./scripts/build_packages.sh` 端到端跑通 rootless 与 roothide 两条线；`out/` 中每条产物都用 `dpkg-deb -f` 复核过 Package / Version / Architecture，且与文件名一致；解包后安装根与宿主元数据检查均符合规范 §10。
- **静态检查**：新增代码无 ARC 违规（两个 target 都是 `-fobjc-arc`）；`dladdr` 需要 `<dlfcn.h>`，`Tweak.x` 的 `TweakLang_FRAMEWORKS` 目前只有 `Foundation`，需确认链接期不缺符号。
- **运行时验收**：`A3` 判的是 language-override 覆写值本身，可在本环境用 harness 验证；「实机肉眼看到文案切换」不作为验收项，见「后续待办」。
- **回归**：`A5` / `A6` 通过代码走查确认现有 hook 路径未被改动、所有新增分支都有回退路径。