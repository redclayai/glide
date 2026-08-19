/// System-owned keyboard shortcuts that KeyType must observe but never reinterpret as text editing.
public enum ReservedSystemShortcut {
    /// macOS screenshot / screen-recording shortcuts:
    /// - Shift-Command-3: capture screen
    /// - Shift-Command-4: capture selected area/window
    /// - Shift-Command-5: open Screenshot controls / recording
    /// Holding Control sends the capture to the clipboard; it is still non-mutating for the text field.
    public static func isScreenCapture(
        keyCode: Int64,
        shift: Bool,
        control: Bool,
        option: Bool,
        command: Bool
    ) -> Bool {
        guard command, shift, !option else { return false }
        switch keyCode {
        case 20, 21, 23:
            return true
        default:
            return false
        }
    }
}
