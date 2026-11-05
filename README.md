# PocketFilm iOS

基于 [SpektraLab](https://github.com/JamesQiu2005/SpektraLab) 的非官方 iPhone RAW 胶片相机移植。

这是 iOS 构建所需的源码子集。使用原 C++/Metal 光谱引擎；当前版本已编译完成，并已在真机验证。

真机验证截图如下：

<img width="120" height="262" alt="fd461a0691dba6b598251a2308a1b61a" src="https://github.com/user-attachments/assets/244821b3-9bd6-4e08-8733-c68b96775a6c" />

真机型号为iPhone18Pro，iOS版本27.2。镜头切换及可变光圈可正常调用。

## 云端编译

1. 打开仓库的 **Actions**。
2. 选择 **Build PocketFilm for iPhone**。
3. **Run workflow**，保留 `run_tests`，runner 使用 `xcode-27`（0.3 需要 iOS 27 SDK）。
4. 完成后下载本次运行的 `PocketFilm-iPhone-编号` artifact。
5. 如果设备编译成功，里面包含 `PocketFilm-unsigned.ipa`。它需要在 Windows 上用自己的账号签名后安装。


详细说明：[Windows 云编译与安装](ios/WINDOWS-CLOUD.zh-CN.md)、[移植与验证说明](ios/README.zh-CN.md)。

## 来源与许可

上游 SpektraLab：Hanze Qiu / JamesQiu2005，提交 `02d82b56cf65f0f8e802a708612edc4e9a4790af`。
胶片模型与上游数据来自 Andrea Volpato 的 [spektrafilm](https://github.com/andreavolpato/spektrafilm)。
代码沿用 GPL-3.0-or-later；胶片/相纸数据与 LUT 保留原始 CC BY-SA 4.0 声明；metal-cpp 许可见其目录。
完整许可与产品新增数据声明在 `license/`、`engine/resources_product/NOTICE.md` 及应用内“关于”。
没有使用上游名称和图标作为此应用品牌。原始上游源码可通过上述仓库和锁定提交获取。
