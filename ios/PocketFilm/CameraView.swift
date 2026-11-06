import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct CameraView: View {
    @Bindable var model: CameraModel
    @State private var importing = false
    @State private var library = false
    @State private var about = false
    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            VStack(spacing: 8) {
                header
                CameraArrangement(landscape: landscape,
                    panelWidth: min(340, geometry.size.width * 0.42),
                    preview: cameraPreview(landscape: landscape)
                        .frame(maxWidth: .infinity, maxHeight: .infinity),
                    panel: VStack(spacing: 8) {
                        controls.frame(maxHeight: landscape ? .infinity : min(260, geometry.size.height * 0.32))
                        shutter
                        footer.frame(height: landscape ? 0 : nil).opacity(landscape ? 0 : 1)
                    })
            }
        }
        .onChange(of: model.apertureSelection) { _, _ in model.changeAperture() }
        .onChange(of: model.recipe) { _, _ in model.updateRecipe() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.rawImage], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { model.importRAW(url) }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $library) {
            NavigationStack {
                List(model.captures) { item in
                    Button {
                        library = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { model.show(item) }
                    } label: {
                        HStack {
                            Image(systemName: "photo").font(.title2)
                            VStack(alignment: .leading) {
                                Text(item.id.prefix(8)).font(.headline)
                                Text(FileManager.default.fileExists(atPath: item.jpeg.path) ? "RAW 与成片" : "RAW 已保留，可重新显影")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.navigationTitle("本地底片")
                    .toolbar { Button("完成") { library = false } }
            }
        }
        .sheet(isPresented: $model.showingResult, onDismiss: { model.closeResult() }) {
            if let item = model.selectedCapture { CaptureView(model: model, item: item) }
        }
        .sheet(isPresented: $about) { LicensesView() }
        .alert("提示", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
    private func cameraPreview(landscape: Bool) -> some View {
        ZStack {
            CameraPreview(session: model.captureSession, guide: model.guide, onFocus: { model.focus(at: $0) })
                .allowsHitTesting(!model.isProcessing && !model.isSwitchingLens)
            if model.isProcessing {
                ProgressView().padding(20).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }.aspectRatio(landscape ? 4.0/3.0 : 3.0/4.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18)).padding(.horizontal, 8)
    }

    private var header: some View {
        HStack {
                VStack(alignment: .leading) {
                    Text("PocketFilm").font(.title2.bold())
                    Text("光谱胶片相机").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { importing = true } label: { Image(systemName: "square.and.arrow.down") }
                    .accessibilityLabel("导入 RAW 文件")
                    .disabled(model.isProcessing || !model.engineReady)
                Button { about = true } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel("关于与开源许可")
            }.padding(.horizontal)
    }

    private var controls: some View {
        ScrollView { VStack(spacing: 10) {
                HStack {
                    Picker("胶片", selection: $model.recipe.film) {
                        ForEach(model.stocks) { Text($0.name).tag($0.id) }
                    }.labelsHidden().tint(.orange)
                    Spacer()
                    Picker("框线", selection: $model.guide) {
                        ForEach(CompositionGuide.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden()
                }
                HStack {
                    Text("胶片曝光").font(.caption)
                    Slider(value: $model.recipe.sceneEV, in: -3...3, step: 0.1).tint(.orange)
                    Text(String(format: "%+.1f", model.recipe.sceneEV))
                        .font(.caption.monospacedDigit()).frame(width: 40)
                }
                Toggle("自动色温", isOn: $model.recipe.automaticWhiteBalance).font(.caption)
                parameterSlider("显影色温", value: $model.recipe.temperature, range: 2000...12000,
                                step: 100, text: "\(Int(model.recipe.temperature)) K")
                    .disabled(model.recipe.automaticWhiteBalance)
                parameterSlider("颗粒", value: $model.recipe.grainAmount, range: 0...2,
                                step: 0.05, text: String(format: "%.2f", model.recipe.grainAmount))
                parameterSlider("光晕", value: $model.recipe.halationAmount, range: 0...4,
                                step: 0.05, text: String(format: "%.2f", model.recipe.halationAmount))
                FilmBorderControls(settings: $model.recipe.border)
                if let caps = model.capabilities {
                    HStack {
                        ForEach(caps.lenses) { lens in
                            Button(lens.name) { model.selectLens(lens.id) }
                                .buttonStyle(.bordered)
                                .tint(caps.selectedLensID == lens.id ? .orange : .gray)
                        }
                    }.disabled(model.isSwitchingLens)
                    HStack {
                        Text(String(format: "物理光圈 f/%.2f", caps.aperture)).font(.caption.monospacedDigit())
                        Spacer()
                        if !caps.apertureStops.isEmpty {
                            Picker("光圈优先", selection: $model.apertureSelection) {
                                Text("自动").tag(Double(0))
                                ForEach(caps.apertureStops, id: \.self) { stop in
                                    Text(String(format: "f/%.2f", stop)).tag(stop)
                                }
                            }.labelsHidden()
                        } else { Text("当前镜头固定光圈").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Picker("成片长边", selection: $model.recipe.maxPhotoEdge) {
                    Text("2048px").tag(2048); Text("4032px").tag(4032)
                }.pickerStyle(.segmented)
                HStack {
                    Picker("RAW 格式", selection: $model.preferProRAW) {
                        Text("ProRAW").tag(true).disabled(model.capabilities?.supportsProRAW != true)
                        Text("Bayer RAW").tag(false).disabled(model.capabilities?.supportsBayer != true)
                    }.pickerStyle(.segmented)
                }
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
            }.padding(.horizontal).disabled(model.isProcessing) }
    }

    private var shutter: some View {
        HStack {
                    Button { library = true } label: {
                        Label("底片", systemImage: "photo.stack").font(.callout)
                    }.disabled(model.isProcessing)
                    Spacer()
                    Button { model.capture() } label: {
                        Circle().fill(.white).frame(width: 62, height: 62)
                            .overlay(Circle().stroke(.black, lineWidth: 3).padding(4))
                    }.disabled(!model.canCapture).opacity(model.canCapture ? 1 : 0.35)
                        .accessibilityLabel("拍摄 RAW 并显影")
                    Spacer()
                    Text("RAW\n+ JPEG").font(.caption2.monospaced()).multilineTextAlignment(.center)
                }.padding(.vertical, 4)
    }

    private var footer: some View {
        Text("原生取景；胶片效果和片边在拍后显影时生效。框线仅辅助构图；开启片边后成片按所选胶片画幅裁剪。")
                    .font(.caption2).foregroundStyle(.secondary)
    }

    private func parameterSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                                 step: Double, text: String) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 60, alignment: .leading)
            Slider(value: value, in: range, step: step).tint(.orange)
            Text(text).font(.caption.monospacedDigit()).frame(width: 65, alignment: .trailing)
        }
    }

}

private struct CaptureView: View {
    @Bindable var model: CameraModel
    let item: CaptureItem
    @State private var saveMessage: String?
    @State private var saving = false
    private var current: Bool { CaptureStore.isCurrent(item, recipe: model.recipe) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let image = UIImage(contentsOfFile: item.jpeg.path) {
                        Image(uiImage: image).resizable().scaledToFit().id(model.imageRevision)
                    } else {
                        ContentUnavailableView("原始 RAW 已保留", systemImage: "doc", description: Text("可以分享原片，或再次尝试显影。"))
                    }
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                    FilmBorderControls(settings: $model.recipe.border)
                    if !current {
                        Text("设置已改变或尚未生成成片。可先重新显影预览；保存时会自动应用当前设置。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button("保存 RAW 与成片到相册") {
                        saving = true
                        model.saveToPhotos(item) { result in
                            saving = false
                            switch result {
                            case .success: saveMessage = "已作为两张照片保存：原始 RAW 和应用当前片边设置的胶片成片。"
                            case .failure(let error): saveMessage = error.localizedDescription
                            }
                        }
                    }.buttonStyle(.borderedProminent)
                        .disabled(saving || !model.engineReady)
                    ShareLink(items: current ? item.shareURLs : [item.source]) {
                        Label(current ? "分享原片、成片与参数" : "分享原始 RAW（成片待更新）", systemImage: "square.and.arrow.up")
                    }
                    Toggle("自动色温", isOn: $model.recipe.automaticWhiteBalance)
                    HStack {
                        Text("色温 \(Int(model.recipe.temperature)) K")
                        Slider(value: $model.recipe.temperature, in: 2000...12000, step: 100)
                            .disabled(model.recipe.automaticWhiteBalance)
                    }
                    HStack {
                        Text(String(format: "颗粒 %.2f", model.recipe.grainAmount))
                        Slider(value: $model.recipe.grainAmount, in: 0...2, step: 0.05)
                    }
                    HStack {
                        Text(String(format: "光晕 %.2f", model.recipe.halationAmount))
                        Slider(value: $model.recipe.halationAmount, in: 0...4, step: 0.05)
                    }
                    Button("应用设置并预览成片") { model.reprocess(item) }
                    Text("画面长边上限 \(model.recipe.processingEdge) 像素，开启片边后会增加外侧像素；原始 RAW 保持拍摄尺寸。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding().disabled(model.isProcessing || saving)
            }.navigationTitle("胶片成片").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { model.closeResult() }.disabled(model.isProcessing || saving) }
                .interactiveDismissDisabled(model.isProcessing || saving)
                .overlay { if model.isProcessing { ProgressView().padding().background(.regularMaterial) } }
                .alert("保存结果", isPresented: Binding(get: { saveMessage != nil }, set: { if !$0 { saveMessage = nil } })) {
                    Button("好") { saveMessage = nil }
                } message: { Text(saveMessage ?? "") }
        }
    }
}

private struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("非官方 iOS 移植") {
                    Text("PocketFilm 基于 Hanze Qiu / JamesQiu2005 的 SpektraLab，使用 Andrea Volpato 的 spektrafilm 胶片模型与数据。名称和图标不代表上游官方产品。")
                    Link("SpektraLab 源码", destination: URL(string: "https://github.com/JamesQiu2005/SpektraLab")!)
                    Link("spektrafilm 模型与数据", destination: URL(string: "https://github.com/andreavolpato/spektrafilm")!)
                }
                Section("开源许可") {
                    ForEach(["GPL-3.0.txt", "SPEKTRAFILM_LICENSE.txt", "metal-cpp-LICENSE.txt", "PRODUCT_PROFILES_NOTICE.md"], id: \.self) { name in
                        NavigationLink(name) {
                            ScrollView { Text(license(name)).font(.caption.monospaced()).padding().textSelection(.enabled) }
                                .navigationTitle(name)
                        }
                    }
                }
            }.navigationTitle("关于").toolbar { Button("完成") { dismiss() } }
        }
    }
    private func license(_ name: String) -> String {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Licenses/\(name)"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "许可文件缺失，请重新编译应用。" }
        return text
    }
}
