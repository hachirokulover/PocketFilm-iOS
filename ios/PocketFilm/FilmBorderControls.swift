import SwiftUI

struct FilmBorderControls: View {
    @Binding var settings: FilmBorderSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("添加胶片片边", isOn: $settings.enabled)
            if settings.enabled {
                Picker("片边类型", selection: $settings.format) {
                    ForEach(FilmBorderFormat.allCases) { Text($0.title).tag($0) }
                }
                Picker("扫描样式", selection: $settings.scan) {
                    ForEach(FilmBorderScan.allCases) { Text($0.title).tag($0) }
                }
                if settings.format.perforated && settings.scan == .strip {
                    Picker("齿孔", selection: $settings.holes) {
                        ForEach(FilmBorderHoles.allCases) { Text($0.title).tag($0) }
                    }
                }
                Stepper(settings.frameNumber == 0 ? "帧号：自动" : "帧号：\(settings.frameNumber)",
                        value: $settings.frameNumber, in: 0...99)
                HStack {
                    Text("边缘灰雾").font(.caption)
                    Slider(value: $settings.fog, in: 0...4, step: 0.05)
                    Text(String(format: "%.2f", settings.fog)).font(.caption.monospacedDigit())
                }
                HStack {
                    Text("片轴漏光").font(.caption)
                    Slider(value: $settings.leaks, in: 0...4, step: 0.05)
                    Text(String(format: "%.2f", settings.leaks)).font(.caption.monospacedDigit())
                }
                Text("成片按所选胶片画幅居中裁剪，再生成片边。120 片边没有齿孔。开启后画面长边最多 2048px，外加片边；原始 RAW 完整保留。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
