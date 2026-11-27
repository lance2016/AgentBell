import SwiftUI

/// 代码审查: the reviews still running on a card, the finished ones on a card under it.
/// A click opens one in the review window, which has the room to read a report.
struct ReviewsPage: View {
    let reviews: ReviewStore
    let open: (String) -> Void

    private var running: [ReviewStore.Job] { reviews.jobs.filter(\.running) }
    private var failed: [ReviewStore.Job] { reviews.jobs.filter { !$0.running } }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if reviews.jobs.isEmpty && reviews.records.isEmpty {
                    ContentUnavailableView("还没有审查", systemImage: "text.magnifyingglass",
                                           description: Text("用「新建审查」发起，完成的报告会列在这里。"))
                }
                if !running.isEmpty {
                    card("进行中", ids: running.map(\.id))
                }
                if !failed.isEmpty || !reviews.records.isEmpty {
                    card("已完成", ids: failed.map(\.id) + reviews.records.map(\.id))
                }
            }
            .padding(BellLayout.inset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Reports are files: the folder may have changed since the last look.
        .onAppear { reviews.reload() }
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
                .help("在审查窗口打开")
            }
        }
        .modifier(SessionGroupSurface())
    }

    @ViewBuilder private func row(_ id: String) -> some View {
        if let job = reviews.job(id) {
            JobRow(job: job)
        } else if let record = reviews.record(id) {
            RecordRow(record: record)
        }
    }
}
