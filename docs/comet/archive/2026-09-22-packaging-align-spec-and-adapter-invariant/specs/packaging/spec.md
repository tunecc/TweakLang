# Capability: packaging

## 目的

用一个统一入口把 TweakLang 打包成最终可发布的 `.deb`。产物线、构建方式、安装语义和验收标准全部对齐《越狱插件打包规范（官方原生 rootful / rootless / roothide）》。

除规范现有条目外，本规格额外强制一条**权限不变量**：包内目录必须 `o+rx`、文件必须 `o+r`。这条来自一次真实故障——Settings.app 以 `mobile` 用户运行，`root/wheel 700` 的 bundle 目录它连穿越都不行，症状是「文件在设备上、dpkg 不报错、注销无效、但设置里没有条目」，极难定位。

## 术语

- **产物线（scheme）**：`rootful`、`rootless`、`roothide` 三者之一，对应 Theos 的 `THEOS_PACKAGE_SCHEME`。
- **发布矩阵**：项目实际启用哪些产物线，由入口脚本顶部的 `SCHEMES` 决定。
- **短架构名**：`rootful`→`arm`、`rootless`→`arm64`、`roothide`→`arm64e`。
- **进包物料**：`layout/`、`tweaklangprefs/Resources/`、`TweakLang.plist`。它们的文件系统权限会被 theos 原样带进最终 deb。

## 配置

- 入口脚本：`scripts/build_packages.sh`（`bash`，`set -euo pipefail`）
- `SCHEMES`：发布矩阵，默认 `rootless roothide`；环境变量可覆盖，例如 `SCHEMES="rootful rootless roothide"`
- `THEOS`：默认 `/opt/theos`。该目录的 git remote 是 `https://github.com/roothide/theos.git`，**一份 theos 同时支持 rootless 与 roothide 两种 scheme**，不需要第二份 roothide-theos
- `DISPLAY_NAME`：`TweakLang`，用于 `out/` 文件名
- 每条产物线的中间产物目录：`packages/<scheme>/`
- 最终产物目录：`out/`

## 行为

### P1 发布矩阵

默认启用 `rootless` 与 `roothide` 两条线（与 README「安装包」一致）。

`rootful` **当前不可用**：入口脚本会在开始构建前明确拦下并说明原因，不会静默产出不合规的包。

`rootful` 不可用的原因在本项目的构建配置，而不在 scheme 传值：`vendor/mod/` 下只有 `roothide` 与 `rootless`，没有 rootful 模块，因此 `THEOS_PACKAGE_ARCH` 不会被改成 `iphoneos-arm`；而 `control` 声明 `Architecture: iphoneos-arm64`、`Makefile` 是 `ARCHS = arm64 arm64e`。用空 scheme 实测构建出的 deb 架构仍是 `iphoneos-arm64`（安装根 `/Library` 正确），不符合规范 §10.1 对 rootful 的 `iphoneos-arm` 要求。

启用 rootful 需要的前置改动（超出本 capability 范围）：把 `control` 的 `Architecture` 改为 `iphoneos-arm`、调整 `Makefile` 的 `ARCHS`、补 rootful 目标设备的安装验证。届时只需删掉入口脚本里那段 rootful 拦截。

启用任一产物线前必须满足规范 §6.5：有明确用户场景、有独立构建与安装验证、发布文档说明适用环境、脚本中显式指定或清空对应 scheme。

### P2 逐条构建

对 `SCHEMES` 中的每条 scheme，按顺序：

1. 清空该 scheme 自己的产物目录 `packages/<scheme>/`（保留目录本身，只清内容，带短重试）；
2. 执行 `make -C <repo> clean package FINALPACKAGE=1 THEOS=<theos> THEOS_PACKAGE_DIR=packages/<scheme>/ THEOS_PACKAGE_SCHEME=<scheme>`；
3. 校验该目录中恰好有一个 `.deb`；不是 1 个就报错退出。

约束：

- `THEOS_PACKAGE_SCHEME` 必须出现在 make 命令行上，不继承也不猜测 shell 环境里的值；
- 启用 `rootful` 时传**空值**（规范 §6.2：rootful 是 Theos 的默认 scheme；`vendor/mod/` 没有 rootful 模块，传字面量 `"rootful"` 会让 `common.mk:134` 报 `'rootful' package scheme does not exist`）；
- 每条构建前必须 `make clean`，不允许跨 scheme 复用中间产物；
- 不允许用 `find <package_dir> -name '*.deb' | head -n 1` 之类的方式挑最终包；
- 不允许把 `THEOS_OBJ_DIR` / `THEOS_BUILD_DIR` / `THEOS_STAGING_DIR` 改到临时目录做隔离；
- 模块缓存路径属于本地构建环境 workaround，不是发布规范的一部分，脚本中必须显式标注。

### P3 构建锁

同一项目同一时间只允许一个正式打包流程。锁目录为 `${TMPDIR:-/tmp}/<repo-name>.build.lock`，用 `mkdir` 原子创建；锁内写 pid；发现持锁进程已不存在时清理陈旧锁；进程退出时通过 trap 释放。锁目录变量必须是全局变量，否则 trap 里拿不到。

### P4 单个 deb 的验收

对构建产出的 deb 依次校验，任一项不满足即报错退出，不继续后续 scheme：

1. **包头可读**：`Package` / `Version` / `Architecture` 三个字段都能取到；
2. **架构**：必须等于该 scheme 的期望值——`rootful`→`iphoneos-arm`、`rootless`→`iphoneos-arm64`、`roothide`→`iphoneos-arm64e`；
3. **宿主元数据清洁性**：解包后不得存在 `.DS_Store`、`._*`、`__MACOSX`；一旦发现就净化整包并以 `dpkg-deb -b --root-owner-group` 重打包，再解包复核；
4. **权限可读性（本 capability 自加）**：包内所有目录都必须有 `o+rx`，所有文件都必须有 `o+r`。不满足即失败，并打印具体条目路径。这条守护的是「`mobile` 用户能否穿越目录、能否读取文件」——它对应的是最难定位的一类故障，而且它**必须是承重的**：把任一进包源目录改回 `700`、或任一进包源文件改回 `600`，验收必须失败并指名该条目；
5. **安装根**：
   - `rootless`：解包后必须存在 `var/jb`；
   - `rootful` / `roothide`：不得出现 `var` 安装根，顶层必须是 `Library` / `Applications` / `usr` 之一；`rootful` 还不得出现 `.jbroot` / `libroothide` 运行基线。

### P5 进包物料的权限

`layout/`、`tweaklangprefs/Resources/`、`TweakLang.plist` 等会被 theos 原样拷进最终 deb 的源物料，必须保持：

- 目录 `755`
- 普通文件 `644`

这条不依赖人记得——P4 第 4 条会在每次打包时验证最终 deb，从源头漏过去也会在产物上被拦住。

### P6 产物收敛与命名

验收通过后：

1. 用 `dpkg-deb -f` 从构建产物读取 `Version`；
2. 复制到 `out/<DISPLAY_NAME>_<Version>_<scheme>_<shortArch>.deb`；
3. 对 `out/` 中的副本再执行一次 `dpkg-deb -f ... Package Version Architecture`，确认版本号与架构和本次构建一致，不一致则报错退出。

约束：

- `<Version>` 必须来自最终 deb 的 `DEBIAN/control` `Version` 字段，不能只改文件名；
- `<ShortArch>` 必须与包头 `Architecture` 对应；文件名可省略 `iphoneos-`，包头不能省略；
- 不允许把最终产物命名为 `rootful.deb` / `rootless.deb` / `roothide.deb` / `latest.deb` / `release.deb`；
- `out/` 中的文件按命名覆写，不主动删除 `out/` 下其它历史文件。

### P7 结束输出

全部 scheme 完成后打印 `out/` 中的 `.deb` 清单。

## 不变量

- 每条产物线独立构建、独立验收，不允许从旧产物反向拼装或用一条线的产物伪装另一条线。
- 脚本不做规范 §9 废弃的任何事情：不手工 lift rootless 包树成 roothide、不改 `DEBIAN/control` 架构伪装产物线、不维护静态 `Package_roothide`、不把 staging 中间目录当最终 deb 语义、不用旧 release 二进制反向拼装。
- 不改 `Makefile`、`control`、`TweakLang.plist`；产物线语义交给 Theos / roothide-theos 的官方模块处理。
- 入口脚本必须能在 macOS 自带 `/bin/bash` 3.2 下运行。3.2 在 UTF-8 locale 下会把「`$var` 紧跟一个多字节字符」里的首字节吞进变量名，使 `set -u` 报 unbound variable。因此脚本内所有这类位置一律写成 `${var}`。

## 已知限制

- 未做真机安装验证（规范 §10.3 第 6 条要求 roothide 至少一次真实设备安装验证），只做到解包 + 权限 + 清洁性验收。语言适配在设备上的可见切换已由用户实测生效，但那不覆盖本 capability 的打包改动。
- `rootful` 线当前不可用，原因见 P1；因此没有 rootful 目标设备的安装验证。
- 仓库根原有的 `build_packages.sh` 与 `BUILDING.md` 曾是记录 roothide 构建方式的唯一位置；`BUILDING.md` 已被用户删除，根目录那份脚本目前已跑不通（它在找不存在的 `~/Develop/theos-roothide`）。是否移除根目录脚本由用户决定，本 capability 不代为删除。
- 宿主元数据只在 staging 残留和最终 deb 两个点清理，未在打包前主动清扫整个源码树。
