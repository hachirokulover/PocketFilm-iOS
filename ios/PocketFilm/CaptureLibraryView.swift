import SwiftUI
import UIKit

struct CaptureLibraryView: View {
    @Bindable var model: CameraModel
    let onSelect: (CaptureItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDeletion: [CaptureItem] = []
    @State private var confirmingDeletion = false
    @State private var deletionError: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.captures) { item in
                    Button { onSelect(item) } label: {
                        CaptureLibraryRow(item: item, revision: model.imageRevision)
                    }
                    .contextMenu {
                        Button("删除本地底片", role: .destructive) { requestDeletion([item]) }
                    }
                }
                .onDelete { offsets in requestDeletion(offsets.map { model.captures[$0] }) }
            }
            .disabled(model.isProcessing)
            .overlay {
                if model.captures.isEmpty {
                    ContentUnavailableView("暂无本地底片", systemImage: "photo.stack",
                        description: Text("拍摄或导入 RAW 后，会在这里按日期时间显示。"))
                }
                if model.isProcessing { ProgressView().padding().background(.regularMaterial) }
            }
            .navigationTitle("本地底片")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton().disabled(model.isProcessing || model.captures.isEmpty) }
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() }.disabled(model.isProcessing) }
            }
            .interactiveDismissDisabled(model.isProcessing)
            .confirmationDialog(pendingDeletion.count > 1 ? "删除所选 \(pendingDeletion.count) 张底片？" : "删除这张本地底片？",
                isPresented: $confirmingDeletion,
                titleVisibility: .visible) {
                    Button("删除本地文件", role: .destructive) {
                        let items = pendingDeletion
                        pendingDeletion = []
                        model.deleteCaptures(items) { result in
                            if case .failure(let error) = result { deletionError = error.localizedDescription }
                        }
                    }
                    Button("取消", role: .cancel) { pendingDeletion = [] }
                } message: {
                    Text("将删除本地 RAW、胶片成片、参数和缩略图，无法撤销。已保存到系统相册的照片不受影响。")
                }
            .alert("删除未完成", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
                Button("好") { deletionError = nil }
            } message: { Text(deletionError ?? "") }
        }
        .task { model.refreshLibrary() }
    }
    private func requestDeletion(_ items: [CaptureItem]) {
        pendingDeletion = items
        confirmingDeletion = !items.isEmpty
    }
}

private struct CaptureLibraryRow: View {
    let item: CaptureItem
    let revision: Int
    @State private var thumbnail: UIImage?
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else { Image(systemName: "photo").foregroundStyle(.secondary) }
            }.frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                Text(item.displayName).font(.headline.monospacedDigit()).foregroundStyle(.primary)
                Text(FileManager.default.fileExists(atPath: item.jpeg.path) ? "RAW 与成片" : "RAW 已保留，可重新显影")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: "\(item.id)-\(revision)") {
            let data = await CaptureStore.thumbnailData(for: item)
            guard !Task.isCancelled else { return }
            thumbnail = data.flatMap { UIImage(data: $0) }
        }
    }
}
