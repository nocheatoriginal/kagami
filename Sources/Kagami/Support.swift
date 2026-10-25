import AppKit
import Carbon.HIToolbox

/// Persistente Einstellungen.
enum Settings {
    private static let defaults = UserDefaults.standard

    static var inputMode: InputMode {
        get { InputMode(rawValue: defaults.string(forKey: "inputMode") ?? "") ?? .direct }
        set { defaults.set(newValue.rawValue, forKey: "inputMode") }
    }
    /// Fenster gehosteter Apps füllen den ganzen virtuellen Bildschirm.
    static var fillWindows: Bool {
        get { defaults.object(forKey: "fillWindows") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "fillWindows") }
    }
    /// Auflösung des virtuellen Bildschirms folgt der Overlay-Größe.
    static var resolutionFollowsWindow: Bool {
        get { defaults.object(forKey: "resolutionFollowsWindow") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "resolutionFollowsWindow") }
    }
    /// Hineingeholte Apps automatisch in den Vollbildmodus schalten.
    static var openFullscreen: Bool {
        get { defaults.object(forKey: "openFullscreen") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "openFullscreen") }
    }
    static var opacity: CGFloat {
        get { CGFloat(defaults.object(forKey: "opacity") as? Double ?? 1.0) }
        set { defaults.set(Double(newValue), forKey: "opacity") }
    }
}

/// NSMenuItem mit Closure statt Target/Action.
final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command],
         handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(ActionMenuItem.fire), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @MainActor @objc private func fire() { handler() }
}

/// Globales Tastenkürzel (Carbon), funktioniert auch wenn Kagami nicht aktiv ist.
/// Jede Instanz braucht eine eigene `id`, damit nur ihr eigenes Kürzel sie auslöst.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let identifier: UInt32
    private let action: @MainActor () -> Void

    init(id: UInt32, keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) {
        self.identifier = id
        self.action = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            // Nicht unser Kürzel → an den nächsten Handler weiterreichen.
            guard status == noErr, pressed.id == hotKey.identifier else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &spec, userData, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4B47_4D49), id: id)  // "KGMI"
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
