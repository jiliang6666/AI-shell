import SwiftUI

/// A persistent choice surface above the composer, outside chat scrollback.
struct AIUserQuestionCard: View {
    let question: AIUserQuestion
    var fontSize: Double = 14
    var isSubmitting = false
    var errorMessage: String?
    var onAnswer: (String?, String) -> Void
    var onCancel: () -> Void
    @State private var customAnswer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(question.arguments.options.isEmpty ? "等待你的回答" : "请选择后继续", systemImage: "questionmark.bubble.fill")
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    Text(question.arguments.question)
                        .font(.system(size: fontSize, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(question.arguments.reason)
                        .font(.system(size: max(12, fontSize - 1)))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(question.arguments.options) { option in
                        Button { onAnswer(option.id, customAnswer.trimmingCharacters(in: .whitespacesAndNewlines)) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 5) {
                                    Text(option.label).font(.system(size: fontSize, weight: .medium))
                                    if option.id == question.arguments.recommendedOptionID {
                                        Text("建议").font(.system(size: max(11, fontSize - 2), weight: .medium)).foregroundStyle(Color.accentColor)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                                }
                                if let description = option.description, !description.isEmpty {
                                    Text(description).font(.system(size: max(12, fontSize - 1))).foregroundStyle(.secondary)
                                }
                            }
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9)
                            .background(Color.accentColor.opacity(option.id == question.arguments.recommendedOptionID ? 0.09 : 0.04), in: RoundedRectangle(cornerRadius: 9))
                            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.accentColor.opacity(0.18)) }
                            .contentShape(RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .help("选择后继续当前任务")
                        .accessibilityIdentifier("ai.question.option.\(option.id)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(1)
            }
            .frame(maxHeight: max(230, fontSize * 18))
            HStack(alignment: .bottom, spacing: 8) {
                TextField(question.arguments.options.isEmpty ? "填写回答…" : "也可以补充你的选择…", text: $customAnswer, axis: .vertical)
                    .font(.system(size: fontSize))
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitCustomAnswer)
                    .accessibilityIdentifier("ai.question.answer")
                Button(action: submitCustomAnswer) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .disabled(customAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("提交回答并继续")
                .accessibilityIdentifier("ai.question.submit")
            }
            if let errorMessage {
                Text(errorMessage).font(.system(size: max(12, fontSize - 1))).foregroundStyle(.red)
            }
            HStack {
                if isSubmitting { ProgressView().controlSize(.mini); Text("正在保存选择…").font(.caption) }
                Spacer()
                Button("取消任务", action: onCancel).buttonStyle(.plain)
                    .font(.system(size: max(12, fontSize - 1))).foregroundStyle(.secondary)
                    .accessibilityIdentifier("ai.question.cancel")
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1) }
        .disabled(isSubmitting)
        .accessibilityIdentifier("ai.question.card")
    }

    private func submitCustomAnswer() {
        let text = customAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { onAnswer(nil, text) }
    }
}
