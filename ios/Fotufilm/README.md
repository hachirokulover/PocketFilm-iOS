# Fotufilm 配方移植

PocketFilm 的「胶片」菜单含两组。**Spektrafilm** 调用原有光谱引擎和 20 种预设。**Fotufilm · 调色配方** 提供 47 种从 Fotufilm 渲染得到的颜色与反差配方。同名胶片在两组中各用自己的配方，例如 Portra 400。

拍照或导入前可先选胶片。打开成片或本地底片后，也可以换胶片，再点「应用设置并预览成片」。Fotufilm 配方支持现有的显影曝光、色温、JPG／HEIF、色域、尺寸和压缩质量设置。颗粒、光晕与胶片片边仍在 Spektrafilm 预设中使用。

## 实现和适用范围

Fotufilm 把胶片的感光响应、显影密度、染料透射和输出介质建模。它还支持会随画面位置变化的光晕、颗粒、扩散，以及依赖整张图像的自动影调。PocketFilm 从上游公布的 Legacy WebAssembly 渲染器中采样固定显影条件下的逐像素颜色和反差。为生成可移植的查找表，烘焙关闭了邻域效果并固定了影调。这个实现适合在手机上离线调色，画面效果会与启用空间和自动调整的 Fotufilm 桌面或网页版不同。红外类配方处理的是 iPhone 已拍到的可见光图像。

每个查找表为 33³ 个 RGBA Float16 采样点。输入为线性 Rec.2020，查找轴在 0–8 范围按 `log2(1 + 32x) / log2(257)` 采样。应用先应用显影曝光，再在 Metal 上做三线性插值，输出线性 Display P3，最后交给原有导出流程转换为用户选定色域。原片始终保存在本地底片库。查找表已随源码提供，构建和拍摄期间均无需下载 Fotufilm 引擎或数据。

## 来源和再生成

- 来源为 Fotufilm（© 2026 MUAStudio Inc.）发布的浏览器引擎，运行时资产版本 `6426fb2e46a35bd1e553`。每个输入包和转换后的查找表均在 [catalogue.json](Assets/catalogue.json) 记录 SHA-256。 [Fotufilm](https://fotufilm.com) · [项目源码](https://github.com/DhaliwalX/fotufilm-engine)
- 原配方及转换的查找表按 **CC BY-SA 4.0** 提供。移植改动包括关闭空间效果、固定场景级自动处理、对广色域颜色和反差采样、量化为 Float16。Fotufilm 的程序和界面资源仅用于离线烘焙，PocketFilm 的安装包包含生成的查找表及其许可。 [上游许可说明](https://github.com/DhaliwalX/fotufilm-engine/blob/87a3f46af093a9e6bf76acf21aca83d3b9e2c600/LICENSING.md) · [原配方归属](../../license/Fotufilm-FILM-PROFILES.txt) · [完整许可](../../license/Fotufilm-CC-BY-SA-4.0.txt)

再生成需要 Node.js 24，以及上述版本的浏览器文件。在临时输入目录中，把 `engine/bridge.js`、`engine/fotufilm.mjs`、`engine/fotufilm.wasm`、`engine/packs/index.json` 分别保存为 `bridge.js`、`fotufilm.mjs`、`fotufilm.wasm`、`index.json`。把 `engine/assets/rolldown-runtime-hePW80VL.js` 和 `engine/packs/<id>.pack` 分别放到该目录的 `assets/` 与 `packs/` 下。文件路径相对于 [Fotufilm 浏览器演示](https://fotufilm.com/demo/)，资产请求使用查询参数 `v=6426fb2e46a35bd1e553`。脚本启动时核对运行时和目录索引的哈希。普通应用构建直接使用仓库里的成品。

```sh
node ios/Tools/bake-fotufilm.mjs <输入目录> <输出目录>
```

脚本对每份配方渲染两次，第二次打乱输入颜色的相邻关系及位置，逐一检查输出颜色是否随位置或邻域变化。将生成结果与仓库目录中的 SHA-256 对照，可复核使用的素材和导出的数据。
