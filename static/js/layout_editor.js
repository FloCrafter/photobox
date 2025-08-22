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