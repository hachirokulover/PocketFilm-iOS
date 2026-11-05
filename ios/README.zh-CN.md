# PocketFilm 0.3：SpektraLab 非官方 iPhone 移植

当前为本地源码更新，未经过本轮 Xcode 编译或真机验证。目标设备为用户的 iPhone 18 Pro / iOS 27.2。

## 功能

- 原生相机取景，已移除实时胶片渲染，不承诺未经测量的实际帧率。
- 关闭 / 九宫格 / 方形 / 16:9 构图辅助线；辅助线不裁切成片。
- 动态发现后置超广角、广角、长焦；逐镜头查询 RAW 和 ProRAW 支持情况。
- iOS 27 可变光圈优先：按设备支持的档位设置物理光圈，快门与 ISO 自动；固定光圈镜头明确显示。
- RAW 先保存再显影，保留原片、JPEG 和参数 JSON，可在应用内分享或保存相册。
- 色温 2000–12000 K、颗粒 0–2、光晕 0–4 滑条，应用到下一张 RAW 或成片重新显影。
- 可选 10 种胶片片边画幅、片条 / 扩孔片夹扫描、黑白齿孔、帧号、灰雾和漏光。拍前或拍后选择，保存自动应用当前设置。
- 无片边画面长边上限 2048 / 4032px；开启片边时按胶片画幅居中裁剪，画面长边最多 2048px，再添加外侧片边。原始 RAW 保持完整尺寸。
- 使用用户提供的图标，版本 0.3.0 / build 3。

色温和胶片效果在拍后显影时生效。原生取景画面不叠加这些效果。

片边来源、使用步骤、裁剪与内存限制见 [CHANGES-0.3.zh-CN.md](CHANGES-0.3.zh-CN.md)。

## 构建

需要 Xcode 27 SDK；部署最低 iOS 17。iOS 27 专属能力都有运行时检查，固定光圈或不支持的镜头不显示可变光圈控制。

有 Mac：打开 ios/PocketFilm.xcodeproj，选择 PocketFilm scheme 和签名 Team。

没有 Mac：阅读 WINDOWS-CLOUD.zh-CN.md，使用 GitHub Actions 的 xcode-27 runner。编译完成的未签名 IPA 需经本机签名工具安装。不要把源码 ZIP 当成 IPA。

```bash
python3 ios/Tools/gen-project.py --check
python3 ios/Tools/validate-port.py
bash ios/Tools/verify-on-mac.sh
# 在 Mac 上选择存在的模拟器运行 13 项测试：
bash ios/Tools/verify-on-mac.sh 'platform=iOS Simulator,id=你的模拟器UDID'
```

图 2 的缩放、无效 RAW 与模拟器兼容修改详见 CHANGES-0.2.zh-CN.md。没有具体崩溃日志，不能确认模拟器修复覆盖朋友遇到的全部问题；测试需重新执行。

本地存储位置：Documents/Captures/<UUID>/，包含 source.dng（或导入文件的原后缀）、film.jpg、recipe.json。相册未授权也保留本地文件。

## 来源与许可

SpektraLab：Hanze Qiu / JamesQiu2005，锁定提交 02d82b56cf65f0f8e802a708612edc4e9a4790af。
https://github.com/JamesQiu2005/SpektraLab

光谱胶片模型与上游资料：Andrea Volpato / spektrafilm。
https://github.com/andreavolpato/spektrafilm

代码沿用 GPL-3.0-or-later；数据与 LUT 保留原始 CC BY-SA 4.0 署名。完整文本见 license/ 和 engine/resources_product/NOTICE.md。未修改胶片测量数据与 Metal 核心数学。新增 iOS 模拟器纹理输出路径，不改变真机输出算法。
