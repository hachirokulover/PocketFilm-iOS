# PocketFilm 0.2 本地更新

本轮根据用户五项要求修改；尚未执行 Xcode 编译、模拟器测试和 iPhone 18 Pro 真机验证。没有提供新的可执行 IPA。

## 图标

使用用户上传的相机图形，仅进行 1024×1024 尺寸适配，未重新绘制。输出为不含 alpha 通道的 RGB PNG，通过 AppIcon 资源目录接入 iOS 工程。

## 取景与构图

删除视频帧到光谱引擎的实时处理路径，改用 AVCaptureVideoPreviewLayer；取景不再受到原来 480px / 12fps 胶片渲染限制。实际相机帧率和流畅度需要真机测试。

构图辅助可选择关闭、九宫格、方形和 16:9。线框依照预览层转换后的实际画面区域定位，仅辅助构图，不裁切原片和成片。

## 图 2 的三个问题

1. 缩放：在变换前确定整数目标宽高，先消除非零原点，再缩放并裁切到明确的整数矩形。测试覆盖整数、小数和负数原点，目标均为 480×360。
2. 无效 RAW：先用 ImageIO 检查实际文件类型必须符合 RAW，而非只看文件后缀；检查 RAW 解码尺寸与输出范围。无效输入在创建渲染引擎之前报错，原文件保留。增加 JPEG 改名为 DNG 的拒绝测试。
3. 模拟器 Metal 崩溃：新增 TARGET_OS_SIMULATOR 分支，使用独立 2D 纹理复制输出，避免缓冲区绑定线性纹理路径；通过关联对象保留源 MTLBuffer，维持 C ABI 的 rgba16 指针生命周期。真机继续使用原来输出路径。**没有朋友的崩溃堆栈，因此这是针对已知模拟器限制的兼容性修改，尚不能确认覆盖其具体崩溃原因。**

## 滑条

- 色温：自动 / 手动，手动范围 2000–12000 K，送入 RAW 解码器。
- 颗粒：0–2，直接使用引擎 grain_amount；0 关闭。
- 光晕：0–4，直接使用引擎 halation_amount；0 关闭。

在拍摄页设置后应用于下一张 RAW；在成片页调整后点击重新显影。为保持原生取景流畅，这些胶片与显影调整不实时叠加在相机画面上。

## iPhone 18 Pro 光圈与镜头

使用 iOS 27 公共接口，不写死某型号的硬件参数。发现后置超广角、广角和长焦物理摄像头，只显示实际存在的镜头。

每次换镜头重新配置相机，查询 RAW / ProRAW、照片尺寸、可用光圈档位。变量光圈支持时显示自动与设备推荐且支持的 f 值，使用光圈优先接口固定光圈、让快门和 ISO 自动曝光；不支持的镜头显示固定光圈。显示镜头当前实际光圈值。

接口参考：
- https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/recommendedlensaperturestops
- https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom(lensaperture:duration:iso:completionhandler:)
- https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/supportsexposuremodecustom(lensaperture:duration:iso:)

## 构建与升级

此版本引用 iOS 27 的 API，需要 Xcode 27 SDK 编译；运行时保留 iOS 17 最低系统检查。云工作流默认选择 xcode-27。

将上传包里的文件覆盖到原 GitHub 仓库相同位置，提交并 Push 后重新触发 Build PocketFilm for iPhone。保留包名 org.pocketfilm.camera，应用版本升为 0.2.0 / build 2。后续使用同一个签名账号和相同应用标识覆盖安装，避免先删除旧应用导致本地底片丢失。

AltStore 元数据清理打包修复保留：不会再产生 Payload/._PocketFilm.app。
