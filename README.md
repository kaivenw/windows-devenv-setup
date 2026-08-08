# Windows 一键开发环境（Java + Python）

一个 PowerShell 脚本，把 Java / Python 后端开发要用的东西一次装齐并配好：

| 组件 | 版本 | 安装方式 |
|---|---|---|
| **JDK** | 8 / 11 / 17 / 21（可自由切换） | Eclipse Temurin 绿色包 |
| **Maven** | 3.9.16 | 官方 zip + 阿里云仓库镜像 |
| **Python** | 3.13 / 3.12 | winget（回退官方安装包）+ 清华 pip 源 |
| **MySQL** | 8.4 LTS | 官方 zip → 初始化 → 注册 Windows 服务 |
| **Redis** | 8.x | redis-windows 发行版 → 注册 Windows 服务 |
| **IntelliJ IDEA** | 最新 | winget（回退 JetBrains 官方直链） |
| **Trae** | 最新 | winget `ByteDance.Trae.CN` |
| Git（可选） | 最新 | winget |

## 怎么用

1. 把整个目录拷到 Windows 机器上
2. 需要改的话，先编辑 `devenv.config.psd1`（装哪些、装到哪、密码、端口）
3. **右键 `一键安装.bat` → 以管理员身份运行**（不右键也行，脚本会自己弹 UAC）
4. 装完 **关掉当前终端，重新开一个**，环境变量才生效

第一次跑大约 20~40 分钟，主要时间在下载（MySQL 单个包就 200MB+）。

### 先看看它要干什么

```bash
powershell -ExecutionPolicy Bypass -File setup-devenv.ps1 -DryRun
```

演练模式只打印计划，不碰系统。

### 常用参数

```bash
powershell -ExecutionPolicy Bypass -File setup-devenv.ps1 -Root D:\devtools
```

```bash
powershell -ExecutionPolicy Bypass -File setup-devenv.ps1 -Only jdk,maven
```

```bash
powershell -ExecutionPolicy Bypass -File setup-devenv.ps1 -Skip mysql,redis -DefaultJdk 17
```

| 参数 | 作用 |
|---|---|
| `-Root <路径>` | 绿色版组件的安装根目录，默认 `C:\devtools` |
| `-Only a,b` | 只装这几个组件 |
| `-Skip a,b` | 跳过这几个组件 |
| `-JdkVersions 8,17` | 指定要装哪几个 JDK |
| `-DefaultJdk 17` | 装完默认激活哪个 JDK |
| `-MysqlRootPassword xxx` | MySQL root 密码 |
| `-IdeaEdition Ultimate` | 装旗舰版 IDEA |
| `-NoMirror` | 不走国内镜像，全部官方源 |
| `-Force` | 已装的也重装 |
| `-DryRun` | 演练，不改系统 |

## JDK 版本切换

这是重点。装完后直接在任意终端敲：

```bash
jdk
```

```
  已安装的 JDK：
     8     C:\devtools\java\jdk-8
     11    C:\devtools\java\jdk-11
     17    C:\devtools\java\jdk-17
   * 21    C:\devtools\java\jdk-21

  切换： jdk <版本号>      例如  jdk 17
```

```bash
jdk 8
```

切换**立即全局生效，且不用重开终端** —— 因为 `java` / `mvn` 是在你每次敲命令时才去解析
`%JAVA_HOME%\bin` 的，那时 junction 已经指向新目标了。

准确地说，切换影响的是**下一次启动的 java 进程**：

- 已经开着的终端 —— 生效，直接敲 `java -version` 就是新版本
- 正在运行的 Spring Boot 应用 —— 不变，JVM 起来后不可能换 JDK，得重启
- IDEA —— 它自己跑在自带的 JBR 上，不受影响；要让编译和运行跟着切，
  Project SDK 得指到 `C:\devtools\java\current`（而不是具体的 `jdk-21`）

### 为什么能做到

`JAVA_HOME` 不是直接指向某个 JDK，而是常年指向一个**目录联接（junction）**：

```
JAVA_HOME = C:\devtools\java\current   ← junction
                                  │
        ┌─────────────────────────┼─────────────────────────┐
        ↓             ↓           ↓                         ↓
     jdk-8        jdk-11       jdk-17                    jdk-21
                                              （current 当前指向这里）
```

`jdk 17` 做的事只有一件：把 `current` 这个 junction 重新指向 `jdk-17`。
环境变量一个字节都没改，所以不存在"要重开终端"的问题 —— 任何进程下一次解析
`%JAVA_HOME%\bin\java.exe` 时，走的就是新目标了。

安装时脚本会给 `java` 目录授予 `BUILTIN\Users` 修改权限，所以日常切换**不需要管理员权限**。
万一授权失败，`jdk` 命令会自动弹 UAC 提权，功能不受影响。

IDEA 里想跟着切，把 Project SDK 指到 `C:\devtools\java\current` 即可（而不是指到具体某个 `jdk-21`）。

## 装完的目录结构

```
C:\devtools\
├── .cache\                  下载的安装包（可以随便删）
├── bin\                     jdk.cmd / jdk.ps1（已加入 PATH）
├── java\
│   ├── jdk-8\  jdk-11\  jdk-17\  jdk-21\
│   └── current  →  junction，JAVA_HOME 指这里
├── apache-maven-3.9.16\
├── maven-repo\              Maven 本地仓库
├── mysql-8.4.x\             含 my.ini
├── mysql-data\              数据目录 + 错误日志 + 慢查询日志
├── redis\                   含 redis.conf
└── redis-data\
```

写入的环境变量（机器级）：`JAVA_HOME`、`MAVEN_HOME`、`M2_HOME`、`MYSQL_HOME`、`CLASSPATH`，
以及 PATH 里追加 `%JAVA_HOME%\bin`、`%MAVEN_HOME%\bin`、`<Root>\bin`、MySQL 和 Redis 的目录。

其他落盘位置：

- `%USERPROFILE%\.m2\settings.xml` — 阿里云镜像 + 本地仓库路径（原文件会自动备份成 `.bak-<时间戳>`）
- `%APPDATA%\pip\pip.ini` — 清华 pip 源
- `%ProgramData%\devenv-setup\logs\setup-*.log` — 完整安装日志

## 默认连接信息

| | |
|---|---|
| MySQL | `127.0.0.1:3306`，用户 `root`，密码 `root1234`，服务名 `MySQL84` |
| Redis | `127.0.0.1:6379`，无密码，服务名 `Redis` |

两个都是**开发用默认值**。MySQL 默认 `bind-address=127.0.0.1` 且**不创建** `root@'%'`，
所以局域网连不进来。确实需要外部访问时，在配置文件里同时改 `BindAddress = '0.0.0.0'`
和 `AllowRemoteRoot = $true`，并把 `RootPassword` 换成强口令。

## 卸载 / 回滚

```bash
powershell -ExecutionPolicy Bypass -File uninstall-devenv.ps1
```

默认是演练，只列出会删什么。确认后：

```bash
powershell -ExecutionPolicy Bypass -File uninstall-devenv.ps1 -Confirm2
```

- 默认保留 `mysql-data` / `redis-data` / `maven-repo`，加 `-RemoveData` 才一起删
- winget 装的 IDEA / Trae / Python / Git 默认不动，加 `-IncludeApps` 才卸

## 设计说明

**幂等。** 脚本可以反复跑。已经装好的组件会跳过，下载过的包会复用缓存。中途断网了，
修好网再跑一遍就行，不用清理现场。

**失败不中断。** 每个组件独立 try/catch，MySQL 装挂了不影响 Redis 和 IDEA。
最后的汇总表会列出哪些成功、哪些要人工跟进。

**版本号尽量不写死。** JDK 查 Adoptium assets API 拿确切文件名；MySQL 小版本查
endoflife.date；Redis 查 GitHub Releases。三者都带兜底的固定版本号，联网解析失败也能装。

**国内下载走镜像。** JDK 优先清华的 Adoptium 镜像（文件名与官方完全一致），Maven 走清华/阿里云
Apache 镜像，GitHub 链接套 ghfast.top 等加速前缀，MySQL 试华为云。每个都保留官方源作为最后一档，
`-NoMirror` 可全部关掉。

**PATH 不会被写坏。** 读注册表时用 `DoNotExpandEnvironmentNames`，避免把 `%SystemRoot%`
展开后写死回去——这是很多同类脚本的经典事故。

**配置文件都不带 BOM。** `my.ini` / `pip.ini` / `redis.conf` 带 BOM 会导致第一个段头
（`[mysqld]`、`[global]`）识别不到，脚本统一用无 BOM 的 UTF-8 写；反过来 `.ps1` 必须带
BOM，否则 PowerShell 5.1 按 ANSI 读，中文全乱码。

## 已知限制

- **Trae 没有稳定的静默安装直链。** winget 装不上时脚本会打开官网下载页，需要手动点一下。
- **Redis 不是官方 Windows 版**（官方不出）。用的是 `redis-windows/redis-windows` 的
  msys2 构建。它自带的 `RedisService.exe` 注册服务失败时，脚本会退回"开机计划任务"方案，
  效果一样是开机自启。
- **MySQL 8.0 已于 2026-04 随 8.0.46 EOL**，所以默认装 8.4 LTS。老项目确实要 8.0 的话，
  改配置 `Series = '8.0'`，脚本会照做并给出警告。
- 只支持 64 位 Windows 10 及以上。
- winget 不可用时（老系统 / 没装 App Installer），IDEA 和 Python 走官方直链兜底，Trae 只能手动。

## 排错

**中文显示成乱码** — `.ps1` 文件的 UTF-8 BOM 被编辑器去掉了。用 VSCode 另存为
"UTF-8 with BOM"，或者用 PowerShell 7（`pwsh`）跑。

**`jdk` 命令找不到** — PATH 没刷新，重开一个终端。

**MySQL 服务起不来** — 看 `<Root>\mysql-data\mysql-error.log`。最常见的是 3306 端口
已经被另一个 MySQL 占了（`netstat -ano | findstr 3306`）。

**下载一直失败** — 公司网络要代理的话，先设 `$env:HTTP_PROXY` / `$env:HTTPS_PROXY` 再跑脚本；
或者加 `-NoMirror` 试试直连官方源。

**想从头再来** — 先 `uninstall-devenv.ps1 -Confirm2 -RemoveData`，再重新装。

## 许可

MIT，见 [LICENSE](LICENSE)。
