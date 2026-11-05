# 没有 Mac：GitHub 云编译 + Windows 签名安装

适用情况：你有 GitHub 账号，没有 Mac，也没有付费 Apple Developer Program 会员。

整个流程分为两步：GitHub 的 macOS 机器编译源码，生成 **未签名 IPA**；你在 Windows 上用自己的 Apple 账号签名并安装。云端编译不需要你的 Apple 密码、验证码或签名证书。

**当前状态：工作流和打包脚本已加入源码并进行本地结构/语法检查，但尚未在你的 GitHub 账号下执行。没有生成实际 IPA，也没有完成真机验证。**

## 1. 把移植版放到自己的 GitHub 仓库

建议新建一个用于这个移植版的仓库，避免改动你现有的其他项目。

下载更新后的源码 ZIP，解压后，将 `PocketFilm-iOS` 文件夹内的内容放到仓库根目录。根目录应直接包含 `engine/`、`ios/`、`.github/`、`license/`，不能在外面再多套一层 `PocketFilm-iOS/`。

你可以用 Windows 版 GitHub Desktop：File → Add Local Repository；若文件夹不是 Git 仓库，按提示创建，再用 Publish repository 发布到自己的账号。公开或私有由你选择；请保留原始代码和资源的许可、署名。

注意 Windows 文件管理器可能没有显示 `.github` 文件夹；它也必须上传。

## 2. 从浏览器触发云端编译

1. 打开自己的仓库，进入 **Actions**。
2. 选择 **Build PocketFilm for iPhone**。
3. 点击 **Run workflow**，默认勾选 `run_tests`，runner 使用 `xcode-27`（0.3 需要 iOS 27 SDK）。
4. 若默认环境的 Xcode/Metal 编译器过旧，可选择 `xcode-27` runner 重试；这是 GitHub 当前文档列出的预览环境，是否可用以账号界面为准。
5. 完成后，在这次运行页面的 **Artifacts** 下载 `PocketFilm-iPhone-运行编号`。
6. 解压其中的 `PocketFilm-unsigned.ipa`。

云构建会先验证项目，再编译设备版并打包 IPA，然后在模拟器执行八项测试。构建和测试日志也在 artifact 中。为方便诊断，即使测试失败也会上传已生成的文件；**有 IPA 不等于测试通过**。

若失败，先查看红色步骤的 `device-build.log` 或 `simulator-tests.log`，修复对应编译/测试错误再安装。这个移植版还没经过首次 Xcode 编译，第一次运行有可能需要调整源码；请把运行链接或编译错误发回来继续修复。

GitHub 文档目前说明：公开仓库的标准托管 runner 免费；私有仓库消耗账号的可用分钟数，超出部分可能收费。以你的账号计费页面为准。

## 3. 在 Windows 上签名并安装

可以使用 Sideloadly：<https://sideloadly.io/>。

官网目前列出 Windows、免费 Apple 账号以及 iOS 27+ 支持；这不是本应用已经通过 iPhone 18 Pro / iOS 27.2 实测的证明。

1. 从官网取得 Windows 版本，按该工具提示准备 Apple 设备驱动和依赖。官网对 Windows 的 iTunes/iCloud 版本有专门要求，按其当前指引操作。
2. 用 USB 连接 iPhone，解锁并选择信任电脑。
3. 在 Sideloadly 中选中设备，拖入 `PocketFilm-unsigned.ipa`。
4. 在本机工具里使用你自己的 Apple 账号完成签名；遇到双重认证按工具提示处理。
5. 根据 iOS 提示开启开发者模式，并在需要时信任开发者。
6. 启动 PocketFilm，允许相机权限；先用 2048px 输出测试，再试 4032px。

Apple 密码和验证码只在你决定使用的本机签名流程中处理，**不要发到聊天里，不要写进 GitHub 仓库、Actions 参数或日志**。Sideloadly 是第三方软件，使用自己的账号登录前请自行查看其官方说明与隐私政策。

免费个人签名通常 7 天到期，需重新签名/刷新；Sideloadly 提供自动刷新功能。Apple 对 Personal Team 还有同时安装应用数量等限制。具体签名或认证失败，应以工具实际错误为准，不能通过云端编译绕过签名要求。

## 4. 首次真机测试

- 查看取景是否正常，胶片切换有无报错。
- 用 Bayer RAW 与 ProRAW 分别拍摄；不支持的格式会禁用或拒绝。
- 拍摄明显的上下标记，核对取景、成片和相册方向。
- 检查应用内底片是否保留 DNG；拒绝相册权限时文件仍应存在。
- 连续取景十分钟，检查发热、内存和实际帧率。
- 将首次崩溃或相机错误日志发回来；不要附带账号密码、验证码或私人照片。

官方参考：

- GitHub runner 与计费范围：<https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job>
- Apple Personal Team 限制：<https://developer.apple.com/help/account/basics/about-your-developer-account/>
- Sideloadly 功能、Windows 依赖与刷新方式：<https://sideloadly.io/>
