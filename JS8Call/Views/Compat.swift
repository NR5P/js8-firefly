import SwiftUI

/// Small wrappers so the Mac app still runs on macOS 13, where a few newer SwiftUI calls don't exist.
/// On iOS they compile to exactly the call they wrap.
extension View {
    /// Runs `action` with the new value whenever `value` changes.
    @ViewBuilder
    func onValueChange<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        #if os(macOS)
        if #available(macOS 14, *) {
            onChange(of: value) { _, new in action(new) }
        } else {
            onChange(of: value, perform: action)
        }
        #else
        onChange(of: value) { _, new in action(new) }
        #endif
    }

    /// The rolling wave on the transmit indicator; static on macOS 13.
    @ViewBuilder
    func transmitEffect(isActive: Bool) -> some View {
        #if os(macOS)
        if #available(macOS 14, *) {
            symbolEffect(.variableColor.iterative, isActive: isActive)
        } else {
            self
        }
        #else
        symbolEffect(.variableColor.iterative, isActive: isActive)
        #endif
    }

    /// A gentle pulse on an SF Symbol; static on macOS 13.
    @ViewBuilder
    func pulseEffect() -> some View {
        #if os(macOS)
        if #available(macOS 14, *) {
            symbolEffect(.pulse)
        } else {
            self
        }
        #else
        symbolEffect(.pulse)
        #endif
    }
}
