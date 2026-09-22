# Capability: packaging

## 目的

用一个统一入口把 TweakLang 打包成最终可发布的 `.deb`，产物线、构建方式、安装语义和验收标准全部对齐《越狱插件打包规范（官方原生 rootful / rootless / roothide）》。

## 术语

- **产物线（scheme）**：`rootful`、`rootless`、`roothide` 三者之一，对应 Theos 的 `THEOS_PACKAGE_SCHEME`。
- **发布矩阵**：项目实际启用哪些产物线，由入口脚本顶部的 `SCHEMES` 决定。
- **短架构名**：`rootful`→`arm`、`rootless`→`arm64`、`roothide`→`arm64e`。

## 配置

- 入口脚本：`scripts/build_packages.sh`（`bash`，`set -euo pipefail`）
- `SCHEMES`：发布矩阵，默认 `rootless roothide`；环境变量可覆盖，例如 `SCHEMES="rootful rootless roothide"`
- `THEOS`：默认 `/opt/theos`。上游 Theos 2.5.0 自带 `vendor/mod/roothide`，同一份 theos 即可构建 rootless 与 roothide
- `DISPLAY_NAME`：`TweakLang`，用于 `out/` 文件名
- 每条产物线独立的产物目录：`packages/<scheme>/`

## 行为

### P1 发布矩阵

默认启用 `rootless` 与 `roothide` 两条线（与 README「安装包」一致）。`rootful` **当前不可用**：入口脚本会在开始构建前明确拦下并说明原因，不会静默产出不合规的包。

`rootful` 不可用的原因在本项目的构建配置，而不在 scheme 传值：`/opt/theos/vendor/mod/` 下只有 `roothide` 与 `rootless`，没有 rootful 模块，因此 `THEOS_PACKAGE_ARCH` 不会被改成 `iphoneos-arm`；而 `control` 声明 `Architecture: iphoneos-arm64`、`Makefile` 是 `ARCHS = arm64 arm64e`。用空 scheme 实测构建出的 deb 架构仍是 `iphoneos-arm64`（安装根 `/Library` 正确），不符合规范 §10.1 对 rootful 的 `iphoneos-arm` 要求。

启用 rootful 需要的前置改动（超出本 change 范围）：把 `control` 的 `Architecture` 改为 `iphoneos-arm`、调整 `Makefile` 的 `ARCHS`、补 rootful 目标设备的安装验证。届时只需删掉入口脚本里那段 rootful 拦截。

启用任一产物线前必须满足规范 §6.5：有明确用户场景、有独立构建与安装验证、发布文档说明适用环境、脚本中显式指定或清空对应 scheme。

### P2 逐条构建

对 `SCHEMES` 中的每条 scheme，按顺序：

1. 清空该 scheme 自己的产物目录 `packages/<scheme>/`（保留目录本身，只清内容，带短重试）；
2. 执行 `make -C <repo> clean package FINALPACKAGE=1 THEOS=<theos> THEOS_PACKAGE_DIR=packages/<scheme>/ THEOS_PACKAGE_SCHEME=<scheme>`；
3. 校验该目录中恰好有一个 `.deb`；不是 1 个就报错退出。

约束：

- `THEOS_PACKAGE_SCHEME` 必须出现在 make 命令行上，不继承也不猜测 shell 环境里的值；
- 启用 `rootful` 时显式传空值 `THEOS_PACKAGE_SCHEME=`；
- 每条构建前必须 `make clean`，不允许跨 scheme 复用中间产物；
- 不允许用 `find <package_dir> -name '*.deb' | head -n 1` 之类的方式挑最终包；
- 不允许把 `THEOS_OBJ_DIR` / `THEOS_BUILD_DIR` / `THEOS_STAGING_DIR` 改到临时目录做隔离（Theos 多架构 merge / lipo 依赖默认布局）；
- 模块缓存路径属于本地构建环境 workaround，不是发布规范的一部分，脚本中必须显式标注。

### P3 构建锁

同一项目同一时间只允许一个正式打包流程。锁目录为 `${TMPDIR:-/tmp}/<repo-name>.build.lock`，用 `mkdir` 原子创建；锁内写 pid；发现持锁进程已不存在时清理陈旧锁；进程退出时通过 trap 释放。

### P4 单个 deb 验收

对构建产出的 deb 依次校验：

1. **包头可读**：`Package` / `Version` / `Architecture` 三个字段都能取到；
2. **架构**：必须等于该 scheme 的期望值——`rootful`→`iphoneos-arm`、`rootless`→`iphoneos-arm64`、`roothide`→`iphoneos-arm64e`；
3. **宿主元数据清洁性**：解包后不得存在 `.DS_Store`、`._*`、`__MACOSX`；一旦发现就净化整包并以 `dpkg-deb -b --root-owner-group` 重打包，再解包复核；
4. **安装根**：
   - `rootless`：解包后必须存在 `var/jb`；
   - `rootful` / `roothide`：不得出现 `var` 安装根，顶层必须是 `Library` / `Applications` / `usr` 之一；`rootful` 还不得出现 `.jbroot` / `libroothide` 运行基线。

任一项不满足即报错退出，不继续后续 scheme。

### P5 产物收敛与命名

验收通过后：

1. 用 `dpkg-deb -f` 从构建产物读取 `Version`；
2. 复制到 `out/<DISPLAY_NAME>_<Version>_<scheme>_<shortArch>.deb`；
3. 对 `out/` 中的副本再执行一次 `dpkg-deb -f ... Package Version Architecture`，确认版本号与架构和本次构建一致，不一致则报错退出。

约束：

- `<Version>` 必须来自最终 deb 的 `DEBIAN/control` `Version` 字段，不能只改文件名；
- `<ShortArch>` 必须与包头 `Architecture` 对应；文件名可省略 `iphoneos-`，包头不能省略；
- 不允许把最终产物命名为 `rootful.deb` / `rootless.deb` / `roothide.deb` / `latest.deb` / `release.deb`；
- `out/` 中的文件按命名覆写，不主动删除 `out/` 下其它历史文件。

### P6 结束输出

全部 scheme 完成后打印 `out/` 中的 `.deb` 清单。

## 不变量

- 每条产物线独立构建、独立验收，不允许从旧产物反向拼装或用一条线的产物伪装另一条线。
- 脚本不做规范 §9 废弃的任何事情：不手工 lift rootless 包树成 roothide、不改 `DEBIAN/control` 架构伪装产物线、不维护静态 `Package_roothide`、不把 staging 中间目录当最终 deb 语义、不用旧 release 二进制反向拼装。
- 不改 `Makefile`、`control`、`TweakLang.plist`；产物线语义交给 Theos / roothide-theos 的官方模块处理。

## 已知限制

- 未做真机安装验证（规范 §10.3 第 6 条要求 roothide 至少一次真实设备安装验证），只做到解包验收。
- 脚本位于 `scripts/build_packages.sh`，与规范 §5「建议为 `./scripts/build_packages.sh`」一致。
- `rootful` 线当前不可用，原因见 P1；因此没有 rootful 目标设备的安装验证。
- macOS 自带 `/bin/bash` 是 3.2，在 UTF-8 locale 下会把「`$var` 紧跟一个多字节字符」里的首字节吞进变量名，使 `set -u` 报 unbound variable。脚本内所有这类位置一律写成 `${var}`；用 homebrew bash 5.x 手动跑通不会暴露这个问题，验收时必须用 `/bin/bash` 跑。
