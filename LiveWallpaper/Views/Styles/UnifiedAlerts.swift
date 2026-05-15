import SwiftUI

/// Unified error-alert presentation. Replaces the repeated
/// `.alert(...) Binding(get:set:)` boilerplate that previously sat on every
/// settings / cache / library / scene-import surface. Pairs with
/// `DestructiveActionPolicy.confirmDestructive` so the codebase has exactly
/// one error-display modifier and one destructive-confirm modifier.
///
/// Two surfaces:
///
/// - `errorAlert(_:message:)` — drives presentation off an optional `String?`
///   binding. Use when the call site already builds the message itself
///   (validation summary, import/export failures, etc.). Dismiss clears the
///   binding back to `nil`.
/// - `errorAlert(_:error:)` — drives presentation off an optional `Error?`
///   binding and renders `localizedDescription` plus `recoverySuggestion`
///   (when the error conforms to `LocalizedError`).
extension View {
    func errorAlert(
        _ title: LocalizedStringKey,
        message: Binding<String?>
    ) -> some View {
        modifier(StringErrorAlertModifier(title: title, message: message))
    }

    func errorAlert<E: Error>(
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
