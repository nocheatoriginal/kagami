# Kagami

Ein Overlay für macOS. Zieh eine App ins Kagami-Fenster: Sie läuft dann auf einem eigenen virtuellen Monitor, und Kagami zeigt diesen Monitor live in einem Overlay, das auf **jedem Desktop/Space und über Vollbild-Apps** liegt. Du kannst die App dort direkt bedienen, also klicken, scrollen, tippen und ziehen.

## Wie es funktioniert

```
┌────────────── Overlay (NSPanel, alle Spaces, über Vollbild) ─────────────┐
│  TopBar: ＋  ⤢        Kagami — Safari · Notes           …  👁            │
│ ┌──────────────────────────────────────────────────────────────────────┐ │
│ │   StreamView  ◄── ScreenCaptureKit (60 fps, IOSurface)               │ │
│ │       │                                     ▲                         │ │
│ │       │ Maus/Scroll → InputForwarder        │                         │ │
│ └───────┼─────────────────────────────────────┼─────────────────────────┘ │
└─────────┼─────────────────────────────────────┼───────────────────────────┘
          ▼                                     │
   ┌──────────────────── Virtueller Monitor „Kagami“ (CGVirtualDisplay) ───┐
   │   Fenster der gehosteten Apps (per Accessibility dorthin verschoben)  │
   └───────────────────────────────────────────────────────────────────────┘
```

* **VirtualDisplay**: legt mit der privaten CoreGraphics-API `CGVirtualDisplay` einen echten Monitor an (dieselbe Technik wie DeskPad oder BetterDisplay). Seine Auflösung folgt der Größe des Overlays, und er wird diagonal an die äußerste Ecke deiner Monitore gesetzt.
* **HostManager**: verschiebt die Fenster der App per Accessibility-API auf diesen Monitor und fängt neue Fenster der App automatisch ein.
* **DisplayCapture**: streamt den Monitor per ScreenCaptureKit direkt als GPU-Surface ins Overlay.
* **InputForwarder**: rechnet Mausposition, Klicks, Drags, Rechtsklick und Scrollen auf den virtuellen Monitor um. Beim Klick wird die App aktiv, deshalb landen Tastatureingaben automatisch bei ihr.
* **Cursor-Schutz**: Wandert der echte Mauszeiger auf den unsichtbaren Monitor, wird er sofort zurückgesetzt.

## Voraussetzungen

* macOS 14 (Sonoma) oder neuer
* Xcode 15+ bzw. die Command Line Tools (`xcode-select --install`)
* Unter *Systemeinstellungen › Schreibtisch & Dock* muss **„Monitore verwenden verschiedene Spaces“** aktiv sein (Standard).

## Bauen & Starten

```bash
cd ~/Desktop/projects/kagami
./scripts/run.sh    # baut build/Kagami.app und startet sie
```

Oder Schritt für Schritt: `./scripts/build-app.sh` und dann `open build/Kagami.app`.

In Xcode entwickeln: `open Package.swift`. Zum Testen der Berechtigungen solltest du aber immer die gebaute `.app` starten.

### In „Programme“ installieren

```bash
./scripts/install.sh   # baut, beendet ein laufendes Kagami, kopiert nach /Applications und startet es
```

Danach findest du Kagami in Launchpad und Spotlight. Es läuft immer nur **eine** Instanz: Ein zweiter Start blendet einfach das Overlay der laufenden Instanz ein. Kagami lässt sich auch nicht in sich selbst legen.

Das Icon liegt in `Resources/AppIcon.png`. Es wird beim Bauen automatisch zu `.icns` umgewandelt, und `scripts/make_icon.py` erzeugt es neu.

### Berechtigungen (beim ersten Start)

1. **Bildschirm- & Systemaudioaufnahme**: erlauben und Kagami danach neu starten (Menüleiste › Kagami › *Kagami neu starten*).
2. **Bedienungshilfen**: erlauben. Das wird ohne Neustart erkannt.

> Tipp: Ist ein „Apple Development“-Zertifikat installiert (Xcode › Settings › Accounts), signiert das Build-Skript automatisch damit. Dann bleiben die Berechtigungen über Rebuilds erhalten. Bei ad-hoc-Signatur fragt macOS nach jedem Build neu; aufräumen mit `tccutil reset ScreenCapture io.github.nocheatoriginal.kagami && tccutil reset Accessibility io.github.nocheatoriginal.kagami`.

## Bedienung

| Aktion | Wie |
|---|---|
| App direkt in Kagami starten | **＋** oben links öffnet den Starter (Suche, ↩ startet den ersten Treffer, esc schließt) |
| Laufende App hineinholen | `.app` ins Fenster ziehen, im Starter anklicken (Punkt = läuft schon) oder Menüleiste › *Laufende App hineinholen* |
| Zwischen Apps wechseln | App-Tabs oben in der Leiste anklicken oder **⌃⌥⇥** (Rechtsklick auf einen Tab: Vollbild, zurückholen, beenden) |
| Alle zurückholen | Menü › *Alle zurück auf den Hauptbildschirm* (nacheinander, Vollbild bleibt erhalten) |
| Overlay ein/aus | **⌃⌥K** (global), 👁 in der Leiste oder Menüleistensymbol |
| Verschieben | an der oberen Leiste ziehen |
| Größe ändern | am Fensterrand oder an der Ecke ziehen (mit nativen Pfeilen); der virtuelle Monitor passt seine Auflösung an |
| Fenster einpassen | 🪟 in der Leiste |
| Vollbild umschalten | ⤢ in der Leiste, **⌃⌥F**, oder ganz normal ⌃⌘F / grüner Knopf in der App |
| Immer Vollbild | Menü › *Apps im Vollbild öffnen* |
| App zurückgeben | Menüleiste › *In Kagami* › App › *Zurück auf den Hauptbildschirm* |
| Eingabemodus | Menü › *Eingabe* (siehe unten) |
| Deckkraft | Menü › *Deckkraft* |
| In Kagami „hineingehen“ | mit drei Fingern zum Schreibtisch **„Kagami“** wischen (oder Menü › *Zum Kagami-Schreibtisch wechseln*) |
| Kagami-Schreibtisch ein/aus | Menü › *Eigener Kagami-Schreibtisch (Wischen)* |

### Vollbild

Fenster im nativen Vollbildmodus bleiben im Vollbild: Kagami verlässt kurz den Vollbildmodus, verschiebt das Fenster auf den Kagami-Bildschirm und schaltet dort wieder auf Vollbild. Dann füllt die App das Overlay komplett aus und läuft in einem eigenen Space auf dem virtuellen Monitor. Wenn du das Overlay größer oder kleiner ziehst, wächst das Vollbild-Fenster mit. Gibst du die App zurück, landet sie wieder im Vollbild auf dem Hauptbildschirm.

### Kagami-Schreibtisch

Solange Kagami läuft, gibt es auf dem Hauptbildschirm einen eigenen Vollbild-Space „Kagami“, auch wenn das Overlay ausgeblendet ist. Wischst du hinein, schaltet der virtuelle Monitor auf die Auflösung deines Bildschirms um und wird dort bildschirmfüllend angezeigt. Das Overlay ist solange ausgeblendet. Klicks, Ziehen und Scrollen laufen dort immer als echte HID-Events (wie im Modus *Kompatibel*), damit auch Browser und Electron-Apps reagieren und die Tastatur bei der angeklickten App landet. Wischst du wieder raus, kommt das Overlay in seiner alten Größe zurück.

Bei Mission Control und „Schreibtisch anzeigen“ weicht das Overlay zum Bildschirmrand aus und kommt danach zurück.

### Eingabemodi

* **Direkt** (Standard): Events gehen direkt an den Prozess, der Cursor bleibt, wo er ist, und Hover-Effekte funktionieren. Das läuft mit den meisten nativen Apps.
* **Kompatibel**: echte HID-Events. Der Cursor springt für Millisekunden auf den virtuellen Monitor und sofort zurück. Damit funktionieren auch Chrome, Electron-Apps (Slack, VS Code, Discord …) und Spiele. Kein Hover.

Klicks auf die Menüleiste des virtuellen Monitors laufen in beiden Modi über echte HID-Events.

## Bekannte Grenzen

* Fenster auf anderen Spaces findet Kagami über eine private Accessibility-Funktion. Lassen sie sich trotzdem nicht erreichen, springt Kagami einmal kurz zur App und danach zur vorherigen App zurück.

* `CGVirtualDisplay` ist private API. Das ist für die eigene Nutzung kein Problem, im Mac App Store aber nicht erlaubt. Die API kann sich mit macOS-Updates ändern.
* Manche Apps erlauben kein Verschieben oder keine freie Größe (z. B. feste Fenstergrößen).
* Geöffnete Menüs der gehosteten App können im Kompatibel-Modus zicken, weil der echte Cursor nicht auf dem Monitor ist.
* Ab macOS 15 fragt das System regelmäßig nach, ob Kagami weiter aufnehmen darf.
* Beim Beenden verschwindet der virtuelle Monitor, und macOS holt die Fenster automatisch auf den Hauptbildschirm zurück.

## Projektstruktur

```
Package.swift
Sources/CGVirtualDisplayPrivate/   Header der privaten API
Sources/Kagami/
  AppDelegate.swift      App-Start, Menüs, Verdrahtung
  OverlayPanel.swift     Overlay-Fenster + obere Leiste
  KagamiSpace.swift      Kagami-Schreibtisch (Vollbild-Space, Eingaben)
  ExposeWatcher.swift    Mission Control / Schreibtisch anzeigen erkennen
  StreamView.swift       Live-Bild, Maus-Events, Drag & Drop
  VirtualDisplay.swift   virtueller Monitor, Auflösung, Platzierung
  DisplayCapture.swift   ScreenCaptureKit-Stream
  InputForwarder.swift   Maus/Scroll → virtueller Monitor
  HostManager.swift      Apps hineinholen/zurückgeben, Fenster einfangen
  AXHelpers.swift        Accessibility-Hilfen
  AXSpaces.swift         Fenster auf allen Spaces finden (privater AX-Trick wie in AltTab)
  Geometry.swift         Koordinatensysteme
  Support.swift          Einstellungen, Menü-Items, globales Tastenkürzel
  LauncherView.swift     Starter mit allen installierten Apps
  ResizeCursor.swift     native Pfeile beim Größe ändern
  SingleInstance.swift   nur eine Instanz, Neustart, kein Kagami-in-Kagami
Resources/Info.plist
scripts/build-app.sh   Bauen + Signieren
scripts/run.sh         Bauen + Starten
scripts/install.sh     Bauen + nach /Applications installieren
scripts/make_icon.py   App-Icon erzeugen (Python + Pillow)
```