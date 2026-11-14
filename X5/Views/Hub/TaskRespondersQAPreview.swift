#if DEBUG
import SwiftUI

/// Только QA-скрин в симуляторе: настоящий TaskDetailView с мок-откликами,
/// без входа и сети (X5_TASK_QA_PREVIEW=1, X5_TASK_QA_USER — чей вид).
struct TaskRespondersQAPreview: View {
    @EnvironmentObject private var auth: Auth
    @State private var ready = false

    static var isOn: Bool { ProcessInfo.processInfo.environment["X5_TASK_QA_PREVIEW"] == "1" }

    var body: some View {
        Group {
            if ready {
                NavigationStack { TaskDetailView(task: Self.task) }
            } else {
                Color.black
            }
        }
        .onAppear {
            auth.qaPreviewUserId(ProcessInfo.processInfo.environment["X5_TASK_QA_USER"] ?? "qa-viewer")
            ready = true
        }
    }

    static let task: HubTask = {
        let json = #"{"id":"6f1c2a9e-4b7d-4e2a-9c51-3d8e0f7a1b24","author_id":"qa-author","author_name":"X5","title":"Монтажер","description":"Нужен монтажёр для рилс: 4 ролика в неделю","budget":"Обговаривается","category":"video","categories":["video"],"country_code":"KZ","city":"Алматы","status":"open"}"#
        return try! JSONDecoder().decode(HubTask.self, from: Data(json.utf8))
    }()

    // Выдуманные имена, не из прода.
    static let responses: [TaskResponse] = ["Айдана", "Ерлан", "Мадина", "Санжар", "Дина", "Арсен", "Алия", "Нурлан"]
        .enumerated()
        .map { index, name in
            TaskResponse(
                id: "qa-response-\(index)",
                taskId: task.id,
                specialistId: "qa-specialist-\(index)",
                specialistName: name,
                specialistAvatar: nil,
                message: "Отклик через чат",
                status: "open",
                createdAt: nil
            )
        }
}
#endif
