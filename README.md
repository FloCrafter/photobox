# Raspberry Pi Photobox Software

Dieses Projekt ist eine vollautomatische, Raspberry Pi-gesteuerte Photobox-Software, die per Tastendruck Fotos aufnimmt, diese in einem anpassbaren Layout anordnet und optional direkt ausdruckt oder per QR-Code zum Download anbietet.

![Beispiel-Screenshot der Anwendung]
<!-- Hier könntest du später einen Screenshot deiner fertigen Oberfläche einfügen -->

---

##  Features

- **Einfache Bedienung:** Startet per Tastendruck einen Countdown und nimmt automatisch eine Serie von Fotos auf.
- **Anpassbare Layouts:** Erstelle eigene Fotolayouts (z.B. Fotostreifen, 10x15-Postkarten) über einen integrierten Web-Layout-Editor.
- **Live-Vorschau:** Zeigt das Kamerabild in Echtzeit auf dem Bildschirm an.
- **Sofortiger Druck:** Verbindet sich mit jedem CUPS-fähigen Drucker für den direkten Ausdruck der fertigen Fotocollage.
- **QR-Code-Sharing:** Generiert nach jeder Aufnahme einen QR-Code, über den Gäste das Foto direkt auf ihr Smartphone herunterladen können (benötigt ngrok).
- **Kiosk-Modus:** Startet nach dem Hochfahren des Raspberry Pi automatisch im Vollbildmodus, bereit für den Einsatz ohne Tastatur oder Maus.
- **Umfangreiche Konfiguration:** Alle wichtigen Parameter wie Auslöser-Taste, Countdown-Zeit, Drucker, Layout und Texte sind über ein Web-Interface einstellbar.

---

##  Setup & Installation

Das gesamte System kann mit einem einzigen Befehl auf einem frischen, Debian-basierten System (z.B. Raspberry Pi OS with desktop) installiert werden.

**Voraussetzungen:**
- Ein Raspberry Pi 4 (oder neuer) mit Raspberry Pi OS (Desktop-Version).
- Eine angeschlossene Webcam.
- Eine aktive Internetverbindung für die Erstinstallation.

**Installation:**
Öffnen Sie ein Terminal und führen Sie den folgenden Befehl aus:

```bash
curl -sSL https://swagnation.de/backup/phb/setup.sh | bash
