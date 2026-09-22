# 目标

两件事：

1. **把统一打包入口对齐《越狱插件打包规范（官方原生 rootful / rootless / roothide）》**：入口位置、产物收敛与命名、对每个最终 deb 的验收，都按规范来。并在此过程中把一次真实线上故障的教训固化成断言——**包内目录必须 `o+rx`、文件必须 `o+r`**，因为 Settings.app 以 `mobile` 用户运行，`root/wheel 700` 的 bundle 目录它连穿越都不行。
2. **修掉 R1**：`TLAdapterForBundle` 的 `bundleIdTail` 兜底命中后没有复核目录名，违反了它自己注释里声明的不变量，会放过目录名不一致的 bundle，造成「列表里能选、实际不生效」的条目。

# 范围

- **新增 `scripts/build_packages.sh`**（规范 §5 指名的入口路径）。`THEOS` 默认 `/opt/theos` 一条打 rootless + roothide 两种 scheme。
- 每条产物线：清空该 scheme 自己的 `packages/<scheme>/` → `make clean package FINALPACKAGE=1` 且 scheme 显式传在 make 命令行 → 校验目录中恰好 1 个 `.deb` → `verify_deb`（架构、安装根、宿主元数据、**权限**）→ 复制到 `out/` → `dpkg-deb -f` 复核。
- **权限断言**（规范现有条目之外，本项目自加）：包内所有目录 `o+rx`、所有文件 `o+r`，不满足即构建失败并指出具体路径。
- 规范 §11.3 的构建锁（含陈旧锁回收）与目录清空加重试。
- `rootful` 在脚本里明确拦下，并说明原因（`control` 声明 `iphoneos-arm64`、`Makefile` 是 `ARCHS = arm64 arm64e`、`vendor/mod/` 无 rootful 模块，空 scheme 产出的架构仍不符规范 §10.1）。
- **R1 修复**：移除 `TLAdapterForBundle` 的 id-tail 分支与 `TLAdapterEntry` 的 `bundleIdTail` 字段，目录名精确匹配成为唯一途径；`Tweak.x` 的 `configuredLanguageForAdapter` 只以 `bundleName` 及其 normalized 形式作候选键。
- **修复源码树权限**（本次线上故障的直接原因）：`layout/`、`tweaklangprefs/Resources/` 由 700/600 改为 755/644；`TweakLang.plist`、`control`、`postrm` 由 600 改为 644。

# 非目标

- 不新增 `rootful` 产物线；启用它需要先改 `control` 与 `Makefile` 的 `ARCHS`，超出本 change。
- 不改 `Makefile`、`control`、`TweakLang.plist`（filter 与依赖声明）。
- 不改语言覆盖的行为：`HelloKbAIPrefs` 的匹配方式、覆写值集合（`system` / `zh-Hans` / `en`）、`+[NSLocale preferredLanguages]` 的作用域与全部回退路径均与 R1 修复前一致。
- 不删除仓库根原有的 `build_packages.sh`（它目前已跑不通，但是否移除由用户决定）。
- 不引入新的偏好域或偏好键。
- 不做真机安装验证。语言适配在设备上的可见切换已由用户实测生效（Hello 键盘侠 中英文案切换正常）；本 change 新增的打包脚本尚未做真机安装验证。

# 验收示例

- `A1` **入口与显式 scheme**：`scripts/build_packages.sh` 按发布矩阵（默认 rootless + roothide）逐条构建；`THEOS_PACKAGE_SCHEME` 在每条 make 命令行上显式传入、不继承 shell 环境；每条构建前执行 `make clean` 并清空该 scheme 自己的产物目录；同一项目同一时间只允许一个打包流程（构建锁）。
- `A2` **产物收敛与命名**：最终 `.deb` 复制到 `out/`，文件名为 `TweakLang_<Version>_<scheme>_<shortArch>.deb`；复制后用 `dpkg-deb -f out/<deb> Package Version Architecture` 复核，版本号与架构必须与本次构建产物一致；挑选产物不使用 `find <dir> -name '*.deb' | head -n 1` 之类的方式。
- `A3` **架构与安装根**：rootless deb 包头 `Architecture: iphoneos-arm64`，解包后安装根为 `var/jb`；roothide deb 包头 `Architecture: iphoneos-arm64e`，解包后安装根为 `Library` 等 roothide 语义目录且不出现 `var/jb`。
- `A4` **包内容清洁性**：最终 `.deb` 及其解包目录中不存在 `.DS_Store`、`._*`、`__MACOSX`；一旦发现即净化并以 `--root-owner-group` 重打包。
- `A5` **权限可读性**：最终 `.deb` 内所有目录都具有 `o+rx`、所有文件都具有 `o+r`；不满足即构建失败并指出具体条目路径。
- `A6` **权限断言承重（变异测试）**：把任一进包的源目录改回 `700`、或任一进包的源文件改回 `600`，`scripts/build_packages.sh` 必须以非零码失败并在输出中指名该条目；恢复后能重新干净通过。
- `A7` **rootful 明确拦下**：`SCHEMES` 中包含 `rootful` 时，脚本在开始任何构建前就以明确原因退出，不产出任何 deb。
- `A8` **stock bash 兼容**：`scripts/build_packages.sh` 在 macOS 自带 `/bin/bash` 3.2 下能从第一条 scheme 跑到 `Done` 且退出码 0；脚本内不存在「`$var` 紧跟多字节字符」的写法（一律 `${var}`）。
- `A9` **R1 结构性修复**：`TLAdapterForBundle` 只按目录名精确匹配；对 `HelloKbAIPrefsX.bundle`、`XHelloKbAIPrefs.bundle`、以及 identifier 无关的 bundle 均返回 `NULL`；`bundleIdTail` 已从注册表结构和两个消费方完全移除。
- `A10` **偏好键无跨 bundle 泄漏**：`configuredLanguageForAdapter` 只以 `bundleName` 及其 normalized 形式作候选键；为一个恰好同名的其它 bundle 设置语言，不会影响本适配器取到的值。
- `A11` **语言覆盖行为不变**：`HelloKbAIPrefs` 的匹配、覆写值集合、`+[NSLocale preferredLanguages]` 的作用域限定与全部失败路径回退 `%orig` 的行为，与 R1 修复前一致。
- `A12` **构建产物含修复**：`out/` 中的 roothide deb 内，`TweakLangPrefs` 与 `TweakLang.dylib` 都不含 `HelloKbAI` 尾段字符串、都含 `HelloKbAIPrefs` 目录名字符串。

# 约束与不变量

- 一条 `/opt/theos`（其 git remote 为 `https://github.com/roothide/theos.git`）同时支持 rootless 与 roothide 两种 scheme；不需要、也不应该再找第二份 roothide-theos。
- 不改 `Makefile`、`control`、`TweakLang.plist` 的 filter 与依赖声明。
- 语言覆盖链路（`NSBundle` 的四个 hook、`CFBundleCopyLocalizedString`、`+[NSLocale preferredLanguages]`）的行为不变。
- 源码树中所有会进包的安装物料必须保持目录 `755` / 文件 `644`；这条由 `A5` / `A6` 的断言守护，不再依赖人记得。
- 入口脚本必须能在 macOS 自带 `/bin/bash` 3.2 下运行：所有 `$var` 后紧跟非 ASCII 字符的位置一律写 `${var}`。
- 不做规范 §9 废弃的任何事情：不手工 lift 包树、不改 `DEBIAN/control` 架构伪装产物线、不维护静态 `Package_roothide` 模板、不把 staging 当最终 deb 语义。
- `-fmodules-cache-path` 是本地构建环境 workaround，不是发布规范的一部分，脚本中必须显式标注。

# 决策

- **工作区**：当前目录（`isolation = current`，`change_branch = main`）。用户已有的未提交改动原样保留，不纳入本 change 的提交。
- **入口路径**：`scripts/build_packages.sh`，即规范 §5 指名的位置。
- **THEOS**：默认 `/opt/theos`，一条打两种包。其 remote 已核实为 `roothide/theos.git`，最近提交含「add roothide support」「Add rootless.h compatibility to support building roothide packages」。
- **发布矩阵**：rootless + roothide，不启用 rootful；`SCHEMES` 做成可覆盖变量，但 rootful 在脚本里被明确拦下并说明缺什么前置改动。
- **产物目录**：每条线独立的 `packages/<scheme>/` 作中间目录，`out/` 作最终目录；`out/` 只按命名覆写本次产物，不主动删除其它历史文件。
- **宿主元数据策略**：不在用户源码树上删 `.DS_Store`；只清 `.theos` staging 残留，并对最终 deb 做「解包 → 净化 → `--root-owner-group` 重打包」兜底。
- **权限修复范围**：只改会进包的物料（`layout/`、`tweaklangprefs/Resources/`、`TweakLang.plist`、`control`、`postrm`），不动仓库其它部分的权限。
- **R1 的修法**：选择「移除兜底」而不是「加一道校验」，让不变量结构性成立——id-tail 分支只可能在 directory 名不一致时命中，而那正是它要防的失败模式。`configuredLanguageForAdapter` 的 id-tail 候选键同样移除，因为它是一个跨 bundle 泄漏口。
- **仓库根的 `build_packages.sh`**：暂不删除。它目前已跑不通（在找不存在的 `~/Develop/theos-roothide`），是否移除由用户决定。

# 待解决问题

无。目标、范围、验收项和非目标已由用户确认。

# 验证预期

- **构建**：`THEOS=/opt/theos make` 通过，`TweakLang`（`Tweak.x`）与 `TweakLangPrefs`（`TLRootListController.m`）两个 target 的 arm64 + arm64e 均无 error。
- **打包入口**：`./scripts/build_packages.sh` 在 stock `/bin/bash` 3.2 下端到端跑通 rootless 与 roothide 两条线，退出码 0，`out/` 两条产物齐全且都通过 `verify_deb`。
- **变异测试**：`A6` 的三组变异（源目录 700、源文件 600、`SCHEMES=rootful`）都必须被断言抓到并非零退出；恢复后干净通过。这条专门用来证明断言不是空转。
- **静态检查**：新增代码无 ARC 违规（两个 target 都是 `-fobjc-arc`）；bash 脚本静态扫描「`$var` 紧跟非 ASCII 字节」为 0 处。
- **真机验证状态**：语言适配的设备可见切换已由用户实测生效（不在本 change 的验收项内）；本 change 新增的打包脚本未做真机安装验证，需在 handoff 中明确记录。
