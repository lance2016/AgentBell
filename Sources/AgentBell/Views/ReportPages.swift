import BellCore
import SwiftUI

/// 代码审查: the reviews still running on a card, the finished ones on a card under it.
/// A click opens one in the review window, which has the room to read a report.
struct ReviewsPage: View {
    let reviews: ReviewStore
    let open: (String) -> Void

    var body: some View {
        let running = reviews.jobs.filter(\.running).map(\.id)
        let finished = reviews.jobs.filter { !$0.running }.map(\.id) + reviews.records.map(\.id)
        ReportCards(running: ("进行中", running), finished: finished, window: "审查窗口", open: open) { id in
            if let job = reviews.job(id) {
                JobRow(job: job)
            } else if let record = reviews.record(id) {
                RecordRow(record: record)
            }
        } empty: {
            ContentUnavailableView("还没有审查", systemImage: "text.magnifyingglass",
                                   description: Text("用「新建审查」发起，完成的报告会列在这里。"))
        }
        // Reports are files: the folder may have changed since the last look.
        .onAppear { reviews.reload() }
    }
}

/// 周报: the reports being written, then the saved ones. A click opens one in the weekly
/// window, where it can be read and edited.
struct WeeklyPage: View {
    let weekly: WeeklyStore
    let open: (String) -> Void

    var body: some View {
        let running = weekly.jobs.filter(\.running).map(\.id)
        let finished = weekly.jobs.filter { !$0.running }.map(\.id) + weekly.records.map(\.id)
        ReportCards(running: ("生成中", running), finished: finished, window: "周报窗口", open: open) { id in
            if let job = weekly.job(id) {
                WeeklyJobRow(job: job)
            } else if let record = weekly.record(id) {
                WeeklyRecordRow(record: record)
            }
        } empty: {
            ContentUnavailableView("还没有周报", systemImage: "calendar",
                                   description: Text("用「生成周报」整理本周或上周的会话，写好的周报会列在这里。"))
        }
        .onAppear { weekly.reload() }
    }
}

/// What still runs on a card, the finished ones on a card under it; each row opens its
/// item in `window`.
private struct ReportCards<Row: View, Empty: View>: View {
    let running: (title: String, ids: [String])
    let finished: [String]
    let window: String
    let open: (String) -> Void
    @ViewBuilder let row: (String) -> Row
    @ViewBuilder let empty: () -> Empty

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if running.ids.isEmpty && finished.isEmpty {
                    empty()
                }
                if !running.ids.isEmpty {
                    card(running.title, ids: running.ids)
                }
                if !finished.isEmpty {
                    card("已完成", ids: finished)
                }
            }
            .padding(BellLayout.inset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card(_ title: String, ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.groupName)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .accessibilityAddTraits(.isHeader)
            ForEach(ids, id: \.self) { id in
                CardDivider(leading: 12)
                Button { open(id) } label: {
                    row(id)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(BellButtonStyle())
                .help("在\(window)打开")
            }
        }
        .modifier(SessionGroupSurface())
    }
}
