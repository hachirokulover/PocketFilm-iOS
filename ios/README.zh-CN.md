# PocketFilm 0.3：SpektraLab 非官方 iPhone 移植

当前为本地源码更新，未经过本轮 Xcode 编译或真机验证。目标设备为用户的 iPhone 18 Pro / iOS 27.2。

## 功能

- 相机主屏以取景器为中心。镜头、RAW 格式、物理光圈和胶片配置可从顶部参数栏打开。底片库、快门、显影、构图和成片导出集中在操作栏，横屏时操作栏移至右侧。

- 支持竖屏和左右横屏，拍照方向跟随设备；点击取景画面选择对焦点。修改说明与真机验收见 [横竖屏与点击对焦](CHANGES-orientation-focus.zh-CN.md)。

- 原生相机取景，已移除实时胶片渲染，不承诺未经测量的实际帧率。
- 关闭 / 九宫格 / 方形 / 16:9 构图辅助线；辅助线不裁切成片。
- 动态发现后置超广角、广角、长焦；逐镜头查询 RAW 和 ProRAW 支持情况。
- iOS 27 可变光圈优先：按设备支持的档位设置物理光圈，快门与 ISO 自动；固定光圈镜头明确显示。
- RAW 先保存再显影，保留原片、JPG 或 HEIF 成片和参数 JSON，可在应用内分享或保存相册。
- 相机页右上角「导入照片」可从系统相册选择普通照片或 RAW，每次处理一张。普通照片沿用现有白平衡，可手动调整色温。相册提供的 RAW 原片走 RAW 解码；未能提供 RAW 时，可从「文件」导入原始 RAW。
- 相册导入只读取选中的图片。普通照片的输入文件保存在本地底片库，保存回系统相册时只新增显影成片。
- 拍摄页和成片页的“成片导出”可选择 JPG / HEIF、sRGB / Adobe RGB (1998) / Display P3 / DCI-P3，以及 1–100 的压缩质量。新设置默认 JPG、sRGB、质量 100。打开旧底片会读取该张成片的导出设置，旧版参数对应 JPG、sRGB、质量 95。
- 色温 2000–12000 K、颗粒 0–2、光晕 0–4 滑条，应用到下一张 RAW 或成片重新显影。
- 可选 10 种胶片片边画幅、片条 / 扩孔片夹扫描、黑白齿孔、帧号、灰雾和漏光。拍前或拍后选择，保存自动应用当前设置。
- 无片边画面长边上限 2048 / 4032px；开启片边时按胶片画幅居中裁剪，画面长边最多 2048px，再添加外侧片边。原始 RAW 保持完整尺寸。
- 使用用户提供的图标，版本 0.3.0 / build 3。

色温和胶片效果在拍后显影时生效。原生取景画面不叠加这些效果。

片边来源、使用步骤、裁剪与内存限制见 [CHANGES-0.3.zh-CN.md](CHANGES-0.3.zh-CN.md)。

## 构建

显影参数转换、缩放规则、压缩质量和显影会话由 Rust 核心负责。SwiftUI 提供界面，Swift 调用 AVFoundation、Core Image 和 Photos，原有 C++／Metal 光谱引擎负责渲染。

本机 Xcode 构建需要通过 rustup 安装最新的 Rust 稳定版。

```bash
rustup target add --toolchain stable aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
cargo +stable test --locked --manifest-path ios/RustCore/Cargo.toml --target-dir ios/build/rust-host
```

GitHub Actions 会准备 Rust 目标并运行本机测试。Xcode 按当前平台和架构构建 Rust 静态库，并链接到应用。

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

本地底片按日期时间命名并显示缩略图，支持左滑、编辑或长按删除。Documents/Captures 下的每张底片包含带日期时间的输入文件、胶片 JPG 或 HEIF、recipe.json、capture.json 与 thumbnail.jpg。同一时间重复保存自动增加序号，旧版 UUID 目录继续兼容。相册未授权时仍可从本地分享成片。详情见 [底片库说明](CHANGES-library.zh-CN.md)。

## 来源与许可

SpektraLab：Hanze Qiu / JamesQiu2005，锁定提交 02d82b56cf65f0f8e802a708612edc4e9a4790af。
https://github.com/JamesQiu2005/SpektraLab

光谱胶片模型与上游资料：Andrea Volpato / spektrafilm。
https://github.com/andreavolpato/spektrafilm

代码沿用 GPL-3.0-or-later；数据与 LUT 保留原始 CC BY-SA 4.0 署名。完整文本见 license/ 和 engine/resources_product/NOTICE.md。未修改胶片测量数据与 Metal 核心数学。新增 iOS 模拟器纹理输出路径，不改变真机输出算法。
