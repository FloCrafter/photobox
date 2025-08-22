#!/bin-bash
set -e
# ==============================================================================
# Setup-Skript für die COMP-PHB Photobox-Anwendung (Kiosk-Modus)
# ==============================================================================
# Erstellt die komplette Struktur inklusive CSS- und JS-Dateien.
# ==============================================================================

# --- Sicherheitscheck: Nicht als root ausführen ---
if [ "$(id -u)" = "0" ]; then
   echo "Dieses Skript sollte nicht als root-Benutzer ausgeführt werden. Führen Sie es als normaler Benutzer mit sudo-Rechten aus (z.B. der 'pi'-Benutzer)." >&2
   exit 1
fi

# --- Konfiguration ---
PROJECT_DIR_NAME="Photobox"
PROJECT_PATH="$HOME/$PROJECT_DIR_NAME" # Absoluter Pfad
SERVICE_NAME="photobox"
CURRENT_USER=$(whoami)

# --- Farben für die Ausgabe ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Starte das Kiosk-Setup für die Photobox-Anwendung...${NC}"

# --- Schritt 1: Systemabhängigkeiten installieren ---
echo -e "\n${YELLOW}--> Schritt 1: Installiere Systemabhängigkeiten...${NC}"

# NEU: Zuerst das Tool zur Zeitsynchronisierung installieren.
# Wir leiten Fehlermeldungen um, falls es schon da ist.
echo -e "${YELLOW}   ... installiere ntpdate zur Zeitsynchronisierung...${NC}"
sudo apt-get install -y ntpdate &> /dev/null

# NEU: Erzwinge eine Synchronisierung der Systemzeit.
# "|| true" sorgt dafür, dass das Skript nicht abbricht, falls keine Internetverbindung besteht.
echo -e "${YELLOW}   ... synchronisiere Systemzeit...${NC}"
sudo ntpdate pool.ntp.org || true

# Jetzt führen wir die eigentliche Installation durch.
echo -e "${YELLOW}   ... aktualisiere Paketlisten und installiere Abhängigkeiten...${NC}"
sudo apt-get update && sudo apt-get install -y \
    python3 \
    python3-venv \
    v4l-utils \
    cups \
    fonts-dejavu-core \
    chromium
echo -e "${GREEN}Systemabhängigkeiten erfolgreich installiert.${NC}"

# --- Schritt 2: Projektverzeichnis erstellen ---
echo -e "\n${YELLOW}--> Schritt 2: Erstelle Projektverzeichnisstruktur...${NC}"
if [ -d "$PROJECT_PATH" ]; then
    echo -e "${YELLOW}Warnung: Das Verzeichnis '$PROJECT_PATH' existiert bereits von einem vorherigen Versuch. Es wird entfernt und neu erstellt.${NC}"
    rm -rf "$PROJECT_PATH"
fi
mkdir -p "$PROJECT_PATH"
cd "$PROJECT_PATH" || exit

mkdir -p layouts photos shared_photo static/css static/js static/uploads templates
echo -e "${GREEN}Verzeichnisstruktur erstellt in: $PROJECT_PATH${NC}"


# --- Schritt 3: Anwendungsdateien erstellen ---
echo -e "\n${YELLOW}--> Schritt 3: Erstelle Anwendungsdateien...${NC}"

# WICHTIG: Ersetzen Sie den folgenden Code-Block mit Ihrem vollständigen app.py Code!
cat << 'EOF' > app.py
import os
import cv2
import json
import subprocess
import datetime
import re
import base64
import numpy as np
from flask import Flask, render_template, request, jsonify, send_from_directory
from PIL import Image, ImageDraw, ImageFont
from werkzeug.utils import secure_filename
# --- NEU: Imports für die QR-Code-Funktionalität ---
import shutil
from pyngrok import ngrok
import atexit

# --- Konfiguration (Erweitert) ---
PHOTOS_FOLDER = 'photos'
STATIC_FOLDER = 'static'
LAYOUTS_FOLDER = 'layouts'
UPLOADS_FOLDER = os.path.join(STATIC_FOLDER, 'uploads')
SETTINGS_FILE = 'settings.json'
# --- NEU: Pfade für das geteilte Foto ---
SHARED_PHOTO_FOLDER = 'shared_photo'
LATEST_PHOTO_FILENAME = 'latest.jpg'

app = Flask(__name__, template_folder='templates', static_folder=STATIC_FOLDER)
app.config['LAYOUTS_FOLDER'] = LAYOUTS_FOLDER
app.config['UPLOADS_FOLDER'] = UPLOADS_FOLDER

os.makedirs(PHOTOS_FOLDER, exist_ok=True)
os.makedirs(LAYOUTS_FOLDER, exist_ok=True)
os.makedirs(UPLOADS_FOLDER, exist_ok=True)
# --- NEU: Ordner für geteiltes Foto erstellen ---
os.makedirs(SHARED_PHOTO_FOLDER, exist_ok=True)

# --- NEU: Globale Variable und Aufräumfunktion für ngrok ---
public_url = None
def disconnect_ngrok():
    if public_url:
        print(" * Schließe ngrok Tunnel.")
        ngrok.disconnect(public_url)
atexit.register(disconnect_ngrok)


# --- Hilfsfunktionen ---

# WICHTIG: Deine funktionierende Kamera-Erkennung wird 1:1 übernommen!
def get_available_cameras_robust():
    available_cameras = []
    try:
        result = subprocess.run(['v4l2-ctl', '--list-devices'], capture_output=True, text=True, check=True)
        output = result.stdout
        camera_blocks = re.split(r'\n(?=\S)', output.strip())
        for block in camera_blocks:
            lines = block.strip().split('\n')
            if not lines or '(usb-' not in lines[0]: continue
            camera_name_match = re.match(r'^(.*?)\s*\(usb-', lines[0])
            if not camera_name_match: continue
            camera_name = camera_name_match.group(1).strip()
            for line in lines[1:]:
                device_path = line.strip()
                if device_path.startswith('/dev/video'):
                    try:
                        index = int(re.search(r'\d+$', device_path).group())
                        cap = cv2.VideoCapture(index, cv2.CAP_V4L2)
                        if cap.isOpened():
                            cap.release()
                            available_cameras.append({"id": str(index), "name": f"{camera_name} ({device_path})"})
                    except (ValueError, AttributeError, cv2.error):
                        continue
    except (FileNotFoundError, subprocess.CalledProcessError):
        for i in range(5):
            cap = cv2.VideoCapture(i)
            if cap.isOpened():
                available_cameras.append({"id": str(i), "name": f"Kamera {i}"})
                cap.release()
    return available_cameras

def get_default_settings():
    available_cams = get_available_cameras_robust()
    return {
        "triggerKey": "Enter", "countdownTime": 5, "reviewTime": 15, "printerName": get_printers()[0] if get_printers() else "",
        "selectedLayout": "default.json", "fullscreen": False, "selectedCamera": available_cams[0]['id'] if available_cams else "0",
        "orientation": "landscape", "instructionsPosition": "right", "rotateInPortrait": True,
        
        "text_start_instruction": "Drücke <strong>{key}</strong> um zu starten!",
        "text_review_instruction": "Drucken mit <strong>{key}</strong> | Zurück in <strong>{s}s</strong>",
        "text_capture_progress": "Bild {x} von {y}",
        "text_processing": "Bilder werden verarbeitet",
        "text_printing": "Foto wird gedruckt!",
        "text_settings_title": "Einstellungen",
        "text_settings_layout_editor_btn": "Layout Editor öffnen",
        "text_settings_text_editor_btn": "Text-Editor öffnen",
        "text_settings_trigger_key_label": "Auslöser-Taste:",
        "text_settings_countdown_label": "Countdown (Sekunden):",
        "text_settings_layout_template_label": "Layout-Vorlage:",
        "text_settings_orientation_label": "Anzeige-Modus:",
        "text_settings_portrait_pos_label": "Position der Anleitung (Hochformat):",
        "text_settings_rotate_final_label": "Finales Bild im Hochformat drehen",
        "text_settings_camera_label": "Kamera:",
        "text_settings_printer_label": "Drucker:",
        "text_settings_fullscreen_label": "Vollbildmodus",
        "text_settings_save_btn": "Speichern"
    }

def load_settings():
    if not os.path.exists(SETTINGS_FILE): return get_default_settings()
    try:
        with open(SETTINGS_FILE, 'r', encoding='utf-8') as f:
            settings = json.load(f)
            default_settings = get_default_settings()
            for key, value in default_settings.items():
                settings.setdefault(key, value)
            return settings
    except (json.JSONDecodeError, IOError):
        return get_default_settings()

def save_settings(settings):
    with open(SETTINGS_FILE, 'w', encoding='utf-8') as f: json.dump(settings, f, indent=4, ensure_ascii=False)

def get_printers():
    try:
        result = subprocess.run(['lpstat', '-p'], capture_output=True, text=True, check=True)
        return [line.split()[1] for line in result.stdout.strip().split('\n') if line.startswith('printer')]
    except (subprocess.CalledProcessError, FileNotFoundError): return []
        
def get_layouts():
    layouts = []
    if not os.path.exists(LAYOUTS_FOLDER): return []
    for f in os.listdir(LAYOUTS_FOLDER):
        if f.endswith('.json'):
            try:
                with open(os.path.join(LAYOUTS_FOLDER, f), 'r', encoding='utf-8') as layout_file:
                    data = json.load(layout_file)
                    layouts.append({"id": f, "name": data.get("name", f)})
            except Exception: continue
    return sorted(layouts, key=lambda x: x['name'])

# --- API Endpunkte ---
# MODIFIZIERT: Hauptroute übergibt die public_url an das Template
@app.route('/')
def index(): 
    return render_template('index.html', public_url=str(public_url))

@app.route('/layout-editor')
def layout_editor(): 
    return render_template('layout_editor.html')

@app.route('/text-editor')
def text_editor():
    return render_template('text_editor.html')

@app.route('/api/layouts', methods=['POST'])
def save_layout():
    data, layout_name = request.json, request.json.get('name')
    if not layout_name or not data.get('layout'): return jsonify({"status": "error", "message": "Name oder Layout-Daten fehlen."}), 400
    filename = secure_filename(layout_name).replace(' ', '_').lower()
    if not filename.endswith('.json'): filename += ".json"
    layout_data = data['layout']; layout_data['name'] = layout_name
    filepath = os.path.join(app.config['LAYOUTS_FOLDER'], filename)
    with open(filepath, 'w', encoding='utf-8') as f: json.dump(layout_data, f, indent=4, ensure_ascii=False)
    return jsonify({"status": "success", "message": f"Layout '{filename}' gespeichert."})

@app.route('/api/layout/<path:filename>')
def get_layout_data(filename):
    safe_filename = secure_filename(filename)
    return send_from_directory(app.config['LAYOUTS_FOLDER'], safe_filename)

@app.route('/api/upload-image', methods=['POST'])
def upload_image():
    if 'file' not in request.files: return jsonify({"status": "error", "message": "Keine Datei im Request"}), 400
    file = request.files['file']
    if file.filename == '': return jsonify({"status": "error", "message": "Keine Datei ausgewählt"}), 400
    if file:
        filename = secure_filename(file.filename)
        unique_filename = datetime.datetime.now().strftime("%Y%m%d%H%M%S") + "_" + filename
        filepath = os.path.join(app.config['UPLOADS_FOLDER'], unique_filename)
        file.save(filepath)
        return jsonify({"status": "success", "url": f"/static/uploads/{unique_filename}"})
    return jsonify({"status": "error", "message": "Unbekannter Fehler beim Upload"}), 500

@app.route('/api/settings', methods=['GET', 'POST'])
def handle_settings():
    if request.method == 'POST':
        save_settings(request.json); return jsonify({"status": "success", "message": "Settings saved."})
    else: 
        return jsonify(load_settings())

@app.route('/api/system-info', methods=['GET'])
def get_system_info(): 
    return jsonify({"printers": get_printers(), "cameras": get_available_cameras_robust(), "layouts": get_layouts()})

# --- DIESE FUNKTION WURDE MINIMAL ERGÄNZT ---
@app.route('/api/process-photo', methods=['POST'])
def process_photo_from_browser():
    settings = load_settings()
    data = request.json
    image_data_urls = data.get('imageDataUrls')
    layout_filename = settings.get('selectedLayout')
    instructions_position = settings.get('instructionsPosition', 'right')

    if not image_data_urls or not layout_filename: return jsonify({"status": "error", "message": "Bilddaten oder Layout fehlen."}), 400
    layout_path = os.path.join(LAYOUTS_FOLDER, layout_filename)
    if not os.path.exists(layout_path): return jsonify({"status": "error", "message": "Layout-Datei nicht gefunden."}), 404
    with open(layout_path, 'r', encoding='utf-8') as f: layout = json.load(f)
    canvas_info = layout['canvas']
    final_image = Image.new('RGBA', (canvas_info['width'], canvas_info['height']), canvas_info.get('background_color', '#ffffff'))

    def paste_elements(target_image, elements, layer_filter):
        for element in [e for e in elements if e.get('type') == 'image' and e.get('layer', 'top') == layer_filter]:
            try:
                img_path = element['src'].lstrip('/'); sticker = Image.open(img_path).convert("RGBA")
                sticker.thumbnail((element['width'], element['height']), Image.Resampling.LANCZOS)
                target_image.paste(sticker, (element['x'], element['y']), sticker)
            except Exception as e: print(f"Konnte Sticker {element.get('src')} nicht laden: {e}")

    paste_elements(final_image, layout.get('static_elements', []), 'bottom')
    for i, slot in enumerate(layout['photo_slots']):
        if i >= len(image_data_urls): break
        _, encoded = image_data_urls[i].split(",", 1)
        frame = cv2.imdecode(np.frombuffer(base64.b64decode(encoded), np.uint8), cv2.IMREAD_COLOR)
        photo_pil = Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
        
        if slot.get('orientation') == 'portrait':
            photo_pil = photo_pil.rotate(-90, expand=True)
            if instructions_position == 'left':
                photo_pil = photo_pil.rotate(180)
        
        photo_pil.thumbnail((slot['width'], slot['height']), Image.Resampling.LANCZOS)
        final_image.paste(photo_pil, (slot['x'], slot['y']))
        
    draw = ImageDraw.Draw(final_image)
    for element in [e for e in layout.get('static_elements', []) if e.get('type') == 'text']:
        try:
            font = ImageFont.truetype("DejaVuSans.ttf", element['font_size'])
        except IOError: font = ImageFont.load_default()
        draw.text((element['x'], element['y']), element['content'], font=font, fill=element.get('font_color', '#000000'), anchor=element.get('anchor', 'la'))
    paste_elements(final_image, layout.get('static_elements', []), 'top')

    final_image = final_image.convert("RGB")
    filename = f"photobox_{datetime.datetime.now().strftime('%Y-%m-%d_%H-%M-%S')}.jpg"
    filepath = os.path.join(PHOTOS_FOLDER, filename)
    final_image.save(filepath, "JPEG")

    # --- NEU: Kopiert das fertige Bild für die Freigabe ---
    try:
        latest_photo_path = os.path.join(SHARED_PHOTO_FOLDER, LATEST_PHOTO_FILENAME)
        shutil.copy(filepath, latest_photo_path)
        print(f" * Foto '{filename}' wurde als '{LATEST_PHOTO_FILENAME}' für die Freigabe aktualisiert.")
    except Exception as e:
        print(f" * Fehler beim Kopieren des Fotos für die Freigabe: {e}")
    
    return jsonify({"status": "success", "filename": filename, "url": f"/{PHOTOS_FOLDER}/{filename}"})

@app.route('/api/print-photo', methods=['POST'])
def print_photo():
    data, filename, printer_name = request.json, request.json.get('filename'), load_settings().get('printerName')
    if not filename or not printer_name: return jsonify({"status": "error", "message": "Dateiname oder Drucker fehlt."}), 400
    filepath = os.path.join(PHOTOS_FOLDER, filename)
    if not os.path.exists(filepath): return jsonify({"status": "error", "message": "Datei nicht gefunden."}), 404
    try:
        subprocess.run(['lp', '-d', printer_name, '-o', 'fit-to-page', filepath], check=True)
        return jsonify({"status": "success", "message": f"Drucke {filename} auf {printer_name}."})
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        return jsonify({"status": "error", "message": f"Konnte nicht drucken. Fehler: {e}"}), 500

@app.route('/photos/<filename>')
def serve_photo(filename): 
    return send_from_directory(PHOTOS_FOLDER, filename)

# --- NEUE ROUTE FÜR QR-CODE-FREIGABE ---
@app.route('/latest')
def latest_page():
    """
    Zeigt eine HTML-Seite mit dem neuesten Bild und einem Download-Button.
    Der QR-Code verweist auf diese URL.
    """
    # Zeitstempel, um Caching im Browser zu umgehen
    timestamp = int(datetime.datetime.now().timestamp())
    return render_template('download.html', timestamp=timestamp)

# NEUE ROUTE, die nur das Bild liefert
@app.route('/latest-image')
def latest_image_file():
    """Liefert die reine Bilddatei für die Download-Seite."""
    return send_from_directory(SHARED_PHOTO_FOLDER, LATEST_PHOTO_FILENAME)

# --- MODIFIZIERTER APP-START ---
if __name__ == '__main__':
    PORT = 5000
    
    # Starte ngrok, um einen öffentlichen Link zu erstellen
    try:
        public_url = ngrok.connect(PORT, "http").public_url
        print("="*50)
        print(f" * Photobox läuft auf: http://127.0.0.1:{PORT}")
        print(f" * Öffentlicher Link zum Teilen (für QR-Code): {public_url}/latest")
        print(f" * Öffne diese URL, um den QR-Code auf einem zweiten Gerät anzuzeigen.")
        print("="*50)
    except Exception as e:
        print(f" * Fehler beim Starten von ngrok: {e}")
        print(" * Anwendung wird ohne öffentlichen Freigabe-Link gestartet.")

    # Starte Flask, ABER deaktiviere den Reloader, um den ngrok-Fehler zu vermeiden
    app.run(host='0.0.0.0', port=PORT, debug=True, use_reloader=False)
EOF

# Erstellen der anderen Konfigurationsdateien
echo "{}" > settings.json
echo '{
    "canvas": {
        "width": 900,
        "height": 600,
        "background_color": "#5f5353"
    },
    "photo_slots": [
        {
            "x": 40,
            "y": 60,
            "type": "photo",
            "width": 350,
            "height": 500,
            "orientation": "portrait"
        },
        {
            "x": 510,
            "y": 60,
            "type": "photo",
            "width": 350,
            "height": 500,
            "orientation": "portrait"
        }
    ],
    "static_elements": [
        {
            "x": 350,
            "y": 3,
            "type": "text",
            "width": 200,
            "height": 50,
            "content": "Photobox",
            "font_size": 39,
            "font_color": "#58c729",
            "anchor": "la"
        },
        {
            "x": 753,
            "y": 553,
            "type": "text",
            "width": 200,
            "height": 50,
            "content": "By Flo",
            "font_size": 12,
            "font_color": "#817979",
            "anchor": "la"
        },
        {
            "x": 839,
            "y": -4,
            "type": "image",
            "width": 70,
            "height": 70,
            "layer": "top",
            "src": "/static/uploads/20250822151435_ChatGPT_Image_22._Aug._2025__16_14_03-removebg-preview.png"
        }
    ],
    "name": "default"}' > layouts/default.json

# Platzhalter für HTML-Dateien
echo -e "${YELLOW}   ... erstelle HTML-Dateien...${NC}"
cat << 'EOF' > templates/index.html
<!DOCTYPE html>
<html lang="de">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Raspi Photobox</title>
    <link rel="stylesheet" href="{{ url_for('static', filename='css/style.css') }}">
    <!-- NEU: Skript zur QR-Code-Erzeugung wird hinzugefügt -->
    <script src="https://cdnjs.cloudflare.com/ajax/libs/qrcode-generator/1.4.4/qrcode.js"></script>
</head>
<body>
    <!-- NEU: Die öffentliche URL von ngrok wird hier gespeichert, damit JS darauf zugreifen kann -->
    <div id="photobox-app" data-public-url="{{ public_url }}">
       <div id="live-view-screen" class="screen active">
            <video id="live-video" autoplay playsinline></video>
            <div id="countdown-overlay" class="hidden"></div>
            <div id="flash-overlay" class="hidden"></div>
            <div id="capture-progress" class="hidden"></div>
            <div class="instructions"></div>
        </div>

        <!-- MODIFIZIERT: Der Review-Bildschirm enthält jetzt den QR-Code-Container -->
        <div id="review-screen" class="screen hidden">
            <img id="review-image" src="" alt="Captured Photo">
            
            <div id="qr-code-container" class="hidden">
                <h3>Foto teilen!</h3>
                <div id="qrcode"></div>
            </div>

            <div id="review-instructions-overlay" class="instructions"></div>
        </div>

        <div id="settings-icon">⚙️</div>

        <div id="settings-modal" class="hidden">
            <div class="modal-content">
                <span id="close-settings" class="close-button">×</span>
                <h2 data-text-key="text_settings_title">Einstellungen</h2>
                
                <a href="/layout-editor" class="button-link" data-text-key="text_settings_layout_editor_btn">Layout Editor öffnen</a>
                <a href="/text-editor" class="button-link" data-text-key="text_settings_text_editor_btn">Text-Editor öffnen</a>
                
                <hr class="divider">
                <form id="settings-form">
                    <div class="form-group">
                        <label for="triggerKey" data-text-key="text_settings_trigger_key_label">Auslöser-Taste:</label>
                        <input type="text" id="triggerKey" name="triggerKey">
                    </div>
                    <div class="form-group">
                        <label for="countdownTime" data-text-key="text_settings_countdown_label">Countdown (Sekunden):</label>
                        <input type="number" id="countdownTime" name="countdownTime" min="1" max="10">
                    </div>
                    <div class="form-group">
                        <label for="reviewTime">Review-Zeit (Sekunden):</label>
                        <input type="number" id="reviewTime" name="reviewTime" min="5" max="120">
                    </div>
                    <div class="form-group">
                        <label for="selectedLayout" data-text-key="text_settings_layout_template_label">Layout-Vorlage:</label>
                        <select id="selectedLayout" name="selectedLayout"></select>
                    </div>
                    <div class="form-group">
                        <label for="orientation" data-text-key="text_settings_orientation_label">Anzeige-Modus:</label>
                        <select id="orientation" name="orientation">
                            <option value="landscape">Querformat</option>
                            <option value="portrait">Hochformat</option>
                        </select>
                    </div>
                    <div id="portrait-options">
                        <div class="form-group">
                            <label for="instructionsPosition" data-text-key="text_settings_portrait_pos_label">Position der Anleitung (Hochformat):</label>
                            <select id="instructionsPosition" name="instructionsPosition">
                                <option value="right">Rechts</option>
                                <option value="left">Links</option>
                            </select>
                        </div>
                        <div class="form-group checkbox-group">
                            <input type="checkbox" id="rotateInPortrait" name="rotateInPortrait">
                            <label for="rotateInPortrait" data-text-key="text_settings_rotate_final_label">Finales Bild im Hochformat drehen</label>
                        </div>
                    </div>
                     <hr class="divider">
                    <div class="form-group">
                        <label for="selectedCamera" data-text-key="text_settings_camera_label">Kamera:</label>
                        <select id="selectedCamera" name="selectedCamera"></select>
                    </div>
                    <div class="form-group">
                        <label for="printerName" data-text-key="text_settings_printer_label">Drucker:</label>
                        <select id="printerName" name="printerName"></select>
                    </div>
                    <div class="form-group checkbox-group">
                        <input type="checkbox" id="fullscreen" name="fullscreen">
                        <label for="fullscreen" data-text-key="text_settings_fullscreen_label">Vollbildmodus</label>
                    </div>
                    <button type="submit" data-text-key="text_settings_save_btn">Speichern</button>
                </form>
            </div>
        </div>
    </div>
    <script src="{{ url_for('static', filename='js/main.js') }}"></script>
</body>
</html>
EOF
#-----------------------
#Layout HTML
cat << 'EOF' > templates/layout_editor.html
<!DOCTYPE html>
<html lang="de">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Layout Editor</title>
    <link rel="stylesheet" href="{{ url_for('static', filename='css/layout_editor.css') }}">
</head>
<body>
    <div id="editor-container">
        <div id="toolbar">
            <h2>Layout Editor</h2>
            
            <div id="view-controls" class="controls-group">
                <label>Ansicht:</label>
                <button id="zoom-out-btn" title="Herauszoomen">-</button>
                <button id="zoom-in-btn" title="Heranzoomen">+</button>
                <button id="zoom-reset-btn" title="Originalgröße">100%</button>
                <button id="fit-to-view-btn" title="An Ansicht anpassen">Anpassen</button>
            </div>

            <div class="controls">
                <!-- NEU: Zwei getrennte Buttons für Foto-Slots -->
                <button id="add-portrait-slot-btn">Hochformat-Slot +</button>
                <button id="add-landscape-slot-btn">Querformat-Slot +</button>
                <button id="add-text-btn">Text hinzufügen</button>
                <button id="upload-image-btn">Sticker/Bild hochladen</button>
                <input type="file" id="image-upload-input" class="hidden" accept="image/png, image/jpeg, image/gif">
                <button id="save-layout-btn" class="primary-btn">Layout Speichern</button>
                <a href="/" class="button-link">Zurück zur Fotobox</a>
            </div>
        </div>

        <div id="load-template-bar">
            <label for="existing-layouts">Vorlage laden/bearbeiten:</label>
            <select id="existing-layouts">
                <option value="">-- Neues leeres Layout --</option>
            </select>
        </div>

        <div id="editor-main">
            <div id="canvas-container">
                <div id="canvas">
                    <!-- Elemente werden hier von JS eingefügt -->
                </div>
            </div>

            <div id="properties-panel">
                <h3>Eigenschaften</h3>
                <div id="canvas-properties" class="property-group">
                    <h4>Leinwand</h4>
                    <label>Breite (px): <input type="number" id="canvas-width"></label>
                    <label>Höhe (px): <input type="number" id="canvas-height"></label>
                    <label>Hintergrund: <input type="color" id="canvas-bgcolor"></label>
                    <div class="layout-presets">
                        <button id="set-portrait-btn">Hochformat (600x900)</button>
                        <button id="set-landscape-btn">Querformat (900x600)</button>
                    </div>
                </div>
                <div id="element-properties" class="property-group">
                    <h4>Ausgewähltes Element</h4>
                    <div id="common-props">
                        <label>X-Position: <input type="number" id="el-x"></label>
                        <label>Y-Position: <input type="number" id="el-y"></label>
                        <label>Breite: <input type="number" id="el-width"></label>
                        <label>Höhe: <input type="number" id="el-height"></label>
                    </div>
                    <div id="text-props" class="property-group">
                        <label>Text: <input type="text" id="el-text-content"></label>
                        <label>Schriftgröße: <input type="number" id="el-font-size"></label>
                        <label>Farbe: <input type="color" id="el-font-color"></label>
                    </div>
                    <div id="image-props" class="property-group">
                        <label>Ebene:
                            <select id="el-image-layer">
                                <option value="top">Über den Fotos</option>
                                <option value="bottom">Unter den Fotos</option>
                            </select>
                        </label>
                    </div>
                    <button id="delete-element-btn">Element löschen</button>
                </div>
                <div id="no-element-selected" class="property-group">
                    <p>Kein Element ausgewählt.</p>
                    <p>Klicke auf ein Element auf der Leinwand, um es zu bearbeiten.</p>
                </div>
            </div>
        </div>
    </div>
    <script src="{{ url_for('static', filename='js/layout_editor.js') }}"></script>
</body>
</html>
EOF

#----------------------
#TextEditor HTML
cat << 'EOF' > templates/text_editor.html
<!DOCTYPE html>
<html lang="de">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Text-Editor - Raspi Photobox</title>
    <!-- Wir verwenden das gleiche CSS wie für die Einstellungen -->
    <link rel="stylesheet" href="{{ url_for('static', filename='css/style.css') }}">
    <link rel="stylesheet" href="{{ url_for('static', filename='css/text_editor.css') }}">
</head>
<body>
    <div class="editor-container">
        <h1>Text-Editor</h1>
        <p>Hier können Sie alle für den Benutzer sichtbaren Texte anpassen. Platzhalter wie <code>{key}</code> oder <code>{s}</code> werden automatisch ersetzt.</p>

        <form id="text-editor-form">
            <hr class="divider">
            <h3>Haupt-Ansicht & Workflow</h3>
            <div class="form-group">
                <label for="text_start_instruction">Start-Anleitung</label>
                <input type="text" id="text_start_instruction" name="text_start_instruction">
                <small>Platzhalter: <code>{key}</code> (Auslöser-Taste)</small>
            
            </div>
            <div class="form-group">
                <label for="text_review_instruction">Anleitung (Druckvorschau)</label>
                <input type="text" id="text_review_instruction" name="text_review_instruction">
                <small>Platzhalter: <code>{key}</code> (Druck-Taste), <code>{s}</code> (Sekunden bis Abbruch)</small>
            </div>
             <div class="form-group">
                <label for="text_capture_progress">Fortschrittsanzeige bei Serienaufnahme</label>
                <input type="text" id="text_capture_progress" name="text_capture_progress">
                <small>Platzhalter: <code>{x}</code> (aktuelles Bild), <code>{y}</code> (Bilder gesamt)</small>
            </div>
            <div class="form-group">
                <label for="text_processing">Verarbeitungstext</label>
                <input type="text" id="text_processing" name="text_processing">
            </div>
             <div class="form-group">
                <label for="text_printing">Drucktext</label>
                <input type="text" id="text_printing" name="text_printing">
            </div>

            <hr class="divider">
            <h3>Einstellungs-Fenster</h3>
            <div class="form-group">
                <label for="text_settings_title">Titel</label>
                <input type="text" id="text_settings_title" name="text_settings_title">
            </div>
             <div class="form-group">
                <label for="text_settings_layout_editor_btn">Button "Layout Editor"</label>
                <input type="text" id="text_settings_layout_editor_btn" name="text_settings_layout_editor_btn">
            </div>
            <div class="form-group">
                <label for="text_settings_text_editor_btn">Button "Text-Editor"</label>
                <input type="text" id="text_settings_text_editor_btn" name="text_settings_text_editor_btn">
            </div>
            <div class="form-group">
                <label for="text_settings_trigger_key_label">Label "Auslöser-Taste"</label>
                <input type="text" id="text_settings_trigger_key_label" name="text_settings_trigger_key_label">
            </div>
            <div class="form-group">
                <label for="text_settings_countdown_label">Label "Countdown"</label>
                <input type="text" id="text_settings_countdown_label" name="text_settings_countdown_label">
            </div>
            <div class="form-group">
                <label for="text_settings_layout_template_label">Label "Layout-Vorlage"</label>
                <input type="text" id="text_settings_layout_template_label" name="text_settings_layout_template_label">
            </div>
             <div class="form-group">
                <label for="text_settings_orientation_label">Label "Anzeige-Modus"</label>
                <input type="text" id="text_settings_orientation_label" name="text_settings_orientation_label">
            </div>
             <div class="form-group">
                <label for="text_settings_portrait_pos_label">Label "Position der Anleitung"</label>
                <input type="text" id="text_settings_portrait_pos_label" name="text_settings_portrait_pos_label">
            </div>
            <div class="form-group">
                <label for="text_settings_rotate_final_label">Label "Finales Bild drehen"</label>
                <input type="text" id="text_settings_rotate_final_label" name="text_settings_rotate_final_label">
            </div>
            <div class="form-group">
                <label for="text_settings_camera_label">Label "Kamera"</label>
                <input type="text" id="text_settings_camera_label" name="text_settings_camera_label">
            </div>
             <div class="form-group">
                <label for="text_settings_printer_label">Label "Drucker"</label>
                <input type="text" id="text_settings_printer_label" name="text_settings_printer_label">
            </div>
             <div class="form-group">
                <label for="text_settings_fullscreen_label">Label "Vollbildmodus"</label>
                <input type="text" id="text_settings_fullscreen_label" name="text_settings_fullscreen_label">
            </div>
            <div class="form-group">
                <label for="text_settings_save_btn">Button "Speichern"</label>
                <input type="text" id="text_settings_save_btn" name="text_settings_save_btn">
            </div>

            <div class="button-group">
                 <a href="/" id="back-link" class="button-link">Zurück zur Fotobox</a>
                 <button type="submit">Alle Texte speichern</button>
            </div>
        </form>
    </div>
    <script src="{{ url_for('static', filename='js/text_editor.js') }}"></script>
</body>
</html>
EOF

cat << 'EOF' > templates/download.html
<!DOCTYPE html>
<html lang="de">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Dein Foto</title>
    <style>
        body { margin: 0; padding: 20px; box-sizing: border-box; display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 100vh; background-color: #2c3e50; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; text-align: center; }
        h1 { color: #ecf0f1; margin-bottom: 20px; }
        img { max-width: 90%; max-height: 70vh; border-radius: 12px; box-shadow: 0 10px 30px rgba(0,0,0,0.3); margin-bottom: 30px; }
        .download-btn { display: inline-block; padding: 15px 40px; font-size: 1.2em; font-weight: bold; color: white; background-color: #3498db; border: none; border-radius: 8px; text-decoration: none; transition: background-color 0.3s, transform 0.2s; cursor: pointer; }
        .download-btn:hover { background-color: #2980b9; transform: scale(1.05); }

        /* NEU: Stil für die Bestätigungsnachricht */
        #confirmation-message {
            color: #2ecc71; /* Helles Grün */
            font-weight: bold;
            margin-top: 15px;
            opacity: 0; /* Standardmäßig unsichtbar */
            transition: opacity 0.5s;
        }
    </style>
</head>
<body>
    <h1>Dein Foto</h1>
    
    <img src="/latest-image?t={{ timestamp }}" alt="Dein Photobox-Foto">
    
    <!-- MODIFIZIERT: Der Link hat jetzt eine ID bekommen -->
    <a href="/latest-image" class="download-btn" id="downloadButton" download="photobox-foto.jpg">
        Jetzt Herunterladen
    </a>

    <!-- NEU: Platzhalter für die Nachricht -->
    <p id="confirmation-message">Download wurde gestartet!</p>

    <!-- NEU: Ein kleiner JavaScript-Block, um die Nachricht anzuzeigen -->
    <script>
        // Finde den Download-Button und die Nachricht im Dokument
        const downloadBtn = document.getElementById('downloadButton');
        const message = document.getElementById('confirmation-message');

        // Füge einen Event-Listener hinzu, der auf einen Klick wartet
        downloadBtn.addEventListener('click', () => {
            // Wenn geklickt wird, ändere die Deckkraft der Nachricht auf 1, um sie sichtbar zu machen
            message.style.opacity = '1';

            // Optional: Ändere den Text des Buttons nach dem Klick
            downloadBtn.textContent = 'Heruntergeladen!';

            // Optional: Verhindere, dass der Button mehrmals geklickt wird
            // (nicht zwingend nötig, da der Download bereits gestartet ist)
            downloadBtn.style.pointerEvents = 'none';
            downloadBtn.style.backgroundColor = '#2980b9';
        });
    </script>

</body>
</html>
EOF

# NEU: CSS- und JS-Dateien mit Platzhalter-Inhalt erstellen
echo -e "${YELLOW}   ... erstelle CSS-Dateien...${NC}"
cat << 'EOF' > static/css/style.css
:root {
    --primary-color: #1a1a1a; --secondary-color: #2b2b2b; --accent-color: #00aaff;
    --text-color: #f0f0f0; --font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
}
body, html {
    margin: 0; padding: 0; height: 100%; width: 100%;
    background-color: var(--primary-color); color: var(--text-color);
    font-family: var(--font-family); overflow: hidden;
}
#photobox-app {
    position: relative; width: 100%; height: 100%;
    display: flex; justify-content: center; align-items: center;
}
.screen {
    width: 100%; height: 100%; position: absolute; top: 0; left: 0;
    display: flex; flex-direction: column; justify-content: center; align-items: center;
    transition: opacity 0.5s ease, visibility 0.5s;
    overflow: hidden;
}
.screen.hidden { opacity: 0; visibility: hidden; pointer-events: none; }

#live-video { width: 100%; height: 100%; object-fit: cover; }

#review-screen {
    flex-direction: row;
    justify-content: center;
    align-items: center;
    gap: 40px;
}
#review-image {
    object-fit: contain;
    /* Im Querformat darf das Bild den QR-Code nicht überlappen */
    max-width: 80%;
    max-height: 90vh;
    border-radius: 8px;
    transform: none;
}
#photobox-app.portrait-mode #review-image {
    width: 100vh;
    height: 100vw;
    max-width: none; /* Wichtig, um die Drehung nicht einzuschränken */
}
#photobox-app.portrait-mode.pos-left #review-image {
    transform: rotate(90deg);
}
#photobox-app.portrait-mode.pos-right #review-image {
    transform: rotate(-90deg);
}


/* Symmetrisches Layout für Overlays im Hochformat */
.instructions, #capture-progress {
    background-color: rgba(0, 0, 0, 0.8); padding: 15px 25px;
    border-radius: 25px; font-size: 1.6em; text-shadow: 0 0 8px rgba(0,0,0,0.9);
    position: absolute; white-space: nowrap; z-index: 5;
    top: 50%;
    opacity: 0;
    transition: opacity 0.5s ease-in-out;
}
.instructions.visible, #capture-progress.visible {
    opacity: 1;
}

#photobox-app.landscape-mode .instructions { bottom: 25px; top: auto; left: 50%; transform: translateX(-50%); }
#photobox-app.landscape-mode #capture-progress { top: 30px; left: 50%; transform: translateX(-50%); }
#photobox-app.portrait-mode.pos-left .instructions { left: 30px; transform: translateY(-50%) rotate(90deg); }
#photobox-app.portrait-mode.pos-left #capture-progress { right: 30px; transform: translateY(-50%) rotate(90deg); }
#photobox-app.portrait-mode.pos-right .instructions { right: 30px; transform: translateY(-50%) rotate(-90deg); }
#photobox-app.portrait-mode.pos-right #capture-progress { left: 30px; transform: translateY(-50%) rotate(-90deg); }

#countdown-overlay {
    position: absolute; top: 50%; left: 50%;
    font-weight: bold; color: white; text-shadow: 0 0 20px black; z-index: 10;
    transform: translate(-50%, -50%);
}
#photobox-app.landscape-mode #countdown-overlay:not(.static-message) { font-size: 20vw; animation: countdown-zoom-landscape 1s infinite; }
@keyframes countdown-zoom-landscape {
    from { transform: translate(-50%, -50%) scale(1); }
    to { transform: translate(-50%, -50%) scale(1.5); opacity: 0; }
}
#photobox-app.portrait-mode.pos-left #countdown-overlay:not(.static-message) { font-size: 30vw; animation: countdown-zoom-portrait-left 1s infinite; }
@keyframes countdown-zoom-portrait-left {
    from { transform: translate(-50%, -50%) rotate(90deg) scale(1); }
    to { transform: translate(-50%, -50%) rotate(90deg) scale(1.5); opacity: 0; }
}
#photobox-app.portrait-mode.pos-right #countdown-overlay:not(.static-message) { font-size: 30vw; animation: countdown-zoom-portrait-right 1s infinite; }
@keyframes countdown-zoom-portrait-right {
    from { transform: translate(-50%, -50%) rotate(-90deg) scale(1); }
    to { transform: translate(-50%, -50%) rotate(-90deg) scale(1.5); opacity: 0; }
}
#countdown-overlay.static-message {
    animation: none !important;
}
#photobox-app.landscape-mode #countdown-overlay.static-message { font-size: 5vw; }
#photobox-app.portrait-mode.pos-left #countdown-overlay.static-message { font-size: 8vw; transform: translate(-50%, -50%) rotate(90deg); }
#photobox-app.portrait-mode.pos-right #countdown-overlay.static-message { font-size: 8vw; transform: translate(-50%, -50%) rotate(-90deg); }

#flash-overlay { position: absolute; top: 0; left: 0; width: 100%; height: 100%; background-color: white; z-index: 20; }
#settings-icon{position:absolute;top:20px;right:20px;font-size:2em;cursor:pointer;z-index:100;transition:transform .3s ease}#settings-icon:hover{transform:rotate(45deg)}#settings-modal{position:fixed;top:0;left:0;width:100%;height:100%;background-color:rgba(0,0,0,.7);display:flex;justify-content:center;align-items:center;z-index:99;backdrop-filter:blur(5px)}.modal-content{background-color:var(--secondary-color);padding:20px 40px 30px;border-radius:15px;width:90%;max-width:500px;position:relative;box-shadow:0 5px 25px rgba(0,0,0,.5);max-height:90vh;overflow-y:auto;text-align:center}.close-button{position:absolute;top:15px;right:20px;font-size:2em;font-weight:700;cursor:pointer}.form-group{margin-bottom:20px;text-align:left}.form-group label{display:block;margin-bottom:8px;font-weight:700}.form-group.checkbox-group{display:flex;align-items:center;gap:10px}.form-group.checkbox-group label{margin-bottom:0;font-weight:400}.form-group input[type=text],.form-group input[type=number],.form-group select{width:100%;box-sizing:border-box;padding:10px;border-radius:5px;border:1px solid #555;background-color:var(--primary-color);color:var(--text-color);font-size:1em}#settings-form button,.button-link{width:100%;padding:12px;background-color:var(--accent-color);color:#fff;border:none;border-radius:5px;font-size:1.1em;cursor:pointer;transition:background-color .3s;display:inline-block;text-decoration:none;box-sizing:border-box;text-align:center}#settings-form button:hover,.button-link:hover{background-color:#0088cc}.divider{border:none;height:1px;background-color:#444;margin:25px 0}
.hidden{display:none!important}



#qr-code-container {
    position: absolute;
    z-index: 10;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    color: var(--text-color);
    padding: 15px;
    background-color: rgba(0, 0, 0, 0.5);
    border-radius: 10px;
    transition: opacity 0.5s;
    transform: none; /* Standardmäßig keine Transformation */
}
#qr-code-container h3 {
    margin: 0 0 10px 0;
    font-size: 1.2em;
    font-weight: bold;
}
#qrcode {
    border: 5px solid white;
    background: white;
    border-radius: 5px;
    line-height: 0;
}

/* Position Querformat: rechts oben (ist perfekt) */
#photobox-app.landscape-mode #qr-code-container {
    top: 10px;    /* Geändert von 20px */
    right: 10px;   /* Geändert von 20px */
    transform: none; /* Keine Drehung */
}

/* Position Hochformat, Anleitung links -> QR-Code RECHTS, näher am Rand */
#photobox-app.portrait-mode.pos-left #qr-code-container {
    top: 10px;     /* Geändert von 20px */
    right: -30px;    /* Geändert von 20px */
    transform-origin: top left; /* Drehe um die obere linke Ecke */
    transform: rotate(90deg);
}

/* Position Hochformat, Anleitung rechts -> QR-Code LINKS, näher am Rand */
#photobox-app.portrait-mode.pos-right #qr-code-container {
    top: 10px;     /* Geändert von 20px */
    left: -30px;     /* Geändert von 20px */
    transform-origin: top right; /* Drehe um die obere rechte Ecke */
    transform: rotate(-90deg);
}


.blink { animation: blink-animation 1s infinite; }
@keyframes blink-animation {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.3; }
}
EOF
cat << 'EOF' > static/css/layout_editor.css
:root {
    --primary-color: #1a1a1a;
    --secondary-color: #2b2b2b;
    --tertiary-color: #3c3c3c;
    --accent-color: #00aaff;
    --accent-color-hover: #0095dd;
    --danger-color: #d9534f;
    --danger-color-hover: #c9302c;
    --text-color: #f0f0f0;
    --font-family: 'Segoe UI', system-ui, sans-serif;
    --border-color: #444;
}

body, html {
    margin: 0; padding: 0; height: 100%; width: 100%;
    background-color: var(--primary-color);
    color: var(--text-color);
    font-family: var(--font-family);
    overflow: hidden;
}

body.is-dragging, body.is-dragging * { user-select: none; }
#editor-container { display: flex; flex-direction: column; height: 100vh; }
#toolbar {
    background-color: var(--secondary-color); padding: 12px 25px;
    display: flex; justify-content: space-between; align-items: center;
    border-bottom: 1px solid var(--border-color); flex-wrap: wrap; gap: 20px;
}
#toolbar h2 { margin: 0; font-weight: 600; flex-shrink: 0; }
#toolbar .controls { display: flex; align-items: center; margin-left: auto; gap: 10px; }
#toolbar .controls button, #toolbar .controls .button-link {
    padding: 8px 16px; font-size: 0.9em; border: 1px solid var(--border-color);
    background-color: var(--tertiary-color); color: var(--text-color); border-radius: 5px; cursor: pointer;
    transition: all 0.2s ease; text-decoration: none;
}
#toolbar .controls button:hover, #toolbar .controls .button-link:hover { background-color: var(--accent-color-hover); border-color: var(--accent-color-hover); color: white; }
#toolbar .controls .primary-btn { background-color: var(--accent-color); border-color: var(--accent-color); color: white; }
.controls-group { display: flex; align-items: center; gap: 8px; padding: 5px 10px; background-color: var(--primary-color); border-radius: 6px; }
.controls-group label { font-weight: 600; font-size: 0.9em; color: #ccc; }
.controls-group button { background-color: var(--tertiary-color); border: 1px solid var(--border-color); color: var(--text-color); border-radius: 4px; padding: 4px 10px; cursor: pointer; font-weight: bold; }
.controls-group button:hover { background-color: #4a4a4a; }
#load-template-bar { background-color: var(--secondary-color); padding: 10px 25px; display: flex; align-items: center; gap: 15px; border-bottom: 1px solid var(--border-color); }
#load-template-bar label { font-weight: 600; }
#load-template-bar select { flex-grow: 1; padding: 8px; background-color: var(--primary-color); color: var(--text-color); border: 1px solid var(--border-color); border-radius: 5px; }
#editor-main { display: flex; flex-grow: 1; overflow: hidden; }
#canvas-container { flex-grow: 1; padding: 30px; background-color: #111; overflow: auto; display: flex; justify-content: center; align-items: center; }
#canvas { position: relative; box-shadow: 0 10px 30px rgba(0,0,0,0.5); background-color: white; flex-shrink: 0; transform-origin: center; transition: transform 0.2s ease; }
.canvas-element { position: absolute; cursor: grab; border: 2px dashed transparent; box-sizing: border-box; transition: border-color 0.2s ease; }
.canvas-element:hover { border-color: #f0ad4e; }
.canvas-element.selected { border: 2px solid var(--accent-color); z-index: 10; }
.photo-slot { background-color: #e0e0e0; display: flex; justify-content: center; align-items: center; color: #555; font-size: 1.2em; font-weight: bold; }
/* NEU: Visuelle Unterscheidung der Slot-Typen */
.photo-slot.portrait::after { content: "H"; }
.photo-slot.landscape::after { content: "Q"; }
.text-element { background-color: rgba(0, 170, 255, 0.1); padding: 5px; display: flex; align-items: center; justify-content: center; text-align: center; overflow: hidden; white-space: nowrap; }
.image-element { background-color: transparent; border-style: dashed !important; }
.image-element img { width: 100%; height: 100%; object-fit: contain; pointer-events: none; }
.resize-handle { position: absolute; width: 10px; height: 10px; background-color: var(--accent-color); border: 1px solid white; border-radius: 50%; z-index: 11; }
.resize-handle.br { bottom: -6px; right: -6px; cursor: nwse-resize; }
.resize-handle.bl { bottom: -6px; left: -6px; cursor: nesw-resize; }
.resize-handle.tr { top: -6px; right: -6px; cursor: nesw-resize; }
.resize-handle.tl { top: -6px; left: -6px; cursor: nwse-resize; }
#properties-panel { width: 320px; flex-shrink: 0; background-color: var(--secondary-color); padding: 25px; overflow-y: auto; border-left: 1px solid var(--border-color); }
.property-group { border-bottom: 1px solid var(--border-color); transition: opacity 0.3s ease, max-height 0.4s ease, padding 0.3s ease, margin-bottom 0.3s ease; overflow: hidden; max-height: 0; opacity: 0; padding: 0 10px; margin-bottom: 0; }
.property-group.active { max-height: 800px; opacity: 1; padding: 20px 0; margin-bottom: 25px; }
#text-props, #image-props { border-bottom: none; }
.property-group:last-child { border-bottom: none; }
#properties-panel h3 { margin: 0 0 25px 0; font-size: 1.5em; font-weight: 600; text-align: center; }
#properties-panel h4 { margin-top: 0; margin-bottom: 20px; color: var(--accent-color); border-bottom: 1px solid var(--border-color); padding-bottom: 10px; }
#properties-panel label { display: block; margin-bottom: 15px; font-size: 0.9em; color: #ccc; }
#properties-panel input, #properties-panel select { width: 100%; box-sizing: border-box; padding: 10px; border-radius: 5px; border: 1px solid var(--border-color); background-color: var(--tertiary-color); color: var(--text-color); margin-top: 5px; font-size: 1em; }
#properties-panel input:focus, #properties-panel select:focus { outline: none; border-color: var(--accent-color); box-shadow: 0 0 0 3px rgba(0, 170, 255, 0.3); }
#properties-panel input[type="color"] { padding: 2px; height: 40px; }
.layout-presets { display: flex; gap: 10px; margin-top: 15px; }
.layout-presets button { flex: 1; padding: 8px; font-size: 0.9em; background-color: var(--tertiary-color); color: var(--text-color); border: 1px solid var(--border-color); border-radius: 5px; cursor: pointer; transition: background-color 0.2s ease; }
.layout-presets button:hover { background-color: #4a4a4a; }
#delete-element-btn { width: 100%; padding: 10px; background-color: var(--danger-color); color: white; border: none; border-radius: 5px; cursor: pointer; margin-top: 10px; transition: background-color 0.2s ease; }
#delete-element-btn:hover { background-color: var(--danger-color-hover); }
.hidden { display: none !important; }
EOF
cat << 'EOF' > static/css/text_editor.css
body { overflow-y: auto; }
        .editor-container {
            background-color: var(--secondary-color);
            padding: 20px 40px 30px;
            border-radius: 15px;
            width: 90%;
            max-width: 700px; /* Etwas breiter für mehr Platz */
            margin: 40px auto;
            box-shadow: 0 5px 25px rgba(0,0,0,.5);
        }
        .editor-container h1 { text-align: center; }
        .form-group small {
            display: block;
            margin-top: -5px;
            margin-bottom: 10px;
            color: #aaa;
            font-size: 0.85em;
        }
        .button-group {
            display: flex;
            gap: 15px;
            margin-top: 30px;
        }
        #back-link {
             background-color: #555;
        }
         #back-link:hover {
             background-color: #777;
        }
EOF
echo -e "${YELLOW}   ... erstelle JavaScript-Dateien...${NC}"
cat << 'EOF' > static/js/main.js
document.addEventListener('DOMContentLoaded', () => {
    // MODIFIZIERT: Neue DOM-Elemente für den QR-Code hinzugefügt
    const DOM = {
        app: document.getElementById('photobox-app'),
        liveViewScreen: document.getElementById('live-view-screen'),
        reviewScreen: document.getElementById('review-screen'),
        liveVideo: document.getElementById('live-video'),
        reviewImage: document.getElementById('review-image'),
        countdownOverlay: document.getElementById('countdown-overlay'),
        flashOverlay: document.getElementById('flash-overlay'),
        settingsIcon: document.getElementById('settings-icon'),
        settingsModal: document.getElementById('settings-modal'),
        closeSettings: document.getElementById('close-settings'),
        settingsForm: document.getElementById('settings-form'),
        captureProgress: document.getElementById('capture-progress'),
        portraitOptions: document.getElementById('portrait-options'),
        liveInstructions: document.querySelector('#live-view-screen .instructions'),
        reviewInstructions: document.querySelector('#review-screen .instructions'),
        // NEU: Elemente für QR-Code
        qrCodeContainer: document.getElementById('qr-code-container'),
        qrcode: document.getElementById('qrcode')
    };
    
    // MODIFIZIERT: 'publicUrl' zum Speichern des ngrok-Links hinzugefügt
    let appState = {
        currentScreen: 'live', settings: {}, lastPhotoFilename: null,
        activeStream: null, photosToTake: 0, capturedPhotos: [], isCapturing: false,
        loadingInterval: null,
        reviewTimeout: null,
        publicUrl: null // NEU
    };

    // MODIFIZIERT: `initializeApp` holt die publicUrl und ruft die neue Review-Funktion auf
    async function initializeApp() {
        // NEU: öffentliche URL aus dem HTML-Attribut auslesen
        appState.publicUrl = DOM.app.dataset.publicUrl;

        await loadInitialData();
        updateDynamicTexts();
        const urlParams = new URLSearchParams(window.location.search);
        if (urlParams.has('review')) {
            const filename = urlParams.get('review');
            // MODIFIZIERT: Ruft die neue Funktion auf, die auch den QR-Code anzeigt
            showReviewScreenWithQRCode(filename);
        } else {
            await startCamera(appState.settings.selectedCamera);
        }
        setupEventListeners();
        applyOrientation();
        await updateLayoutInfo();
        applyFullscreen(appState.settings.fullscreen);
        
        setTimeout(() => {
            document.querySelectorAll('.instructions').forEach(el => el.classList.add('visible'));
        }, 100);
    }
    
    async function loadInitialData() {
        const sysInfoRes = await fetch('/api/system-info');
        const sysInfo = await sysInfoRes.json();
        const settingsRes = await fetch('/api/settings');
        appState.settings = await settingsRes.json();
        populateSettingsForm(appState.settings, sysInfo);
    }
    
    async function updateLayoutInfo() {
        if (!appState.settings.selectedLayout) return;
        try {
            const res = await fetch(`/api/layout/${appState.settings.selectedLayout}`);
            if (!res.ok) throw new Error('Layout not found');
            const layoutData = await res.json();
            appState.photosToTake = layoutData.photo_slots.length;
        } catch (e) {
            console.error("Layout-Datei konnte nicht geladen werden:", e);
            appState.photosToTake = 1;
        }
    }

    function applyOrientation() {
        const app = DOM.app;
        app.className = '';
        if (appState.settings.orientation === 'portrait') {
            app.classList.add('portrait-mode', `pos-${appState.settings.instructionsPosition}`);
            DOM.portraitOptions.style.display = 'block';
        } else {
            app.classList.add('landscape-mode');
            DOM.portraitOptions.style.display = 'none';
        }
        updateInstructionTexts();
    }

    // Deine funktionierende Kamera-Funktion wird 1:1 beibehalten
    async function startCamera(cameraIndex) {
        if (appState.activeStream) appState.activeStream.getTracks().forEach(track => track.stop());
        try {
            const devices = await navigator.mediaDevices.enumerateDevices();
            const videoDevices = devices.filter(device => device.kind === 'videoinput');
            if (videoDevices.length === 0) throw new Error("Keine Kameras gefunden.");
            const constraints = { video: { deviceId: { exact: cameraIndex }, width: { ideal: 1920 }, height: { ideal: 1080 } } };
            const stream = await navigator.mediaDevices.getUserMedia(constraints);
            DOM.liveVideo.srcObject = stream;
            DOM.liveVideo.play();
            appState.activeStream = stream;
        } catch (err) {
            try {
                const stream = await navigator.mediaDevices.getUserMedia({ video: { width: { ideal: 1920 }, height: { ideal: 1080 } }});
                DOM.liveVideo.srcObject = stream;
                DOM.liveVideo.play();
                appState.activeStream = stream;
            } catch (fallbackErr) {
                alert(`Kamera konnte nicht gestartet werden: ${fallbackErr.message}`);
            }
        }
    }
    
    function switchScreen(screenName) {
        document.querySelectorAll('.screen').forEach(s => s.classList.add('hidden'));
        if (DOM[`${screenName}Screen`]) DOM[`${screenName}Screen`].classList.remove('hidden');
        appState.currentScreen = screenName;
    }

    // NEU: Funktion, die Bild und QR-Code anzeigt
    function showReviewScreenWithQRCode(filename) {
        appState.lastPhotoFilename = filename;
        DOM.reviewImage.src = `/photos/${filename}?t=${new Date().getTime()}`;

        DOM.qrcode.innerHTML = '';
        if (appState.publicUrl && appState.publicUrl !== "None" && appState.publicUrl !== 'None') {
            const shareUrl = `${appState.publicUrl}/latest`;
            const qr = qrcode(0, 'L');
            qr.addData(shareUrl);
qr.make();
            DOM.qrcode.innerHTML = qr.createImgTag(8, 8);
            DOM.qrCodeContainer.classList.remove('hidden');
        } else {
            DOM.qrCodeContainer.classList.add('hidden');
        }

        switchScreen('review');
        startReviewTimer(); // Startet den neuen Countdown
    }

    // MODIFIZIERT: startReviewTimer wurde an die neue Logik angepasst
    function startReviewTimer() {
        if (appState.reviewTimeout) clearInterval(appState.reviewTimeout);
        const overlay = DOM.reviewInstructions;
        let count = appState.settings.reviewTime;
        
        const updateTimerText = () => {
            // MODIFIZIERT: Verwendet jetzt den Text aus den Einstellungen
            overlay.innerHTML = appState.settings.text_review_instruction
                .replace('{key}', `<strong>${appState.settings.triggerKey}</strong>`)
                .replace('{s}', `<strong>${count}</strong>`);
        };

        updateTimerText();
        overlay.classList.remove('hidden');
        overlay.classList.add('visible');
        
        appState.reviewTimeout = setInterval(() => {
            count--;
            updateTimerText();
            if (count <= 0) {
                clearInterval(appState.reviewTimeout);
                discardPhoto(); 
            }
        }, 1000);
    }

    function startCaptureSequence() {
        if (appState.isCapturing || appState.photosToTake === 0) return;
        appState.isCapturing = true;
        appState.capturedPhotos = [];
        DOM.liveInstructions.style.display = 'none';
        takeNextPhoto();
    }

    function takeNextPhoto() {
    const photoNumber = appState.capturedPhotos.length + 1;
    if (photoNumber > appState.photosToTake) {
        processAllPhotos();
        return;
    }

    DOM.captureProgress.textContent = appState.settings.text_capture_progress.replace('{x}', photoNumber).replace('{y}', appState.photosToTake);
    DOM.captureProgress.classList.remove('hidden');
    DOM.captureProgress.classList.add('visible');

    let count = appState.settings.countdownTime;
    DOM.countdownOverlay.textContent = count;
    DOM.countdownOverlay.classList.remove('hidden', 'static-message');

    const countdownInterval = setInterval(() => {
        count--;
        if (count > 0) {
            DOM.countdownOverlay.textContent = count;
        } else {
            clearInterval(countdownInterval);
            DOM.countdownOverlay.classList.add('hidden');
            // Anstatt direkt captureSinglePhoto aufzurufen, starten wir jetzt den robusten Versuch.
            robustCaptureSinglePhoto(); 
        }
    }, 1000);
}

function robustCaptureSinglePhoto(retryCount = 0) {
    // Nach 15 Versuchen (~1.5 Sekunden) geben wir auf.
    if (retryCount >= 15) {
        alert("Kamera reagiert nicht. Aufnahme wird abgebrochen.");
        window.location.reload();
        return;
    }

    const canvas = document.createElement('canvas');
    if (DOM.liveVideo.videoWidth > 0 && DOM.liveVideo.videoHeight > 0) {
        // ERFOLG!
        DOM.flashOverlay.classList.remove('hidden');

        setTimeout(() => {
            canvas.width = DOM.liveVideo.videoWidth;
            canvas.height = DOM.liveVideo.videoHeight;
            const ctx = canvas.getContext('2d');
            ctx.drawImage(DOM.liveVideo, 0, 0, canvas.width, canvas.height);
            appState.capturedPhotos.push(canvas.toDataURL('image/jpeg'));
            
            DOM.flashOverlay.classList.add('hidden');
            DOM.captureProgress.classList.add('hidden');
            setTimeout(takeNextPhoto, 1500); // Weiter zum nächsten Bild
        }, 500); // Dein Blitz-Timing

    } else {
        // FEHLER -> Wiederholen
        // Wir warten 100ms und versuchen es erneut.
        setTimeout(() => robustCaptureSinglePhoto(retryCount + 1), 100);
    }
}

    async function processAllPhotos() {
        const baseProcessingText = appState.settings.text_processing;
        DOM.countdownOverlay.textContent = baseProcessingText + ".";
        DOM.countdownOverlay.classList.add('static-message');
        DOM.countdownOverlay.classList.remove('hidden');
        
        let dotCount = 1;
        appState.loadingInterval = setInterval(() => {
            dotCount = (dotCount % 3) + 1;
            DOM.countdownOverlay.textContent = baseProcessingText + ".".repeat(dotCount);
        }, 500);

        try {
            const response = await fetch('/api/process-photo', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    imageDataUrls: appState.capturedPhotos,
                    instructionsPosition: appState.settings.instructionsPosition
                })
            });
            const data = await response.json();
            if (data.status === 'success') {
                window.location.href = `${window.location.pathname}?review=${data.filename}`;
            } else {
                throw new Error(data.message);
            }
        } catch (error) {
            alert(`Fotos konnten nicht verarbeitet werden: ${error.message}`);
            window.location.reload();
        } finally {
            if (appState.loadingInterval) clearInterval(appState.loadingInterval);
        }
    }

    // MODIFIZIERT: Druckt das Foto und geht dann zurück
    async function confirmAndPrintPhoto() {
        if (appState.reviewTimeout) clearInterval(appState.reviewTimeout);
        if (!appState.lastPhotoFilename) return;
        
        DOM.reviewInstructions.innerHTML = `<span class="blink">${appState.settings.text_printing}</span>`;

        try {
            await fetch('/api/print-photo', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ filename: appState.lastPhotoFilename })
            });
            setTimeout(() => window.location.href = window.location.pathname, 3000);
        } catch (error) {
            alert('Senden des Druckbefehls ist fehlgeschlagen.');
            window.location.href = window.location.pathname;
        }
    }

    function discardPhoto() {
        if (appState.reviewTimeout) clearInterval(appState.reviewTimeout);
        window.location.href = window.location.pathname;
    }

    async function saveSettings(e) {
        e.preventDefault();
        const formData = new FormData(DOM.settingsForm);
        const newSettings = {};
        for(const [key, value] of formData.entries()) {
            if (DOM.settingsForm[key].type === 'checkbox') {
                newSettings[key] = DOM.settingsForm[key].checked;
            } else if (DOM.settingsForm[key].type === 'number') {
                newSettings[key] = parseInt(value, 10);
            } else {
                newSettings[key] = value;
            }
        }

        const settingsToSave = { ...appState.settings, ...newSettings };

        await fetch('/api/settings', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(settingsToSave)
        });
        alert("Einstellungen gespeichert. Die Seite wird neu geladen.");
        window.location.reload();
    }

    function populateSettingsForm(settings, sysInfo) {
        const form = DOM.settingsForm;
        form.triggerKey.value = settings.triggerKey;
        form.countdownTime.value = settings.countdownTime;
        form.reviewTime.value = settings.reviewTime;
        form.fullscreen.checked = settings.fullscreen;
        form.orientation.value = settings.orientation;
        form.instructionsPosition.value = settings.instructionsPosition;
        form.rotateInPortrait.checked = settings.rotateInPortrait;
        
        const cameraSelect = form.selectedCamera;
        cameraSelect.innerHTML = '';
        sysInfo.cameras.forEach(cam => cameraSelect.add(new Option(cam.name, cam.id)));
        cameraSelect.value = settings.selectedCamera;
        const printerSelect = form.printerName;
        printerSelect.innerHTML = '';
        sysInfo.printers.forEach(p => printerSelect.add(new Option(p, p)));
        printerSelect.value = settings.printerName;
        const layoutSelect = form.selectedLayout;
        layoutSelect.innerHTML = '';
        sysInfo.layouts.forEach(l => layoutSelect.add(new Option(l.name, l.id)));
        layoutSelect.value = settings.selectedLayout;
    }
    
    function updateDynamicTexts() {
        document.querySelectorAll('[data-text-key]').forEach(element => {
            const key = element.getAttribute('data-text-key');
            if (appState.settings[key]) {
                element.innerHTML = appState.settings[key];
            }
        });
        updateInstructionTexts();
    }

    function toggleSettingsModal(show) {
        DOM.settingsModal.classList.toggle('hidden', !show);
        appState.currentScreen = show ? 'settings' : 'live';
    }

    function updateInstructionTexts() {
        const { settings } = appState;
        DOM.liveInstructions.innerHTML = settings.text_start_instruction.replace('{key}', `<strong>${settings.triggerKey}</strong>`);
    }

    function applyFullscreen(enable) {
        if (enable && !document.fullscreenElement) {
            DOM.app.requestFullscreen().catch(err => console.error(err));
        } else if (!enable && document.fullscreenElement) {
            document.exitFullscreen();
        }
    }
    
    // MODIFIZIERT: Event-Listener ruft jetzt `confirmAndPrintPhoto` auf
    function setupEventListeners() {
        window.addEventListener('keydown', (e) => {
            if (e.target.tagName === 'INPUT' || e.target.tagName === 'SELECT') {
                 if (e.target.id === 'triggerKey') {
                    e.preventDefault(); e.target.value = e.key;
                }
                return;
            }
            if (appState.isCapturing || appState.currentScreen === 'settings') return;

            if (e.key === appState.settings.triggerKey) {
                e.preventDefault();
                if (appState.currentScreen === 'live') {
                    startCaptureSequence();
                } else if (appState.currentScreen === 'review') {
                    // Statt 'discardPhoto' wird jetzt der Druck ausgelöst
                    confirmAndPrintPhoto(); 
                }
            }
        });
        DOM.settingsIcon.addEventListener('click', () => toggleSettingsModal(true));
        DOM.closeSettings.addEventListener('click', () => toggleSettingsModal(false));
        DOM.settingsModal.addEventListener('click', (e) => { if (e.target === DOM.settingsModal) toggleSettingsModal(false); });
        DOM.settingsForm.addEventListener('submit', saveSettings);
        DOM.settingsForm.selectedLayout.addEventListener('change', updateLayoutInfo);
        DOM.settingsForm.orientation.addEventListener('change', () => {
            appState.settings.orientation = DOM.settingsForm.orientation.value;
            applyOrientation();
        });
    }

    initializeApp();
});
EOF
cat << 'EOF' > static/js/layout_editor.js
document.addEventListener('DOMContentLoaded', () => {
    // --- DOM-ELEMENTE ---
    const DOM = {
        canvas: document.getElementById('canvas'),
        canvasContainer: document.getElementById('canvas-container'),
        // NEU: Geteilte Buttons für Foto-Slots
        addPortraitSlotBtn: document.getElementById('add-portrait-slot-btn'),
        addLandscapeSlotBtn: document.getElementById('add-landscape-slot-btn'),
        addTextBtn: document.getElementById('add-text-btn'),
        uploadImageBtn: document.getElementById('upload-image-btn'),
        imageUploadInput: document.getElementById('image-upload-input'),
        saveLayoutBtn: document.getElementById('save-layout-btn'),
        propertiesPanel: document.getElementById('properties-panel'),
        canvasProperties: document.getElementById('canvas-properties'),
        elementProperties: document.getElementById('element-properties'),
        noElementSelected: document.getElementById('no-element-selected'),
        textProps: document.getElementById('text-props'),
        imageProps: document.getElementById('image-props'),
        deleteElementBtn: document.getElementById('delete-element-btn'),
        existingLayoutsSelect: document.getElementById('existing-layouts'),
        zoomInBtn: document.getElementById('zoom-in-btn'),
        zoomOutBtn: document.getElementById('zoom-out-btn'),
        zoomResetBtn: document.getElementById('zoom-reset-btn'),
        fitToViewBtn: document.getElementById('fit-to-view-btn'),
        setPortraitBtn: document.getElementById('set-portrait-btn'),
        setLandscapeBtn: document.getElementById('set-landscape-btn'),
        inputs: {
            canvasWidth: document.getElementById('canvas-width'), canvasHeight: document.getElementById('canvas-height'),
            canvasBgcolor: document.getElementById('canvas-bgcolor'), elX: document.getElementById('el-x'),
            elY: document.getElementById('el-y'), elWidth: document.getElementById('el-width'),
            elHeight: document.getElementById('el-height'), elTextContent: document.getElementById('el-text-content'),
            elFontSize: document.getElementById('el-font-size'), elFontColor: document.getElementById('el-font-color'),
            elImageLayer: document.getElementById('el-image-layer'),
        }
    };

    // --- ZUSTAND (STATE) ---
    let state = {
        canvas: { width: 600, height: 900, background_color: '#ffffff' },
        photo_slots: [],
        static_elements: [],
        selectedElementId: null,
        view: { scale: 1.0 }
    };
    
    let dragAction = { active: false };

    // --- KERNFUNKTIONEN ---
    function updateUI() {
        renderCanvas();
        updatePropertiesPanel();
        applyCanvasTransform();
    }
    
    function applyCanvasTransform() {
        DOM.canvas.style.transform = `scale(${state.view.scale})`;
    }
    
    function renderCanvas() {
        DOM.canvas.style.width = `${state.canvas.width}px`;
        DOM.canvas.style.height = `${state.canvas.height}px`;
        DOM.canvas.style.backgroundColor = state.canvas.background_color;
        DOM.canvas.innerHTML = ''; 

        const renderElement = (data, type, index) => {
            const el = document.createElement('div');
            const id = `${type}-${index}`;
            el.className = 'canvas-element';
            el.dataset.id = id;
            el.style.left = `${data.x}px`;
            el.style.top = `${data.y}px`;
            el.style.width = `${data.width}px`;
            el.style.height = `${data.height}px`;

            el.addEventListener('mousedown', e => onMouseDown(e, 'drag', el));

            if (type === 'photo') {
                el.classList.add('photo-slot');
                // NEU: Fügt eine Klasse für die Ausrichtung hinzu, um sie visuell zu unterscheiden
                el.classList.add(data.orientation); 
                el.textContent = `Foto ${index + 1}`;
            } else if (data.type === 'text') {
                el.classList.add('text-element');
                el.style.fontSize = `${data.font_size}px`;
                el.style.color = data.font_color;
                el.textContent = data.content;
            } else if (data.type === 'image') {
                el.classList.add('image-element');
                const img = document.createElement('img');
                img.src = data.src;
                el.appendChild(img);
            }

            if (id === state.selectedElementId) {
                el.classList.add('selected');
                ['tl', 'tr', 'bl', 'br'].forEach(pos => {
                    const handle = document.createElement('div');
                    handle.className = `resize-handle ${pos}`;
                    handle.addEventListener('mousedown', e => onMouseDown(e, pos, el));
                    el.appendChild(handle);
                });
            }
            DOM.canvas.appendChild(el);
        };

        (state.photo_slots || []).forEach((slot, i) => renderElement(slot, 'photo', i));
        (state.static_elements || []).forEach((el, i) => renderElement(el, 'static', i));
    }
    
    function updatePropertiesPanel() {
        DOM.canvasProperties.classList.add('active');
        DOM.inputs.canvasWidth.value = state.canvas.width;
        DOM.inputs.canvasHeight.value = state.canvas.height;
        DOM.inputs.canvasBgcolor.value = state.canvas.background_color;

        const hasSelection = !!state.selectedElementId;
        DOM.elementProperties.classList.toggle('active', hasSelection);
        DOM.noElementSelected.classList.toggle('active', !hasSelection);

        DOM.textProps.classList.remove('active');
        DOM.imageProps.classList.remove('active');

        if (hasSelection) {
            const elementData = getSelectedElementData();
            if (!elementData) return;

            DOM.inputs.elX.value = elementData.x;
            DOM.inputs.elY.value = elementData.y;
            DOM.inputs.elWidth.value = elementData.width;
            DOM.inputs.elHeight.value = elementData.height;

            if (elementData.type === 'text') {
                DOM.textProps.classList.add('active');
                DOM.inputs.elTextContent.value = elementData.content;
                DOM.inputs.elFontSize.value = elementData.font_size;
                DOM.inputs.elFontColor.value = elementData.font_color;
            } else if (elementData.type === 'image') {
                DOM.imageProps.classList.add('active');
                DOM.inputs.elImageLayer.value = elementData.layer || 'top';
            }
        }
    }

    // --- EVENT-HANDLER ---
    function onMouseDown(e, type, element) {
        e.preventDefault();
        e.stopPropagation();
        selectElement(element.dataset.id);
        dragAction = { active: true, type: type, element: element, startX: e.clientX, startY: e.clientY, elStartX: parseInt(element.style.left), elStartY: parseInt(element.style.top), elStartW: parseInt(element.style.width), elStartH: parseInt(element.style.height), scale: state.view.scale };
        document.addEventListener('mousemove', onMouseMove);
        document.addEventListener('mouseup', onMouseUp);
        document.body.classList.add('is-dragging');
        document.body.style.cursor = getComputedStyle(e.target).cursor;
    }

    function onMouseMove(e) {
        if (!dragAction.active) return;
        e.preventDefault();
        const dx = (e.clientX - dragAction.startX) / dragAction.scale;
        const dy = (e.clientY - dragAction.startY) / dragAction.scale;
        const el = dragAction.element;
        let newX = dragAction.elStartX, newY = dragAction.elStartY, newW = dragAction.elStartW, newH = dragAction.elStartH;
        if (dragAction.type === 'drag') {
            newX = dragAction.elStartX + dx;
            newY = dragAction.elStartY + dy;
        } else {
            if (dragAction.type.includes('r')) newW = Math.max(20, dragAction.elStartW + dx);
            if (dragAction.type.includes('b')) newH = Math.max(20, dragAction.elStartH + dy);
            if (dragAction.type.includes('l')) { newW = Math.max(20, dragAction.elStartW - dx); newX = dragAction.elStartX + dx; }
            if (dragAction.type.includes('t')) { newH = Math.max(20, dragAction.elStartH - dy); newY = dragAction.elStartY + dy; }
        }
        el.style.left = `${newX}px`; el.style.top = `${newY}px`; el.style.width = `${newW}px`; el.style.height = `${newH}px`;
        updatePropertiesPanelFromDOM(el);
    }
    
    function onMouseUp() {
        if (!dragAction.active) return;
        updateStateFromElementDOM(dragAction.element);
        dragAction = { active: false };
        document.removeEventListener('mousemove', onMouseMove);
        document.removeEventListener('mouseup', onMouseUp);
        document.body.classList.remove('is-dragging');
        document.body.style.cursor = '';
    }

    // --- HILFSFUNKTIONEN & AKTIONEN ---
    const getSelectedElementData = () => { if (!state.selectedElementId) return null; const [type, indexStr] = state.selectedElementId.split('-'); const index = parseInt(indexStr); return type === 'photo' ? state.photo_slots[index] : state.static_elements[index]; };
    function updateStateFromElementDOM(el) { if (!el || !el.dataset.id) return; const data = getSelectedElementData(); if (data) { data.x = parseInt(el.style.left) || 0; data.y = parseInt(el.style.top) || 0; data.width = parseInt(el.style.width) || 0; data.height = parseInt(el.style.height) || 0; } }
    function updatePropertiesPanelFromDOM(el) { if (!state.selectedElementId) return; DOM.inputs.elX.value = parseInt(el.style.left); DOM.inputs.elY.value = parseInt(el.style.top); DOM.inputs.elWidth.value = parseInt(el.style.width); DOM.inputs.elHeight.value = parseInt(el.style.height); }
    function selectElement(id) { if (state.selectedElementId === id) return; state.selectedElementId = id; updateUI(); }
    function initNewLayout() { state.canvas = { width: 600, height: 900, background_color: '#ffffff' }; state.photo_slots = []; state.static_elements = []; state.selectedElementId = null; DOM.existingLayoutsSelect.value = ""; updateUI(); fitCanvasToView(); }
    
    // --- GEÄNDERT: addElement kann jetzt die Ausrichtung für Fotos speichern ---
    function addElement(type, options={}) {
        const defaultPosition = { x: 50, y: 50 };
        let newElement = { ...defaultPosition };
        let id;
        if (type === 'photo') {
            // Setzt Standard-Dimensionen basierend auf der Ausrichtung
            const dims = options.orientation === 'portrait' ? { width: 150, height: 200 } : { width: 200, height: 150 };
            Object.assign(newElement, { type: 'photo', ...dims, ...options });
            state.photo_slots.push(newElement);
            id = `photo-${state.photo_slots.length - 1}`;
        } else {
            if (type === 'text') { Object.assign(newElement, { type: 'text', width: 200, height: 50, content: 'Neuer Text', font_size: 24, font_color: '#333333', anchor: 'la', ...options }); }
            else if (type === 'image') { Object.assign(newElement, { type: 'image', width: 150, height: 150, layer: 'top', ...options }); }
            state.static_elements.push(newElement);
            id = `static-${state.static_elements.length - 1}`;
        }
        selectElement(id);
    }
    
    function deleteSelectedElement() { if (!state.selectedElementId) return; const [type, indexStr] = state.selectedElementId.split('-'); const index = parseInt(indexStr); if (type === 'photo') { state.photo_slots.splice(index, 1); } else if (type === 'static') { state.static_elements.splice(index, 1); } selectElement(null); }
    async function handleImageUpload(e) { const file = e.target.files[0]; if (!file) return; const formData = new FormData(); formData.append('file', file); document.body.style.cursor = 'wait'; try { const response = await fetch('/api/upload-image', { method: 'POST', body: formData }); const result = await response.json(); if (result.status !== 'success') throw new Error(result.message); addElement('image', { src: result.url }); } catch (error) { alert(`Fehler beim Upload: ${error.message}`); } finally { document.body.style.cursor = ''; DOM.imageUploadInput.value = ""; } }
    async function saveLayout() { const selectedOption = DOM.existingLayoutsSelect.options[DOM.existingLayoutsSelect.selectedIndex]; const defaultName = selectedOption.value ? selectedOption.text : "Mein neues Layout"; const layoutName = prompt("Unter welchem Namen soll das Layout gespeichert werden?", defaultName); if (!layoutName) return; const { selectedElementId, view, ...layoutData } = state; const layoutToSave = { ...layoutData, name: layoutName }; try { const response = await fetch('/api/layouts', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name: layoutName, layout: layoutToSave }) }); const result = await response.json(); if (result.status === 'success') { alert('Layout erfolgreich gespeichert! Die Liste wird aktualisiert.'); loadLayoutList(); } else { throw new Error(result.message); } } catch (error) { alert(`Fehler beim Speichern: ${error.message}`); } }
    async function loadLayout(filename) { if (!filename) { initNewLayout(); return; } try { const response = await fetch(`/api/layout/${filename}?t=${new Date().getTime()}`); if (!response.ok) throw new Error(`Serverantwort: ${response.statusText}`); const data = await response.json(); state.canvas = data.canvas || { width: 600, height: 900, background_color: '#ffffff' }; state.photo_slots = data.photo_slots || []; state.static_elements = data.static_elements || []; state.selectedElementId = null; updateUI(); fitCanvasToView(); } catch (error) { alert(`Fehler beim Laden des Layouts: ${error.message}`); initNewLayout(); } }
    async function loadLayoutList() { try { const response = await fetch('/api/system-info'); const data = await response.json(); const currentVal = DOM.existingLayoutsSelect.value; DOM.existingLayoutsSelect.innerHTML = '<option value="">-- Neues leeres Layout --</option>'; data.layouts.forEach(layout => DOM.existingLayoutsSelect.add(new Option(layout.name, layout.id))); DOM.existingLayoutsSelect.value = currentVal; } catch (error) { console.error("Konnte Layout-Liste nicht laden:", error); } }
    function fitCanvasToView() { const container = DOM.canvasContainer; const padding = 60; const containerW = container.clientWidth - padding; const containerH = container.clientHeight - padding; const canvasW = state.canvas.width; const canvasH = state.canvas.height; const scaleX = containerW / canvasW; const scaleY = containerH / canvasH; state.view.scale = Math.min(scaleX, scaleY, 1); applyCanvasTransform(); }

    function setupEventListeners() {
        // --- NEU: Event-Listener für die neuen Buttons ---
        DOM.addPortraitSlotBtn.addEventListener('click', () => addElement('photo', { orientation: 'portrait' }));
        DOM.addLandscapeSlotBtn.addEventListener('click', () => addElement('photo', { orientation: 'landscape' }));

        DOM.addTextBtn.addEventListener('click', () => addElement('text'));
        DOM.deleteElementBtn.addEventListener('click', deleteSelectedElement);
        DOM.uploadImageBtn.addEventListener('click', () => DOM.imageUploadInput.click());
        DOM.imageUploadInput.addEventListener('change', handleImageUpload);
        DOM.saveLayoutBtn.addEventListener('click', saveLayout);
        DOM.existingLayoutsSelect.addEventListener('change', (e) => loadLayout(e.target.value));
        DOM.canvasContainer.addEventListener('mousedown', (e) => { if (e.target === DOM.canvasContainer || e.target === DOM.canvas) { selectElement(null); } });
        
        DOM.propertiesPanel.addEventListener('input', (e) => {
            if (!e.target.id) return;
            const value = e.target.type === 'number' ? parseInt(e.target.value) || 0 : e.target.value;
            if (e.target.id.startsWith('canvas-')) {
                const key = e.target.id.replace('canvas-', '').replace('bgcolor', 'background_color');
                state.canvas[key] = value;
            } else if (state.selectedElementId) {
                const elementData = getSelectedElementData();
                if (elementData) {
                    const propertyMap = { 'el-x': 'x', 'el-y': 'y', 'el-width': 'width', 'el-height': 'height', 'el-text-content': 'content', 'el-font-size': 'font_size', 'el-font-color': 'font_color', 'el-image-layer': 'layer' };
                    const key = propertyMap[e.target.id];
                    if (key) elementData[key] = value;
                }
            }
            updateUI();
        });

        DOM.zoomInBtn.addEventListener('click', () => { state.view.scale = Math.min(3, state.view.scale + 0.1); applyCanvasTransform(); });
        DOM.zoomOutBtn.addEventListener('click', () => { state.view.scale = Math.max(0.1, state.view.scale - 0.1); applyCanvasTransform(); });
        DOM.zoomResetBtn.addEventListener('click', () => { state.view.scale = 1.0; applyCanvasTransform(); });
        DOM.fitToViewBtn.addEventListener('click', fitCanvasToView);
        DOM.setPortraitBtn.addEventListener('click', () => { state.canvas.width = 600; state.canvas.height = 900; updateUI(); });
        DOM.setLandscapeBtn.addEventListener('click', () => { state.canvas.width = 900; state.canvas.height = 600; updateUI(); });
        window.addEventListener('resize', fitCanvasToView);
    }

    async function initialize() {
        await loadLayoutList();
        initNewLayout();
        setupEventListeners();
    }
    
    initialize();
});
EOF
cat << 'EOF' > static/js/text_editor.js
document.addEventListener('DOMContentLoaded', () => {
    const form = document.getElementById('text-editor-form');
    let currentSettings = {};

    // 1. Lade die aktuellen Einstellungen (inklusive aller Texte) vom Server
    async function loadTexts() {
        try {
            const response = await fetch('/api/settings');
            if (!response.ok) throw new Error('Could not fetch settings.');
            currentSettings = await response.json();
            
            // Fülle jedes Formularfeld mit dem entsprechenden Wert aus den Settings
            for (const key in currentSettings) {
                if (key.startsWith('text_')) {
                    const inputElement = document.getElementById(key);
                    if (inputElement) {
                        inputElement.value = currentSettings[key];
                    }
                }
            }
        } catch (error) {
            console.error('Fehler beim Laden der Texte:', error);
            alert('Die Texteinstellungen konnten nicht geladen werden.');
        }
    }

    // 2. Speichere die neuen Texte
    async function saveTexts(e) {
        e.preventDefault();
        
        // Erstelle ein neues Objekt mit den aktualisierten Textwerten aus dem Formular
        const updatedTexts = {};
        const formData = new FormData(form);
        for (const [key, value] of formData.entries()) {
            updatedTexts[key] = value;
        }

        // Führe die alten Einstellungen und die neuen Texte zusammen,
        // damit keine anderen Einstellungen verloren gehen.
        const settingsToSave = { ...currentSettings, ...updatedTexts };
        
        try {
            const response = await fetch('/api/settings', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(settingsToSave)
            });
            
            if (!response.ok) throw new Error('Failed to save settings.');

            alert('Texte erfolgreich gespeichert!');
            // Optional: Zurück zur Hauptseite navigieren
            // window.location.href = '/';
        } catch (error) {
            console.error('Fehler beim Speichern der Texte:', error);
            alert('Die Texte konnten nicht gespeichert werden.');
        }
    }

    // Event Listener für das Formular
    form.addEventListener('submit', saveTexts);

    // Initiales Laden der Texte, wenn die Seite aufgerufen wird
    loadTexts();
});
EOF

echo -e "${GREEN}Anwendungsdateien erfolgreich erstellt.${NC}"
echo -e "${YELLOW}   ... erstelle ngrok-Konfigurationsskript...${NC}"
cat << 'EOF' > configure_ngrok.sh
#!/bin/bash
# Dieses Skript konfiguriert den ngrok Authtoken für die Photobox.

PROJECT_PATH_CONFIG="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PYNGROK_EXEC="$PROJECT_PATH_CONFIG/.venv/bin/pyngrok"

echo "--- ngrok Konfiguration ---"
echo "Um eine stabile URL für die QR-Code-Freigabe zu erhalten, wird ein ngrok Authtoken benötigt."
echo "1. Logge dich auf https://dashboard.ngrok.com ein."
echo "2. Kopiere deinen Authtoken von der Seite 'Your Authtoken'."
echo ""

if ! command -v "$PYNGROK_EXEC" &> /dev/null; then
    echo "Fehler: pyngrok wurde nicht im Verzeichnis .venv gefunden. Bitte führe das Haupt-Setup erneut aus."
    exit 1
fi

read -p "Bitte füge deinen ngrok Authtoken hier ein und drücke Enter: " authtoken

if [ -z "$authtoken" ]; then
    echo "Kein Token eingegeben. Konfiguration abgebrochen."
    exit 1
fi

echo "Konfiguriere ngrok mit deinem Token..."
"$PYNGROK_EXEC" authtoken "$authtoken"

echo ""
echo "Erfolg! Dein ngrok Authtoken wurde gespeichert."
echo "Die Photobox wird beim nächsten Start eine stabile URL verwenden."
EOF
chmod +x configure_ngrok.sh

echo -e "${GREEN}Anwendungsdateien erfolgreich erstellt.${NC}"


# --- Schritt 4: Python-Pakete definieren ---
echo -e "\n${YELLOW}--> Schritt 4: Definiere Python-Pakete in requirements.txt...${NC}"
cat << EOF > requirements.txt
flask
opencv-python
numpy
Pillow
pyngrok
EOF
echo -e "${GREEN}requirements.txt erstellt.${NC}"

# --- Schritt 5: Virtuelle Umgebung einrichten ---
echo -e "\n${YELLOW}--> Schritt 5: Richte virtuelle Python-Umgebung ein...${NC}"
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
deactivate
echo -e "${GREEN}Virtuelle Umgebung und Python-Pakete erfolgreich installiert.${NC}"


# --- Schritt 6: Autostart einrichten ---
echo -e "\n${YELLOW}--> Schritt 6: Richte den automatischen Start ein...${NC}"
# A) Backend-Service (systemd)
echo -e "${YELLOW}   ... erstelle systemd-Service für das Backend...${NC}"
cat << EOF > /tmp/$SERVICE_NAME.service
[Unit]
Description=Photobox Backend Service
After=network.target
[Service]
User=$CURRENT_USER
WorkingDirectory=$PROJECT_PATH
ExecStart=$PROJECT_PATH/.venv/bin/python app.py
Restart=always
[Install]
WantedBy=multi-user.target
EOF
sudo mv /tmp/$SERVICE_NAME.service /etc/systemd/system/$SERVICE_NAME.service
sudo systemctl daemon-reload
sudo systemctl enable $SERVICE_NAME.service
echo -e "${GREEN}   Backend-Service '$SERVICE_NAME.service' erstellt und aktiviert.${NC}"

# B) Frontend Kiosk (Desktop Autostart)
echo -e "${YELLOW}   ... erstelle Autostart-Datei für den Browser im Kiosk-Modus...${NC}"
mkdir -p "$HOME/.config/autostart"
cat << EOF > "$HOME/.config/autostart/photobox-kiosk.desktop"
[Desktop Entry]
Type=Application
Name=Photobox Kiosk
Comment=Starts the Photobox frontend in fullscreen
Exec=bash -c "sleep 10 && chromium --kiosk --disable-infobars --noerrdialogs --disable-session-crashed-bubble http://localhost:5000"
EOF
echo -e "${GREEN}   Browser-Autostart erstellt.${NC}"

# --- Fertig! ---
echo -e "\n\n${GREEN}======================================================"
echo -e "      SETUP ABGESCHLOSSEN!"
echo -e "======================================================${NC}"
echo -e "\nDie grundlegende Installation ist fertig. Es fehlt nur noch ein optionaler Schritt."

echo -e "\n${YELLOW}NÄCHSTE SCHRITTE:${NC}"
echo -e "1. ${YELLOW}(Punkt 1 - 2: Optional, aber empfohlen für QR-Codes)${NC} Konfiguriere deinen ngrok-Schlüssel."
echo -e "   Führe dazu die folgenden Befehle aus:"
echo -e "   ${GREEN}cd ~/Photobox${NC}"
echo -e "   ${GREEN}source .venv/bin/activate${NC}"
echo -e "   ${GREEN}python app.py${NC}"
echo -e "2. Drücke nach erfolgreichem ausführen [STR + C], um das Script zu beenden."
echo -e "   Führe nun diesen Befehl aus:"
echo -e "   ${GREEN}bash $PROJECT_PATH/configure_ngrok.sh${NC}"
echo ""
echo -e "3. Starte den Raspberry Pi neu, um die Photobox im Kiosk-Modus zu starten:"
echo -e "   ${GREEN}sudo reboot${NC}"

echo -e "\n${YELLOW}FEHLERSUCHE & WARTUNG:${NC}"
echo -e " - Um den Autostart des Browsers zu deaktivieren:"
echo -e "   ${GREEN}rm $HOME/.config/autostart/photobox-kiosk.desktop${NC}"
echo -e " - Um den Autostart des Backends zu deaktivieren:"
echo -e "   ${GREEN}sudo systemctl disable --now $SERVICE_NAME.service${NC}"
echo -e " - Um die Log-Ausgaben des Backends anzusehen:"
echo -e "   ${GREEN}journalctl -u $SERVICE_NAME.service -f${NC}\n"
