@{
    # ═══════════════════════════════════════════════════════════════════
    #  Windows 开发环境一键安装 —— 配置文件
    #  改完直接重跑 一键安装.bat 即可，脚本是幂等的。
    # ═══════════════════════════════════════════════════════════════════

    # 绿色版组件(JDK / Maven / MySQL / Redis)的安装根目录。
    # 建议放在非系统盘，例如 'D:\devtools'
    Root = 'C:\devtools'

    # 要安装的组件。可选：jdk maven python mysql redis idea trae git
    # 想加 Git 就把 'git' 放进来
    Components = @('jdk', 'maven', 'python', 'mysql', 'redis', 'idea', 'trae')

    # 是否使用国内镜像（阿里云 Maven / 清华 pip / GitHub 加速 / 华为云 MySQL）
    # 在海外或公司内网走代理时设为 $false
    UseMirror = $true

    # ───────────────────────────── JDK ─────────────────────────────
    Jdk = @{
        # 全部来自 Eclipse Temurin(Adoptium)，装几个就能在几个之间切
        # 可选：'8' '11' '17' '21' '25'
        Versions = @('8', '11', '17', '21')

        # 装完后默认激活哪个版本
        Default = '21'
    }

    # ──────────────────────────── Maven ────────────────────────────
    Maven = @{
        Version = '3.9.16'

        # 本地仓库位置。留空 => <Root>\maven-repo
        LocalRepository = ''

        # settings.xml 里写入阿里云中央仓库镜像
        UseAliyunMirror = $true
    }

    # ──────────────────────────── Python ───────────────────────────
    Python = @{
        # 按顺序尝试，第一个装成功就停
        WingetIds = @('Python.Python.3.13', 'Python.Python.3.12')

        # pip 镜像源
        PipIndex = 'https://pypi.tuna.tsinghua.edu.cn/simple'
        PipHost  = 'pypi.tuna.tsinghua.edu.cn'
        # 想换阿里云就改成：
        # PipIndex = 'https://mirrors.aliyun.com/pypi/simple/'
        # PipHost  = 'mirrors.aliyun.com'
    }

    # ──────────────────────────── MySQL ────────────────────────────
    MySql = @{
        # '8.4' = 当前 LTS，支持到 2032，推荐
        # '8.0' = 已于 2026-04 随 8.0.46 EOL，仅在老项目必须时才用
        # '9.7' = 新 LTS
        Series = '8.4'

        # 留空 => 自动解析该系列的最新小版本
        Version = ''

        Port = 3306

        # ⚠ 开发环境默认口令，装完请自行修改，切勿用于生产
        RootPassword = 'root1234'

        # 服务名。留空 => 按系列自动生成，如 MySQL84
        ServiceName = ''

        # 开启 mysql_native_password 插件。
        # MySQL 8.4 起该插件默认不加载，老版本 Navicat / 老 JDBC 驱动连不上，
        # 需要兼容就保持 $true
        EnableNativePassword = $true

        # 监听地址。默认只听本机。
        # 要让虚拟机 / 同事 / 手机连进来才改成 '0.0.0.0'，
        # 并且必须同时把下面的 AllowRemoteRoot 打开、RootPassword 换成强口令。
        BindAddress = '127.0.0.1'

        # 是否创建 root@'%'（可从任意主机登录的 root）。
        # ⚠ 开了就等于把数据库暴露在局域网，只在确实需要时打开
        AllowRemoteRoot = $false
    }

    # ──────────────────────────── Redis ────────────────────────────
    Redis = @{
        # 留空 => 自动取 redis-windows/redis-windows 最新 release
        Version = ''

        Port = 6379

        # 留空 = 不设密码（配置里只监听 127.0.0.1，本机开发够用）
        Password = ''

        MaxMemory = '512mb'
    }

    # ───────────────────────── IntelliJ IDEA ───────────────────────
    Idea = @{
        # 'Community' 免费 / 'Ultimate' 需授权
        Edition = 'Community'
    }

    # ───────────────────────────── Trae ────────────────────────────
    Trae = @{
        # ByteDance.Trae.CN = 国内版；ByteDance.Trae = 国际版
        WingetIds    = @('ByteDance.Trae.CN', 'ByteDance.Trae')
        DownloadPage = 'https://www.trae.com.cn/download'
    }
}
