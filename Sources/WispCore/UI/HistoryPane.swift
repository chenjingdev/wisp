import SwiftUI

extension DictationRecord: Identifiable {}

struct HistoryPane: View {
    @ObservedObject var container: AppContainer
    @State private var query = ""
    @State private var rows: [DictationRecord] = []
    @State private var mayHaveMore = false
    @State private var selectedId: String?
    @State private var confirmDelete = false

    private static let pageSize = 100
    private var selected: DictationRecord? { rows.first { $0.id == selectedId } }

    var body: some View {
        VStack(spacing: 0) {
            TextField("검색 (원문/결과)", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(10)

            List(rows, selection: $selectedId) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.llmOutput ?? row.transcript ?? "(전사 없음)")
                            .lineLimit(1)
                        Text("\(row.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(modeName(row.modeId)) · \(String(format: "%.1f초", row.recordSeconds))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !row.llmSucceeded {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow)
                    }
                }
                .tag(row.id)
            }

            if mayHaveMore {
                Button("더 보기") { loadMore() }.padding(6)
            }

            if let record = selected {
                Divider()
                detail(record)
            }
        }
        .navigationTitle("히스토리")
        .task(id: query) {
            // 첫 진입(빈 쿼리)은 즉시, 타이핑 중에만 0.3초 디바운스.
            // (onAppear+task 이중 호출로 같은 조회가 두 번 돌던 것을 한 번으로)
            if !query.isEmpty {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
            }
            reload()
        }
        .confirmationDialog("이 기록을 삭제할까요? 녹음 파일도 함께 삭제됩니다.",
                            isPresented: $confirmDelete) {
            Button("삭제", role: .destructive) { deleteSelected() }
        }
    }

    @ViewBuilder
    private func detail(_ record: DictationRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button("삭제", role: .destructive) { confirmDelete = true }
            }
            row(title: "STT 원문", text: record.transcript)
            if record.llmOutput != nil {
                row(title: "LLM 결과", text: record.llmOutput)
            }
        }
        .padding(10)
        .frame(maxHeight: 180)
    }

    @ViewBuilder
    private func row(title: String, text: String?) -> some View {
        HStack(alignment: .top) {
            Text(title).font(.caption).foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(text ?? "—").textSelection(.enabled).lineLimit(3)
            Spacer()
            Button("복사") {
                guard let text else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .disabled(text == nil)
        }
    }

    private func modeName(_ id: String) -> String {
        container.modes.first { $0.id == id }?.name ?? id
    }

    /// container.history가 옵셔널이라 `try? history?.…`는 이중 옵셔널이 된다 —
    /// guard로 풀어낸 단일 조회 헬퍼를 쓴다.
    private func fetch(before: Date?) -> [DictationRecord] {
        guard let history = container.history else { return [] }
        let q = query.isEmpty ? nil : query
        return (try? history.fetchPage(query: q, before: before, limit: Self.pageSize)) ?? []
    }

    private func reload() {
        rows = fetch(before: nil)
        mayHaveMore = rows.count == Self.pageSize
    }

    private func loadMore() {
        guard let last = rows.last else { return }
        let more = fetch(before: last.createdAt)
        rows.append(contentsOf: more)
        mayHaveMore = more.count == Self.pageSize
    }

    private func deleteSelected() {
        guard let record = selected else { return }
        container.deleteRecord(id: record.id)
        selectedId = nil
        reload()
    }
}
