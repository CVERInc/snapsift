import Foundation

// One card, three ways in — a key, a pointer, an assistive technology — and one
// set of rules. Everything here is what the app's card buttons, context menu
// and VoiceOver actions ask BEFORE they call the same handlers the keys call.

// MARK: - The cross-out verb a card offers

/// What "cross out" means on THIS card right now. The pointer has no Shift, so
/// the choice the keyboard makes with X versus ⇧X is made here from state.
public enum CardRejectVerb: Equatable {
    /// Unmarked, deletable: X.
    case crossOut
    /// Marked (by anyone, protected or not): X again. Always the safe direction.
    case undoCrossOut
    /// A KNOWN protection (favourite / edited / document), unmarked: the ⇧X
    /// path, which asks before it marks.
    case crossOutProtected
    /// Could not be classified, so it is protected and has NO override: the
    /// plain-X path, which marks nothing and says why.
    case explainUnverifiable

    /// The modifier the shared reject handler is called with. Only the
    /// protected override is the Shift form; everything else is plain X.
    public var usesShift: Bool { self == .crossOutProtected }
    /// Can this verb, by itself, add a deletion mark? (`crossOutProtected`
    /// cannot: it opens a confirmation, and the confirmation marks.)
    public var marksImmediately: Bool { self == .crossOut }
}

public func cardRejectVerb(isMarked: Bool, isProtected: Bool, isUnverifiable: Bool) -> CardRejectVerb {
    if isMarked { return .undoCrossOut }
    if isUnverifiable { return .explainUnverifiable }
    if isProtected { return .crossOutProtected }
    return .crossOut
}

/// Every verb a card can be asked to perform without a keyboard.
public enum CardVerb: Equatable {
    case focus          // click: look, change nothing
    case keep           // K
    case reject         // X / ⇧X — which one is `cardRejectVerb`
    case keepOnly       // ⇧K
    case preview        // Space / Return
}

/// Does this verb leave every mark and nomination exactly as it was?
/// `focus` and `preview` must: a click that only looks is the whole point.
public func cardVerbIsReadOnly(_ verb: CardVerb) -> Bool {
    switch verb {
    case .focus, .preview: return true
    case .keep, .reject, .keepOnly: return false
    }
}

// MARK: - What a card is, in words

/// The decision a card carries, for a listener who cannot see its border.
public enum CardSpokenState: Equatable {
    case willKeep
    case willDelete
    /// Unclassifiable ⇒ protected ⇒ a person should look. NEVER `.undecided`:
    /// "no decision" tells her she may decide, and X will refuse.
    case pleaseConfirm
    /// A known protection, not marked.
    case protected
    case undecided
}

/// Priority follows what will actually HAPPEN to the frame: it survives as the
/// group's keeper, or it is removed; only then why it cannot be removed.
public func cardSpokenState(isKeeper: Bool, isDelete: Bool,
                            isProtected: Bool, isUnverifiable: Bool) -> CardSpokenState {
    if isKeeper { return .willKeep }
    if isDelete { return .willDelete }
    if isUnverifiable { return .pleaseConfirm }
    if isProtected { return .protected }
    return .undecided
}

// MARK: - Pane dimming that stays readable

/// sRGB 0…255 triple.
public struct RGB: Equatable {
    public let r: Double, g: Double, b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    public init(hex: Int) {
        self.init(Double((hex >> 16) & 0xff), Double((hex >> 8) & 0xff), Double(hex & 0xff))
    }
}

/// WCAG 2.x relative luminance.
public func relativeLuminance(_ c: RGB) -> Double {
    func lin(_ v: Double) -> Double {
        let s = v / 255
        return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
}

/// WCAG contrast of `fg` drawn at `alpha` over an opaque `bg`.
public func contrastRatio(_ fg: RGB, alpha: Double = 1, over bg: RGB) -> Double {
    let a = min(max(alpha, 0), 1)
    let mixed = RGB(fg.r * a + bg.r * (1 - a), fg.g * a + bg.g * (1 - a), fg.b * a + bg.b * (1 - a))
    let l1 = relativeLuminance(mixed), l2 = relativeLuminance(bg)
    return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
}

public enum PaneDim {
    /// PROPOSAL — the owner has not ruled on it.
    ///
    /// The ratified spec (SPEC-ui-redesign-2026-09-16 §2) says: unselected
    /// sidebar rows dim to 0.35, and pane focus is shown WITHOUT a colour
    /// line. 0.35 puts the row caption at 1.89:1, so this build proposes the
    /// two values below instead and the owner judges them on screen. Until he
    /// does, the spec stands as written and these are the only two places the
    /// proposal lives. The test suite pins the FLOOR (dimmed text ≥ 4.5:1 on
    /// the sidebar colour) and "Increase Contrast ⇒ no dimming" — not these
    /// numbers.
    public static let proposal = (unselectedRowOpacity: 0.85, selectedRowOutlineWidth: 2.0)

    /// Increase Contrast ⇒ nothing dims, ever. The selected row never dims.
    public static func sidebarRowOpacity(contentActive: Bool, selected: Bool,
                                         increaseContrast: Bool) -> Double {
        guard contentActive, !selected, !increaseContrast else { return 1 }
        return proposal.unselectedRowOpacity
    }
}

// MARK: - Card controls and the double-click

/// May a card's control buttons take a click right now?
///
/// A click FOCUSES a card, and focusing is what makes its buttons appear —
/// possibly under the pointer or the finger. The second click of a double-
/// click (meant: "open the preview") would then land on a button that was not
/// there when she aimed, and "cross out" marks on one click. So buttons that
/// appeared because of a focus stay inert until the double-click interval has
/// passed; during it, clicks fall through to the card, which is what the
/// second click was aimed at. Buttons shown by HOVER on a card that is not
/// focused wait the same interval from the moment the pointer arrived: a
/// pointer that enters at the card's corner and double-clicks at once would
/// otherwise land its first click on a button that appeared under it.
public func cardControlsHittable(isFocused: Bool, focusAge: TimeInterval,
                                 hoverAge: TimeInterval,
                                 doubleClickInterval: TimeInterval) -> Bool {
    isFocused ? focusAge >= doubleClickInterval : hoverAge >= doubleClickInterval
}
