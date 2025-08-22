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