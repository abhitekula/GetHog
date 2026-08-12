import CoreGraphics

/// Interaction dimensions shared by every shell that draws `GetHogUI` views.
///
/// Pointer controls use the native compact desktop floor. Direct-touch and
/// gaze-driven platforms retain a 44pt target, while call sites keep ownership
/// of visual styling and label placement.
public enum PlatformControlMetrics {
    public static let pointerMinimumInteractiveLength: CGFloat = 28
    public static let touchMinimumInteractiveLength: CGFloat = 44

    #if os(macOS)
    public static let minimumInteractiveLength = pointerMinimumInteractiveLength
    #else
    public static let minimumInteractiveLength = touchMinimumInteractiveLength
    #endif
}
