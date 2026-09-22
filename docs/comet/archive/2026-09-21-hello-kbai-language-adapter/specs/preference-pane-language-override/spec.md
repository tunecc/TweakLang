# Capability: preference-pane-language-override

## 目的

TweakLang 为 iPhone「设置.app」中的越狱插件偏好面板单独指定显示语言。它只处理偏好面板，不修改系统全局语言，也不修改被Hook插件自身的文件。

本规格描述完整目标行为，包含两类覆盖机制：

1. **资源型覆盖**（既有）：目标 bundle 提供标准 `.lproj` / `.strings`，通过改写 `NSBundle` / `CFBundle` 的本地化读取结果生效。
2. **适配器型覆盖**（本 change 新增）：目标 bundle 不提供任何 `.lproj`，而是在代码里用系统首选语言做中/英二选一；通过改写 `+[NSLocale preferredLanguages]` 的返回值生效。

## 术语

- **偏好 bundle**：位于 `<jailbreak-root>/Library/PreferenceBundles/*.bundle` 或 `<jailbreak-root>/Library/Application Support/**` 下的 `.bundle`，可被 `PreferenceLoader` 加载进设置.app。
- **jailbreak root**：由 TweakLangPrefs 自身 bundle 路径中 `/Library/PreferenceBundles/` 的前缀推导；找不到时回退 `/var/jb`（存在则该目录）或 `/`。
- **bundleKey**：bundle 目录名去掉 `.bundle` 扩展，作为偏好键与去重依据。
- **语言覆盖值**：`system`（跟随系统）或某个本地化代码，如 `zh-Hans`、`en`。
- **适配器（adapter）**：一条注册表项，声明某个 bundle 使用「硬编码双语」而非 `.lproj`，并给出它实际支持的语言集合。

## 配置

- 偏好域：`com.tune.tweaklang`
- 变更通知：`com.tune.tweaklang/prefschanged`（Darwin 通知中心，Coalesce）
- 语言覆盖键：`lang_<bundleKey>`，值为语言代码；`system` 或空值表示删除该键
- 界面语言键：`ui_language`，只影响 TweakLang 自己的设置页，取值 `system` / `en` / `zh-Hans`

## 行为

### B1 扫描与列表

TweakLangPrefs 在每次构建 specifier 时扫描偏好 bundle，条目按显示名排序，已定制过语言的条目排在前。

扫描顺序：

1. `<jailbreak-root>/Library/PreferenceBundles` 下的 `.bundle`（非递归）
2. `<jailbreak-root>/Library/Application Support` 与各 `.jbroot-*/Library/Application Support` 下的 `.bundle`（递归，跳过 `.app` / `.framework` 子树）

对每个 bundle 生成条目时：

- 读取 bundle 内所有 `*.lproj`（排除 `Base.lproj`）得到语言集合；
- 若语言集合为空，检查该 bundle 是否命中适配器注册表：
  - **命中**：保留条目，语言集合取适配器声明的语言（当前为 `zh-Hans`、`en`），并标记为适配器条目；
  - **未命中**：跳过该 bundle（与既有行为一致）。
- 显示名优先取 `Library/PreferenceLoader/Preferences/*.plist` 中 `entry.label`（按 bundle 名、bundleKey、normalized bundleKey、`CFBundleIdentifier` 及其尾段匹配），其次取 `CFBundleDisplayName` / `CFBundleName`，最后回退 bundleKey；同名多项时追加 ` (bundleKey)` 区分。
- `bundleKey` 已出现过则跳过；`TweakLangPrefs` 自身跳过。

### B2 语言选项

每个条目的可选值：

- 第一项固定为 `system`；
- 其余为 B1 得到的语言集合，按代码大小写不敏感排序；
- 标题由 `ui_language` 决定的 locale 通过 `displayNameForKey:NSLocaleIdentifier` 生成，格式为 `名称 (代码)`，取不到名称时直接显示代码。

### B3 选择语言

用户选择某个值后：

- 写入 `lang_<bundleKey>`（`system` 或空值则删除该键），同时清理历史遗留键；
- `CFPreferencesAppSynchronize`；
- 投递 `com.tune.tweaklang/prefschanged`。

### B4 资源型覆盖（既有链路，不变）

在 Preferences 进程内，TweakLang hook：

- `-[NSBundle preferredLocalizations]`
- `-[NSBundle localizedStringForKey:value:table:]`
- `-[NSBundle pathForResource:ofType:]`
- `-[NSBundle pathForResource:ofType:inDirectory:]`
- `-[NSBundle pathForResource:ofType:inDirectory:forLocalization:]`
- `CFBundleCopyLocalizedString`

命中条件：bundle 路径包含 `PreferenceBundles`、`Application Support`、`MobileSubstrate`、`.jbroot` 或 `/var/jb/`，且不包含 `/System/`；并且该 bundle 的候选键（bundle 目录名、`Application Support` 容器名、`CFBundleIdentifier` 及其尾段、向上查找的 `.bundle` / `.framework` / `.app` 目录名，以及它们的 normalized 形式）在 `lang_*` 映射中有非 `system` 值。

命中后：按 `preferredLocalizations` 返回用户语言；`localizedStringForKey:` / `CFBundleCopyLocalizedString` 依次尝试 `tableName`（或 `Root` / `Localizable` / `Settings` / bundle 名）在 `<lang>.lproj` 下的 `.strings`；`pathForResource:` 在 `<lang>.lproj`（含 `inDirectory:` 子路径两种拼接顺序）下查找资源。找不到一律 `%orig`。

### B5 适配器型覆盖（新增链路）

TweakLang 额外 hook `+[NSLocale preferredLanguages]`。

判定流程：

1. 取 `__builtin_return_address(0)`；为空则 `%orig`。该值必须在 hook 方法体内直接取得并作为参数传入辅助函数，不能在辅助函数内部取（否则拿到的是 hook 自身的返回地址）。
2. `dladdr()` 解析该地址所属镜像路径；失败或路径为空则 `%orig`。
3. 若镜像路径不包含任何「已配置语言」的适配器 bundle 的 `/<bundleName>.bundle/` 标记，则 `%orig`。
4. 命中且用户值为适配器声明的语言（如 `zh-Hans`）→ 返回 `@[@"zh-Hans"]`；为 `en` → 返回 `@[@"en"]`；为 `system`、其它值或适配器未声明的语言 → `%orig`。

约束：

- 只按调用方镜像限定，不做进程级全局改写，Settings.app 自身与其它 PreferenceBundle 的调用不受影响。
- 返回数组必须是新创建的可释放数组，调用方按 `NSLocale` 语义使用。
- 不得在 hook 内触发 `preferredLanguages` 的再次调用（递归）。
- 没有任何适配器被配置非 `system` 语言时，查找表为空，hook 直接 `%orig`，不产生额外开销。

### B6 适配器注册表

注册表定义在项目根目录的 `TLAdapters.h`，由 `Tweak.x`（运行时）与 `tweaklangprefs/TLRootListController.m`（列表）共同包含，是唯一数据源。每项包含：

- `bundleName`：bundle 目录名（不含 `.bundle`）。**必须等于 bundle 的真实目录名**，同时是偏好键 `bundleKey`；
- `bundleIdTail`：`CFBundleIdentifier` 的最后一段，仅用于偏好键别名查找，填 `NULL` 表示不用；
- `languages` / `languageCount`：该 bundle 实际支持的语言代码（首个条目为 `zh-Hans`、`en`）。

表内提供两个入口：

- `TLAdapterForBundle(bundlePath, bundleIdentifier)`：供列表扫描匹配 bundle 目录名，或以 `CFBundleIdentifier` 尾段兜底发现；
- `TLAdapterImageMarker(entry)`：生成该适配器在已加载镜像路径中的标记，形如 `"/HelloKbAIPrefs.bundle/"`。尾部的斜杠不能省略，否则 `X.bundleY/` 会被误判。

运行时侧的预置查找表（B5 第 3 步）用 `TLAdapterImageMarker` 生成键，因此标记格式全项目只有一处定义。

首个条目为 `HelloKbAIPrefs`（`bundleIdTail` 为 `HelloKbAI`，来自 `cn.zqbb.HelloKbAI`）。新增适配器只追加一条表项，不修改 B1 的扫描逻辑与 B5 的拦截逻辑。

**不变量**：`bundleName` 必须等于 bundle 的真实目录名。列表侧用它当 `bundleKey` 写 `lang_<bundleKey>`，运行时侧用它拼镜像标记；两者必须指向同一个名字，否则会出现「列表里能选、实际不生效」的条目。

### B7 偏好读取与容错

- 读取 `lang_*` 时校验类型必须是 `CFString`，否则忽略该键。
- 任何一步失败（bundle 不存在、`NSBundle bundleWithPath:` 返回 nil、`.strings` 读不出来、`dladdr` 失败等）都回退到原有返回值，不抛异常、不缓存错误状态。
- 收到 `com.tune.tweaklang/prefschanged` 时重载偏好映射并清空 strings 缓存。

## 不变量

- 只注入 `Preferences` 进程（`INSTALL_TARGET_PROCESSES = Preferences`）。
- 资源型覆盖（B4）与适配器型覆盖（B5）互不影响：没有适配器条目时，B5 永远 `%orig`。
- `system` 永远是每个条目的第一项，且永不写入偏好文件。
- 不修改任何第三方插件的文件；所有效果都在运行时产生。

## 已知限制

- 适配器型覆盖要求目标插件在**每次需要文案时**重新查询 `+[NSLocale preferredLanguages]`。若某插件把判定结果缓存进静态变量，需要重新进入设置页（极端情况需 respring）才会变化。已确认 Hello 键盘侠 的 `isChinese` 是 `presentFromController:isChinese:plistPath:` 的入参而非 ivar，每次呈现时重新计算，正常情况下重新进页即生效。
- **`A3D` 实机可见切换未验证（后续待办，不阻塞归档）**：本环境无越狱设备，「为该条目选择 `en` / `zh-Hans` 后重新进入 Hello 键盘侠 设置页、页面可见文案真的切换」这一项无法验证。其机制已在本机尽可能验证（`zh-Hans` 命中 `hasPrefix:@"zh"`、`en` 不命中、`system` 与未声明语言回退 `%orig`、目标二进制中不存在其它语言判定入口）。归档判据 `A3` 只覆盖覆写值本身（device-independent），可见切换作为后续待办单独登记。
- **R1（`TLAdapterForBundle` 的 `bundleIdTail` 兜底未强制执行目录名不变量）**：`TLAdapters.h` 的注释声明「`bundleIdTail` 只是发现阶段的兜底，命中后仍然要求目录名与 `bundleName` 一致」，但实现中的 id-tail 分支直接返回条目、没有复核目录名，因此一个 `CFBundleIdentifier` 尾段匹配但目录名不同的 bundle（例如 `HelloKbAIPrefsX.bundle`）也会被当成适配器。后果是它会在列表里得到 `zh-Hans` / `en` 条目，而运行时镜像标记 `/HelloKbAIPrefs.bundle/` 永远匹配不上——正是 B6 不变量要防止的「列表里能选、实际不生效」。当前注册表只有一条且目录名精确匹配，故未实际发生；目录名匹配本身是精确的（已实测 `HelloKbAIPrefsX.bundle` 与 `XHelloKbAIPrefs.bundle` 在 identifier 无关时均返回 `NULL`）。本 change 按「不改代码，记录后归档」处理，留待后续修订。
- 适配器型覆盖只对设置页有效；注入到 UIKit / SpringBoard 的键盘界面不在范围内。
- 适配器注册表是人工维护的白名单，未登记的「无 `.lproj`」bundle 不会出现在列表中。
- `HelloKbAIPrefs` 的 `__objc_methname` 中除 `preferredLanguages` 外也存在 `preferredLocalizations` selector。该路径由既有的资源型覆盖（B4 的 `-[NSBundle preferredLocalizations]` hook）覆盖，因此适配器 hook 是双保险而非唯一生效路径；但无法静态判定它是否真被调用——`__objc_selrefs` 共 527 项且全部非零，通过 `LC_DYLD_CHAINED_FIXUPS` 编码，只能在运行时绑定后确认。
- `bundleLanguageMap` / `bundleLanguageAliasMap` / `adapterImageLanguageMap` 在 Darwin 通知线程被整体替换、在主线程读取，沿用项目既有的无锁替换模式（本 change 未引入新的同步机制，也未改变该模式）。
- roothide 产物线在本机可原生构建（上游 Theos 2.5.0 自带 `vendor/mod/roothide`，`THEOS_PACKAGE_SCHEME=roothide` 会把 `THEOS_PACKAGE_ARCH` 固定为 `iphoneos-arm64e`）。本项目当前只发布 rootless + roothide、未启用 rootful，符合发布矩阵选择；`build_packages.sh` 中 roothide 分支的 `ROOTHIDE_THEOS` 探测路径已过时，以及打包规范 §10.5 宿主元数据清洁、§11 `out/` 命名与 `dpkg-deb -f` 核对尚未实现，均属另一个 change 的范围。
