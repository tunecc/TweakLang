# Capability: preference-pane-language-override

## 目的

TweakLang 为 iPhone「设置.app」中的越狱插件偏好面板单独指定显示语言。它只处理偏好面板，不修改系统全局语言，也不修改被 Hook 插件自身的文件。

本规格描述完整目标行为，包含两类覆盖机制：

1. **资源型覆盖**（既有）：目标 bundle 提供标准 `.lproj` / `.strings`，通过改写 `NSBundle` / `CFBundle` 的本地化读取结果生效。
2. **适配器型覆盖**（既有）：目标 bundle 不提供任何 `.lproj`，而是在代码里用系统首选语言做中/英二选一；通过改写 `+[NSLocale preferredLanguages]` 的返回值生效。

两类机制都由同一张内置的适配器注册表驱动。

## 术语

- **偏好 bundle**：位于 `<jailbreak-root>/Library/PreferenceBundles/*.bundle` 或 `<jailbreak-root>/Library/Application Support/**` 下的 `.bundle`，可被 `PreferenceLoader` 加载进设置.app。
- **jailbreak root**：由 TweakLangPrefs 自身 bundle 路径中 `/Library/PreferenceBundles/` 的前缀推导；找不到时回退 `/var/jb`（存在则该目录）或 `/`。
- **bundleKey**：bundle 目录名去掉 `.bundle` 扩展，作为偏好键与去重依据。
- **语言覆盖值**：`system`（跟随系统）或某个本地化代码，如 `zh-Hans`、`en`。
- **适配器（adapter）**：注册表中的一项，声明某个 bundle 使用「硬编码双语」而非 `.lproj`，并给出它实际支持的语言集合。

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
  - **命中**：保留条目，语言集合取适配器声明的语言，并标记为适配器条目；
  - **未命中**：跳过该 bundle。
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

### B4 资源型覆盖

在 Preferences 进程内，TweakLang hook：

- `-[NSBundle preferredLocalizations]`
- `-[NSBundle localizedStringForKey:value:table:]`
- `-[NSBundle pathForResource:ofType:]`
- `-[NSBundle pathForResource:ofType:inDirectory:]`
- `-[NSBundle pathForResource:ofType:inDirectory:forLocalization:]`
- `CFBundleCopyLocalizedString`

命中条件：bundle 路径包含 `PreferenceBundles`、`Application Support`、`MobileSubstrate`、`.jbroot` 或 `/var/jb/`，且不包含 `/System/`；并且该 bundle 的候选键（bundle 目录名、`Application Support` 容器名、`CFBundleIdentifier` 及其尾段、向上查找的 `.bundle` / `.framework` / `.app` 目录名，以及它们的 normalized 形式）在 `lang_*` 映射中有非 `system` 值。

命中后：按 `preferredLocalizations` 返回用户语言；`localizedStringForKey:` / `CFBundleCopyLocalizedString` 依次尝试 `tableName`（或 `Root` / `Localizable` / `Settings` / bundle 名）在 `<lang>.lproj` 下的 `.strings`；`pathForResource:` 在 `<lang>.lproj`（含 `inDirectory:` 子路径两种拼接顺序）下查找资源。找不到一律 `%orig`。

### B5 适配器型覆盖

TweakLang 额外 hook `+[NSLocale preferredLanguages]`。

判定流程：

1. 取 `__builtin_return_address(0)`；该值必须在 hook 方法体内直接取得并作为参数传入辅助函数，不能在辅助函数内取（否则拿到的是 hook 自身的返回地址）；
2. `dladdr()` 解析该地址所属镜像路径；失败或路径为空则 `%orig`；
3. 用预置的「镜像标记 → 语言」查找表匹配；未命中则 `%orig`；
4. 命中且用户值是适配器声明的语言（如 `zh-Hans`）→ 返回 `@[@"zh-Hans"]`；为 `en` → 返回 `@[@"en"]`；为 `system`、其它值或适配器未声明的语言 → `%orig`。

约束：

- 只按调用方镜像限定，不做进程级全局改写；
- 返回数组必须是新创建的可释放数组；
- 不得在 hook 内触发 `preferredLanguages` 的再次调用（递归）；
- 没有任何适配器被配置非 `system` 语言时，查找表为空，hook 直接 `%orig`，不产生额外开销。

### B6 适配器注册表

注册表定义在项目根目录的 `TLAdapters.h`，由 `Tweak.x`（运行时）与 `tweaklangprefs/TLRootListController.m`（列表）共同包含，是唯一数据源。每项包含：

- `bundleName`：bundle 目录名（不含 `.bundle`）；
- `languages` / `languageCount`：该 bundle 实际支持的语言代码。

表内提供两个入口：

- `TLAdapterForBundle(bundlePath)`：**只按目录名精确匹配**。这是有意的结构性约束，不是遗漏；
- `TLAdapterImageMarker(entry)`：生成该适配器在已加载镜像路径中的标记，形如 `"/HelloKbAIPrefs.bundle/"`。尾部的斜杠不能省略，否则 `X.bundleY/` 会被误判。

**不变量（结构性成立）**：`bundleName` 必须等于 bundle 的真实目录名，同时就是偏好键 `bundleKey`。列表侧用它写 `lang_<bundleKey>`，运行时侧用它拼镜像标记，两边因此必然指向同一个名字。

这条不变量之所以是结构性的，是因为注册表**不提供任何按 `CFBundleIdentifier` 尾段命中的途径**。早期版本曾有这样一个兜底分支，但它只可能在目录名不一致时命中——而那正是它要防的失败模式（「列表里能选、实际不生效」）。`Tweak.x` 的 `configuredLanguageForAdapter` 同样只以 `bundleName` 及其 normalized 形式作偏好键候选，不用 identifier 尾段，否则另一个恰好同名的 bundle 的偏好会被这个适配器捡走。

若未来某个适配器的目录名与想要的键不同，正确做法是让 `bundleName` 就等于目录名。

首个条目为 `HelloKbAIPrefs`，语言 `zh-Hans` + `en`。新增适配器只追加一条表项，不修改 B1 的扫描逻辑与 B5 的拦截逻辑。

### B7 偏好读取与容错

- 读取 `lang_*` 时校验类型必须是 `CFString`，否则忽略该键。没有这道守卫时，手改 plist 写入非字符串会让 `%ctor` 里的 `isEqualToString:` 直接把设置.app 带崩。
- 任何一步失败（bundle 不存在、`NSBundle bundleWithPath:` 返回 nil、`.strings` 读不出来、`dladdr` 失败等）都回退到原有返回值，不抛异常、不缓存错误状态。
- 收到 `com.tune.tweaklang/prefschanged` 时重载偏好映射并清空 strings 缓存。

## 不变量

- 只注入 `Preferences` 进程（`INSTALL_TARGET_PROCESSES = Preferences`）。
- 资源型覆盖（B4）与适配器型覆盖（B5）互不影响：没有适配器条目时，B5 永远 `%orig`。
- `system` 永远是每个条目的第一项，且永不写入偏好文件。
- 不修改任何第三方插件的文件；所有效果都在运行时产生。
- `bundleName` 必须等于 bundle 真实目录名；B6 的结构使它不可能被违反。

## 已知限制

- 适配器型覆盖要求目标插件在**每次需要文案时**重新查询 `+[NSLocale preferredLanguages]`。若某插件把判定结果缓存进静态变量，需要重新进入设置页（极端情况需 respring）才会变化。已确认 Hello 键盘侠 的 `isChinese` 是 `presentFromController:isChinese:plistPath:` 的入参而非 ivar，每次呈现时重新计算。
- **实机可见切换已由用户实测生效**：在 roothide 设备上为该条目选择 English / 简体中文，重新进入 Hello 键盘侠 设置页，文案确认发生切换。
- 适配器型覆盖只对设置页有效；注入到 UIKit / SpringBoard 的键盘界面不在范围内。
- 适配器注册表是人工维护的白名单，未登记的「无 `.lproj`」bundle 不会出现在列表中。
- `HelloKbAIPrefs` 的 `__objc_methname` 中除 `preferredLanguages` 外也存在 `preferredLocalizations` selector。该路径由既有的资源型覆盖（B4）覆盖，因此适配器 hook 是双保险而非唯一生效路径；但无法静态判定它是否真被调用——`__objc_selrefs` 共 527 项且全部非零，通过 `LC_DYLD_CHAINED_FIXUPS` 编码，只能在运行时绑定后确认。
- `bundleLanguageMap` / `bundleLanguageAliasMap` / `adapterImageLanguageMap` 在 Darwin 通知线程被整体替换、在主线程读取，沿用项目既有的无锁替换模式。
