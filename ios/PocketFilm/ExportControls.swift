import SwiftUI

struct ExportControls: View {
    @Binding var settings: ExportSettings
    @Binding var maxPhotoEdge: Int
    let hasFilmBorder: Bool
    @State var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("文件格式", selection: $settings.format) {
                    ForEach(ExportFormat.allCases, id: \.self) { format in
                        Text(format.title).tag(format)
                    }
                }.pickerStyle(.segmented)
                Picker("色域", selection: $settings.colorSpace) {
                    ForEach(ExportColorSpace.allCases, id: \.self) { colorSpace in
                        Text(colorSpace.title).tag(colorSpace)
                    }
                }
                HStack {
                    Text("压缩质量")
                    Slider(value: $settings.quality, in: ExportSettings.qualityRange, step: 1)
                        .accessibilityLabel("压缩质量")
                    Text(settings.quality, format: .number.precision(.fractionLength(0)))
                        .monospacedDigit().frame(width: 32, alignment: .trailing)
                }
                if hasFilmBorder {
                    Text("片边模式的画面长边最多 2048 像素，外加片边。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("画面长边上限", selection: $maxPhotoEdge) {
                        Text("2048 像素").tag(2048)
                        Text("4032 像素").tag(4032)
                    }
                }
            }.padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("成片导出")
                Text("\(settings.format.title) · \(settings.colorSpace.title) · 质量 \(settings.quality, format: .number.precision(.fractionLength(0)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
