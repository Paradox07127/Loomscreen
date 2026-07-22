import SwiftUI

/// Unified error-alert presentation. Pairs with
/// `DestructiveActionPolicy.confirmDestructive` so the codebase has exactly
/// one error-display modifier and one destructive-confirm modifier.
extension View {
    public func errorAlert(
        _ title: LocalizedStringKey,
        message: Binding<String?>
    ) -> some View {
        modifier(StringErrorAlertModifier(title: title, message: message))
    }

    public func errorAlert<E: Error>(
        _ title: LocalizedStringKey,
        error: Binding<E?>
    ) -> some View {
        modifier(TypedErrorAlertModifier(title: title, error: error))
    }
}

private struct StringErrorAlertModifier: ViewModifier {
    let title: LocalizedStringKey
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.alert(
            title,
            isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )
        ) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(verbatim: message ?? "")
        }
    }
}

private struct TypedErrorAlertModifier<E: Error>: ViewModifier {
    let title: LocalizedStringKey
    @Binding var error: E?

    func body(content: Content) -> some View {
        content.alert(
            title,
            isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            ),
            presenting: error
        ) { _ in
            Button("OK", role: .cancel) { error = nil }
        } message: { value in
            if let localized = value as? LocalizedError,
               let suggestion = localized.recoverySuggestion {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text(verbatim: localized.errorDescription ?? value.localizedDescription)
                    Text(verbatim: suggestion).font(.caption)
                }
            } else {
                Text(verbatim: value.localizedDescription)
            }
        }
    }
}
