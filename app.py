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
        "triggerKey": "Enter", "countdownTime": 3, "printerName": get_printers()[0] if get_printers() else "",
        "selectedLayout": "photostrip_4x1.json", "fullscreen": False, "selectedCamera": available_cams[0]['id'] if available_cams else "0",
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