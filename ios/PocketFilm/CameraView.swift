import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

private let cameraAccent = Color(red: 0.47, green: 0.84, blue: 0.74)
private let cameraSurface = Color(red: 0.085, green: 0.11, blue: 0.12)

private enum CameraPanel: String, Identifiable {
    case lens = "镜头", film = "胶片", raw = "RAW 格式", aperture = "光圈"
    case develop = "显影", framing = "构图与片边", output = "成片导出"
    var id: Self { self }
}

struct CameraView: View {
    @Bindable var model: CameraModel
    @State private var importing = false
    @State private var choosingPhoto = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var library = false
    @State private var about = false
    @State private var panel: CameraPanel?
    @State private var pendingCapture: CaptureItem?

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            VStack(spacing: 8) {
                header
                parameterBar
                CameraArrangement(landscape: landscape, panelWidth: 72,
                    preview: viewfinder,
                    panel: capturePanel(landscape: landscape))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .background(Color(red: 0.035, green: 0.053, blue: 0.061).ignoresSafeArea())
        .tint(cameraAccent)
        .onChange(of: model.apertureSelection) { _, _ in model.changeAperture() }
        .photosPicker(isPresented: $choosingPhoto, selection: $selectedPhoto, matching: .images,
            preferredItemEncoding: .current)
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            selectedPhoto = nil
            Task { await model.importPhoto(item) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.rawImage], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { model.importRAW(url) }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $panel) { panel in
            CameraSettingsPanel(model: model, panel: panel)
                .tint(cameraAccent)
        }
        .sheet(isPresented: $library, onDismiss: {
            if let item = pendingCapture {
                pendingCapture = nil
                model.show(item)
            }
        }) {
            CaptureLibraryView(model: model) { item in
                pendingCapture = item
                library = false
            }
        }
        .sheet(isPresented: $model.showingResult, onDismiss: { model.closeResult() }) {
            if let item = model.selectedCapture { CaptureView(model: model, item: item) }
        }
        .sheet(isPresented: $about) { LicensesView() }
        .alert("提示", isPresented: Binding(
            get: { !model.showingResult && model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.aperture")
                .foregroundStyle(cameraAccent)
                .accessibilityHidden(true)
            Text("PocketFilm").font(.headline)
            Spacer(minLength: 0)
            Menu {
                Button { choosingPhoto = true } label: { Label("从相册选择", systemImage: "photo.on.rectangle") }
                Button { importing = true } label: { Label("从文件导入 RAW", systemImage: "doc") }
            } label: {
                Image(systemName: "square.and.arrow.down").frame(width: 44, height: 44)
            }
            .accessibilityLabel("导入照片")
            .disabled(model.isProcessing || !model.engineReady)
            Button { about = true } label: {
                Image(systemName: "info.circle").frame(width: 44, height: 44)
            }
            .accessibilityLabel("关于与开源许可")
        }
        .buttonStyle(.plain)
    }

    private var parameterBar: some View {
        HStack(spacing: 6) {
            parameter(.lens, value: model.capabilities?.lenses.first {
                $0.id == model.capabilities?.selectedLensID
            }?.name ?? "—")
            parameter(.raw, value: model.preferProRAW ? "ProRAW" : "Bayer")
            parameter(.aperture, value: model.capabilities.map {
                String(format: "ƒ/%.2f", $0.aperture)
            } ?? "—")
            parameter(.film, value: model.selectedFilmName)
        }
        .disabled(model.isProcessing || model.isSwitchingLens)
    }

    private func parameter(_ target: CameraPanel, value: String) -> some View {
        Button { panel = target } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(target.rawValue).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(cameraAccent).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 8)
            .background(cameraSurface, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(target.rawValue)
        .accessibilityValue(value)
    }

    private var viewfinder: some View {
        ZStack {
            CameraPreview(session: model.captureSession, guide: model.guide, onFocus: { model.focus(at: $0) })
                .allowsHitTesting(!model.isProcessing && !model.isSwitchingLens)
            if model.isProcessing {
                ProgressView().tint(cameraAccent).padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.13))
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) {
            Text(model.status)
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.black.opacity(0.74), in: RoundedRectangle(cornerRadius: 5))
                .padding(7)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func capturePanel(landscape: Bool) -> some View {
        if landscape {
            ScrollView(.vertical) { captureControls(landscape: true).frame(maxWidth: .infinity) }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
        } else {
            captureControls(landscape: false)
        }
    }

    private func captureControls(landscape: Bool) -> some View {
        let layout = landscape ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            action("底片", icon: "photo.stack") { library = true }
                .disabled(model.isProcessing)
            action("显影", icon: "slider.horizontal.3") { panel = .develop }
                .disabled(model.isProcessing)
            Button { model.capture() } label: {
                Circle().strokeBorder(cameraAccent, lineWidth: 2)
                    .overlay { Circle().fill(cameraAccent).padding(5) }
                    .frame(width: 52, height: 52)
                    .padding(2)
            }
            .accessibilityLabel("拍摄 RAW 并显影")
            .disabled(!model.canCapture)
            .opacity(model.canCapture ? 1 : 0.4)
            action("构图", icon: "viewfinder") { panel = .framing }
                .disabled(model.isProcessing)
            action(model.recipe.export.format.title, icon: "arrow.up.right.square") { panel = .output }
                .accessibilityLabel("成片导出")
                .disabled(model.isProcessing)
        }
        .frame(maxWidth: landscape ? nil : .infinity)
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }

    private func action(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 17, weight: .medium))
                Text(title).font(.caption2.monospacedDigit())
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
    }
}

private struct CameraSettingsPanel: View {
    @Bindable var model: CameraModel
    let panel: CameraPanel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch panel {
                    case .lens:
                        if let caps = model.capabilities {
                            ForEach(caps.lenses) { lens in
                                Button {
                                    if lens.id != caps.selectedLensID { model.selectLens(lens.id) }
                                    dismiss()
                                } label: {
                                    HStack {
                                        Text(lens.name)
                                        Spacer()
                                        if lens.id == caps.selectedLensID { Image(systemName: "checkmark") }
                                    }.frame(minHeight: 32)
                                }.buttonStyle(.bordered)
                                .disabled(model.isSwitchingLens)
                            }
                        } else {
                            Text("等待相机就绪").foregroundStyle(.secondary)
                        }
                    case .film:
                        if !model.fotufilmStocks.isEmpty {
                            DisclosureGroup("Fotufilm · 调色配方") {
                                ForEach(model.fotufilmStocks) { stock in
                                    filmButton(stock.name, id: stock.recipeID)
                                }
                            }
                        }
                        Text("Spektrafilm").font(.headline)
                        ForEach(model.stocks) { stock in
                            filmButton(stock.name, id: stock.id)
                        }
                    case .raw:
                        Picker("RAW 格式", selection: $model.preferProRAW) {
                            Text("ProRAW").tag(true).disabled(model.capabilities?.supportsProRAW != true)
                            Text("Bayer RAW").tag(false).disabled(model.capabilities?.supportsBayer != true)
                        }.pickerStyle(.segmented)
                    case .aperture:
                        if let caps = model.capabilities, !caps.apertureStops.isEmpty {
                            Picker("光圈优先", selection: $model.apertureSelection) {
                                Text("自动").tag(Double(0))
                                ForEach(caps.apertureStops, id: \.self) { stop in
                                    Text(String(format: "ƒ/%.2f", stop)).tag(stop)
                                }
                            }.pickerStyle(.inline)
                        } else {
                            Text(model.capabilities == nil ? "等待相机就绪" : "当前镜头固定光圈")
                                .foregroundStyle(.secondary)
                        }
                    case .develop:
                        adjustment("胶片曝光", value: $model.recipe.sceneEV, range: -3...3, step: 0.1,
                            text: String(format: "%+.1f EV", model.recipe.sceneEV))
                        Toggle("自动色温", isOn: $model.recipe.automaticWhiteBalance)
                        adjustment("色温", value: $model.recipe.temperature, range: 2000...12000, step: 100,
                            text: "\(Int(model.recipe.temperature)) K")
                            .disabled(model.recipe.automaticWhiteBalance)
                        if !model.recipe.usesFotufilm {
                            adjustment("颗粒", value: $model.recipe.grainAmount, range: 0...2, step: 0.05,
                                text: String(format: "%.2f", model.recipe.grainAmount))
                            adjustment("光晕", value: $model.recipe.halationAmount, range: 0...4, step: 0.05,
                                text: String(format: "%.2f", model.recipe.halationAmount))
                        } else {
                            FotufilmControlsNote()
                        }
                    case .framing:
                        Picker("取景框线", selection: $model.guide) {
                            ForEach(CompositionGuide.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented)
                        if model.recipe.usesFotufilm {
                            FotufilmControlsNote()
                        } else {
                            FilmBorderControls(settings: $model.recipe.border)
                        }
                    case .output:
                        ExportControls(settings: $model.recipe.export, maxPhotoEdge: $model.recipe.maxPhotoEdge,
                            hasFilmBorder: model.recipe.hasFilmBorder, expanded: true)
                    }
                }
                .frame(maxWidth: 550, alignment: .leading)
                .padding()
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(panel.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
        }
    }

    private func filmButton(_ name: String, id: String) -> some View {
        Button {
            model.selectFilm(id)
            dismiss()
        } label: {
            HStack {
                Text(name)
                Spacer()
                if id == model.recipe.film { Image(systemName: "checkmark") }
            }.frame(minHeight: 32)
        }.buttonStyle(.bordered)
    }

    private func adjustment(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                            step: Double, text: String) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(text).monospacedDigit().foregroundStyle(cameraAccent)
            }
            Slider(value: value, in: range, step: step).accessibilityLabel(title)
        }
    }
}

private struct FilmChoicePicker: View {
    @Bindable var model: CameraModel

    var body: some View {
        Picker("胶片", selection: Binding(get: { model.recipe.film }, set: { model.selectFilm($0) })) {
            Section("Spektrafilm") {
                ForEach(model.stocks) { stock in Text(stock.name).tag(stock.id) }
            }
            if !model.fotufilmStocks.isEmpty {
                Section("Fotufilm · 调色配方") {
                    ForEach(model.fotufilmStocks) { stock in Text(stock.name).tag(stock.recipeID) }
                }
            }
        }
        .pickerStyle(.menu)
    }
}

private struct FotufilmControlsNote: View {
    var body: some View {
        Text("Fotufilm 配方应用颜色与反差。颗粒、光晕和片边在 Spektrafilm 预设中可用。")
            .font(.caption)
            .foregroundStyle(.secondary)
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
                    if let image = UIImage(contentsOfFile: item.developed.path) {
                        Image(uiImage: image).resizable().scaledToFit().id(model.imageRevision)
                    } else {
                        ContentUnavailableView("原片已保留", systemImage: "doc", description: Text("可以分享原片，或再次尝试显影。"))
                    }
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                    FilmChoicePicker(model: model)
                    GroupBox {
                        ExportControls(settings: $model.recipe.export, maxPhotoEdge: $model.recipe.maxPhotoEdge,
                            hasFilmBorder: model.recipe.hasFilmBorder, expanded: true)
                    }
                    if model.recipe.usesFotufilm {
                        FotufilmControlsNote()
                    } else {
                        GroupBox("片边") {
                            FilmBorderControls(settings: $model.recipe.border)
                        }
                    }
                    if !current {
                        Text("设置已改变或尚未生成成片。可先重新显影预览；保存时会自动应用当前设置。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button(item.isRAW ? "保存 RAW 与成片到相册" : "保存成片到相册") {
                        saving = true
                        model.saveToPhotos(item) { result in
                            saving = false
                            switch result {
                            case .success:
                                saveMessage = item.isRAW
                                    ? "原始 RAW 和 \(model.recipe.export.format.title) 成片已分别保存到相册。"
                                    : "\(model.recipe.export.format.title) 成片已保存到相册。"
                            case .failure(let error):
                                model.errorMessage = nil
                                saveMessage = error.localizedDescription
                            }
                        }
                    }.buttonStyle(.borderedProminent)
                        .disabled(saving || !model.engineReady)
                    ShareLink(items: current ? item.shareURLs : [item.source]) {
                        Label(current ? "分享原片、成片与参数" : "分享原片（成片待更新）", systemImage: "square.and.arrow.up")
                    }
                    Toggle("自动色温", isOn: $model.recipe.automaticWhiteBalance)
                    HStack {
                        Text("色温 \(Int(model.recipe.temperature)) K")
                        Slider(value: $model.recipe.temperature, in: 2000...12000, step: 100)
                            .disabled(model.recipe.automaticWhiteBalance)
                    }
                    if !model.recipe.usesFotufilm {
                        HStack {
                            Text(String(format: "颗粒 %.2f", model.recipe.grainAmount))
                            Slider(value: $model.recipe.grainAmount, in: 0...2, step: 0.05)
                        }
                        HStack {
                            Text(String(format: "光晕 %.2f", model.recipe.halationAmount))
                            Slider(value: $model.recipe.halationAmount, in: 0...4, step: 0.05)
                        }
                    }
                    Button("应用设置并预览成片") { model.reprocess(item) }
                    Text(model.recipe.hasFilmBorder
                        ? "画面长边上限 \(model.recipe.processingEdge) 像素，外加片边。"
                        : "画面长边上限 \(model.recipe.processingEdge) 像素。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding().disabled(model.isProcessing || saving)
            }.navigationTitle("胶片成片").navigationBarTitleDisplayMode(.inline)
                .tint(cameraAccent)
                .toolbar { Button("完成") { model.closeResult() }.disabled(model.isProcessing || saving) }
                .interactiveDismissDisabled(model.isProcessing || saving)
                .overlay { if model.isProcessing { ProgressView().padding().background(.regularMaterial) } }
                .alert("成片", isPresented: Binding(
                    get: { saveMessage != nil || model.errorMessage != nil },
                    set: { if !$0 { saveMessage = nil; model.errorMessage = nil } }
                )) {
                    Button("好") { saveMessage = nil; model.errorMessage = nil }
                } message: { Text(saveMessage ?? model.errorMessage ?? "") }
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
                Section("Fotufilm 调色配方") {
                    Text("配方来源为 Fotufilm（© 2026 MUAStudio Inc.），已转换为 3D 调色表。原配方与调色表按 CC BY-SA 4.0 提供。")
                    Link("Fotufilm", destination: URL(string: "https://fotufilm.com")!)
                }
                Section("开源许可") {
                    ForEach(["GPL-3.0.txt", "SPEKTRAFILM_LICENSE.txt", "metal-cpp-LICENSE.txt", "PRODUCT_PROFILES_NOTICE.md", "Rust-dependencies.txt", "Fotufilm-FILM-PROFILES.txt", "Fotufilm-CC-BY-SA-4.0.txt"], id: \.self) { name in
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
