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