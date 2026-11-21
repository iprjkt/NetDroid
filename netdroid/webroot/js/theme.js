/* ==========================================================================
   NetDroid — Material You Dynamic Color Engine & Wallpaper Studio
   ========================================================================== */

(function (global) {
    'use strict';

    var STORAGE_KEY = 'netdroid_theme_v1';

    var PRESETS = {
        aurora:   { name: 'Aurora',   cls: 'preset-aurora',   accent: '#a8c7fa' },
        ocean:    { name: 'Oceanic',  cls: 'preset-ocean',    accent: '#4dd0e1' },
        sunset:   { name: 'Sunset',   cls: 'preset-sunset',   accent: '#ffb4a9' },
        forest:   { name: 'Forest',   cls: 'preset-forest',   accent: '#6dd58c' },
        obsidian: { name: 'Obsidian', cls: 'preset-obsidian', accent: '#9fa8da' },
        sakura:   { name: 'Sakura',   cls: 'preset-sakura',   accent: '#f48fb1' }
    };

    var ACCENT_SWATCHES = [
        '#a8c7fa', '#4dd0e1', '#6dd58c', '#ffd54f',
        '#ff8a65', '#f48fb1', '#ce93d8'
    ];

    var state = {
        mode: 'dark',
        preset: 'aurora',
        useCustomBg: false,
        autoExtract: true,
        accent: '#a8c7fa',
        blur: 12,
        dim: 42,
        cardOpacity: 76,
        bgUpdatedAt: 0,
        customBgExists: false
    };

    var saveTimer = null;
    var apiRef = null;
    var onPaletteChangeCb = null;

    /* -------------------- Color Math (RGB <-> HSL -> M3 Tones) -------------------- */
    function hexToRgb(hex) {
        var clean = String(hex || '#a8c7fa').replace('#', '');
        if (clean.length === 3) {
            clean = clean[0] + clean[0] + clean[1] + clean[1] + clean[2] + clean[2];
        }
        var n = parseInt(clean, 16);
        if (isNaN(n)) return { r: 168, g: 199, b: 250 };
        return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255 };
    }

    function rgbToHex(r, g, b) {
        var toHex = function (v) {
            var h = Math.max(0, Math.min(255, Math.round(v))).toString(16);
            return h.length === 1 ? '0' + h : h;
        };
        return '#' + toHex(r) + toHex(g) + toHex(b);
    }

    function rgbToHsl(r, g, b) {
        r /= 255; g /= 255; b /= 255;
        var max = Math.max(r, g, b), min = Math.min(r, g, b);
        var h = 0, s = 0, l = (max + min) / 2;
        if (max !== min) {
            var d = max - min;
            s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
            switch (max) {
                case r: h = (g - b) / d + (g < b ? 6 : 0); break;
                case g: h = (b - r) / d + 2; break;
                case b: h = (r - g) / d + 4; break;
            }
            h *= 60;
        }
        return { h: h, s: s * 100, l: l * 100 };
    }

    function hslToRgb(h, s, l) {
        h = ((h % 360) + 360) % 360;
        s = Math.max(0, Math.min(100, s)) / 100;
        l = Math.max(0, Math.min(100, l)) / 100;
        var c = (1 - Math.abs(2 * l - 1)) * s;
        var x = c * (1 - Math.abs(((h / 60) % 2) - 1));
        var m = l - c / 2;
        var r = 0, g = 0, b = 0;
        if (h < 60) { r = c; g = x; }
        else if (h < 120) { r = x; g = c; }
        else if (h < 180) { g = c; b = x; }
        else if (h < 240) { g = x; b = c; }
        else if (h < 300) { r = x; b = c; }
        else { r = c; b = x; }
        return {
            r: Math.round((r + m) * 255),
            g: Math.round((g + m) * 255),
            b: Math.round((b + m) * 255)
        };
    }

    function hslHex(h, s, l) {
        var rgb = hslToRgb(h, s, l);
        return rgbToHex(rgb.r, rgb.g, rgb.b);
    }

    // Generate full Material 3 tonal palette from seed hex color
    function applyTonalPalette(seedHex, mode) {
        var rgb = hexToRgb(seedHex);
        var hsl = rgbToHsl(rgb.r, rgb.g, rgb.b);
        var h = hsl.h;
        var sat = Math.max(38, Math.min(86, hsl.s || 65));
        var hSec = (h + 24) % 360;
        var hTer = (h + 62) % 360;

        var root = document.documentElement;
        root.setAttribute('data-theme', mode === 'light' ? 'light' : 'dark');

        var primaryRgb, surfRgb, elevRgb;

        if (mode === 'light') {
            var p = hslToRgb(h, sat, 38);
            primaryRgb = p;
            surfRgb = hslToRgb(h, 18, 97);
            elevRgb = hslToRgb(h, 24, 99);

            root.style.setProperty('--md-primary', rgbToHex(p.r, p.g, p.b));
            root.style.setProperty('--md-on-primary', '#ffffff');
            root.style.setProperty('--md-primary-container', hslHex(h, Math.min(85, sat + 8), 89));
            root.style.setProperty('--md-on-primary-container', hslHex(h, sat, 17));

            root.style.setProperty('--md-secondary', hslHex(hSec, sat * 0.65, 36));
            root.style.setProperty('--md-on-secondary', '#ffffff');
            root.style.setProperty('--md-secondary-container', hslHex(hSec, sat * 0.65, 88));
            root.style.setProperty('--md-on-secondary-container', hslHex(hSec, sat * 0.7, 16));

            root.style.setProperty('--md-tertiary', hslHex(hTer, sat * 0.85, 42));
            root.style.setProperty('--md-on-tertiary', '#ffffff');
            root.style.setProperty('--md-tertiary-container', hslHex(hTer, sat * 0.8, 90));
            root.style.setProperty('--md-on-tertiary-container', hslHex(hTer, sat * 0.85, 18));
        } else {
            var pDark = hslToRgb(h, Math.min(92, sat + 8), 78);
            primaryRgb = pDark;
            surfRgb = hslToRgb(h, 18, 10);
            elevRgb = hslToRgb(h, 20, 15);

            root.style.setProperty('--md-primary', rgbToHex(pDark.r, pDark.g, pDark.b));
            root.style.setProperty('--md-on-primary', hslHex(h, sat, 14));
            root.style.setProperty('--md-primary-container', hslHex(h, sat * 0.85, 27));
            root.style.setProperty('--md-on-primary-container', hslHex(h, Math.min(95, sat + 12), 90));

            root.style.setProperty('--md-secondary', hslHex(hSec, sat * 0.6, 78));
            root.style.setProperty('--md-on-secondary', hslHex(hSec, sat * 0.6, 15));
            root.style.setProperty('--md-secondary-container', hslHex(hSec, sat * 0.55, 26));
            root.style.setProperty('--md-on-secondary-container', hslHex(hSec, sat * 0.7, 90));

            root.style.setProperty('--md-tertiary', hslHex(hTer, Math.min(90, sat + 6), 80));
            root.style.setProperty('--md-on-tertiary', hslHex(hTer, sat, 16));
            root.style.setProperty('--md-tertiary-container', hslHex(hTer, sat * 0.75, 28));
            root.style.setProperty('--md-on-tertiary-container', hslHex(hTer, Math.min(92, sat + 10), 91));
        }

        root.style.setProperty('--md-primary-rgb', primaryRgb.r + ', ' + primaryRgb.g + ', ' + primaryRgb.b);
        root.style.setProperty('--md-surface-rgb', surfRgb.r + ', ' + surfRgb.g + ', ' + surfRgb.b);
        root.style.setProperty('--md-surface-elevated-rgb', elevRgb.r + ', ' + elevRgb.g + ', ' + elevRgb.b);

        if (typeof onPaletteChangeCb === 'function') {
            onPaletteChangeCb();
        }
    }

    // Extract dominant vibrant color from an HTMLImageElement using offscreen <canvas>
    function extractDominantColor(img) {
        try {
            var canvas = document.createElement('canvas');
            var size = 64;
            canvas.width = size;
            canvas.height = size;
            var ctx = canvas.getContext('2d');
            ctx.drawImage(img, 0, 0, size, size);
            var data = ctx.getImageData(0, 0, size, size).data;

            // 18 hue buckets (20 deg each) weighted by chroma & balanced lightness
            var buckets = [];
            for (var b = 0; b < 18; b++) {
                buckets.push({ weight: 0, r: 0, g: 0, b: 0 });
            }

            for (var i = 0; i < data.length; i += 4) {
                var a = data[i + 3];
                if (a < 180) continue;
                var r = data[i], g = data[i + 1], bl = data[i + 2];
                var hsl = rgbToHsl(r, g, bl);
                if (hsl.l < 12 || hsl.l > 90) continue;
                var satFactor = Math.pow(hsl.s / 100, 1.6);
                var lightFactor = 1 - Math.abs(hsl.l - 54) / 56;
                var w = Math.max(0.02, satFactor * Math.max(0.15, lightFactor));
                var idx = Math.floor(((hsl.h % 360) / 360) * 18) % 18;
                buckets[idx].weight += w;
                buckets[idx].r += r * w;
                buckets[idx].g += g * w;
                buckets[idx].b += bl * w;
            }

            var best = buckets[0];
            for (var k = 1; k < buckets.length; k++) {
                if (buckets[k].weight > best.weight) best = buckets[k];
            }
            if (best.weight <= 0.01) return '#a8c7fa';
            return rgbToHex(best.r / best.weight, best.g / best.weight, best.b / best.weight);
        } catch (e) {
            return '#a8c7fa';
        }
    }

    /* -------------------- Apply Visual State to DOM -------------------- */
    function applyVisuals() {
        var root = document.documentElement;
        root.style.setProperty('--bg-blur', state.blur + 'px');
        root.style.setProperty('--bg-dim', (state.dim / 100).toFixed(2));
        root.style.setProperty('--card-opacity', (state.cardOpacity / 100).toFixed(2));

        applyTonalPalette(state.accent, state.mode);

        var bgEl = document.getElementById('bg-wallpaper');
        if (bgEl) {
            // Clear preset classes
            Object.keys(PRESETS).forEach(function (k) {
                bgEl.classList.remove(PRESETS[k].cls);
            });

            if (state.useCustomBg && state.customBgExists) {
                if (state.customBgDataUri) {
                    bgEl.style.backgroundImage = 'url("' + state.customBgDataUri + '")';
                } else {
                    var url = '/cgi-bin/upload_bg.sh?t=' + (state.bgUpdatedAt || Date.now());
                    bgEl.style.backgroundImage = 'url("' + url + '")';
                }
            } else {
                bgEl.style.backgroundImage = '';
                var presetObj = PRESETS[state.preset] || PRESETS.aurora;
                bgEl.classList.add(presetObj.cls);
            }
        }

        syncControlsUI();
    }

    function syncControlsUI() {
        var setVal = function (id, val) {
            var el = document.getElementById(id);
            if (el) el.value = val;
        };
        var setTxt = function (id, txt) {
            var el = document.getElementById(id);
            if (el) el.textContent = txt;
        };

        setVal('slider-blur', state.blur);
        setTxt('val-blur', state.blur + 'px');
        setVal('slider-dim', state.dim);
        setTxt('val-dim', state.dim + '%');
        setVal('slider-opacity', state.cardOpacity);
        setTxt('val-opacity', state.cardOpacity + '%');

        var colorInput = document.getElementById('accent-picker');
        if (colorInput) colorInput.value = state.accent;

        // Mode buttons
        var darkBtn = document.getElementById('theme-mode-dark');
        var lightBtn = document.getElementById('theme-mode-light');
        if (darkBtn) darkBtn.classList.toggle('active', state.mode === 'dark');
        if (lightBtn) lightBtn.classList.toggle('active', state.mode === 'light');

        // Auto extract switch
        var autoSw = document.getElementById('sw-auto-extract');
        if (autoSw) autoSw.classList.toggle('on', !!state.autoExtract);

        // Preset cards active state
        document.querySelectorAll('.preset-card').forEach(function (card) {
            var p = card.getAttribute('data-preset');
            card.classList.toggle('active', !state.useCustomBg && p === state.preset);
        });

        // Swatches active state
        document.querySelectorAll('.color-swatch').forEach(function (sw) {
            var c = (sw.getAttribute('data-color') || '').toLowerCase();
            sw.classList.toggle('active', c === (state.accent || '').toLowerCase());
        });

        // Custom BG buttons visibility
        var clearBtn = document.getElementById('btn-clear-bg');
        var bgStatus = document.getElementById('custom-bg-status');
        if (clearBtn) clearBtn.style.display = state.customBgExists ? 'inline-flex' : 'none';
        if (bgStatus) {
            if (state.customBgExists && state.useCustomBg) {
                bgStatus.textContent = 'Custom wallpaper active & synced across LAN';
            } else if (state.customBgExists) {
                bgStatus.textContent = 'Custom wallpaper saved (preset currently selected)';
            } else {
                bgStatus.textContent = 'Upload an image to sync across host & LAN devices';
            }
        }
    }

    function persistLocal() {
        try {
            var copy = Object.assign({}, state);
            delete copy.customBgDataUri;
            localStorage.setItem(STORAGE_KEY, JSON.stringify(copy));
        } catch (e) {}
    }

    function persistServerDebounced() {
        persistLocal();
        if (!apiRef) return;
        clearTimeout(saveTimer);
        saveTimer = setTimeout(function () {
            apiRef.post('save_theme', {
                mode: state.mode,
                preset: state.preset,
                useCustomBg: state.useCustomBg ? 'true' : 'false',
                autoExtract: state.autoExtract ? 'true' : 'false',
                accent: state.accent,
                blur: state.blur,
                dim: state.dim,
                cardOpacity: state.cardOpacity
            }).catch(function () {});
        }, 350);
    }

    /* -------------------- Image Resize + Upload + Color Extraction -------------------- */
    function handleWallpaperFile(file, notify) {
        if (!file) return;
        var reader = new FileReader();
        reader.onload = function (ev) {
            var img = new Image();
            img.onload = function () {
                // 1. Extract vibrant Material You accent if enabled
                if (state.autoExtract) {
                    state.accent = extractDominantColor(img);
                }

                // 2. Resize & compress via offscreen <canvas> (max 1600px)
                var maxDim = 1600;
                var w = img.naturalWidth || img.width;
                var h = img.naturalHeight || img.height;
                if (w > maxDim || h > maxDim) {
                    if (w >= h) { h = Math.round(h * (maxDim / w)); w = maxDim; }
                    else { w = Math.round(w * (maxDim / h)); h = maxDim; }
                }

                var canvas = document.createElement('canvas');
                canvas.width = w;
                canvas.height = h;
                var ctx = canvas.getContext('2d');
                ctx.drawImage(img, 0, 0, w, h);

                // Prefer WebP, fallback to JPEG
                var dataUrl = canvas.toDataURL('image/webp', 0.84);
                var ext = 'webp';
                if (dataUrl.indexOf('data:image/webp') !== 0) {
                    dataUrl = canvas.toDataURL('image/jpeg', 0.85);
                    ext = 'jpg';
                }

                // Instant local preview
                state.customBgDataUri = dataUrl;
                state.customBgExists = true;
                state.useCustomBg = true;
                state.bgUpdatedAt = Math.floor(Date.now() / 1000);
                applyVisuals();

                if (!apiRef) return;
                if (notify) notify('Uploading & syncing wallpaper...', 'info');

                apiRef.uploadWallpaper(dataUrl, ext).then(function (res) {
                    if (res && res.ok) {
                        state.bgUpdatedAt = res.updated_at || Math.floor(Date.now() / 1000);
                        if (!apiRef.isKsuNative()) {
                            delete state.customBgDataUri;
                        }
                        applyVisuals();
                        persistServerDebounced();
                        if (notify) notify('Wallpaper synced & Material You palette updated!', 'success');
                    } else {
                        if (notify) notify((res && res.error) || 'Wallpaper upload failed', 'error');
                    }
                }).catch(function () {
                    if (notify) notify('Failed to upload wallpaper', 'error');
                });
            };
            img.src = ev.target.result;
        };
        reader.readAsDataURL(file);
    }

    function init(api, onPaletteChange, notify) {
        apiRef = api;
        onPaletteChangeCb = onPaletteChange;

        // Load cached local theme first for zero-flash render
        try {
            var cached = JSON.parse(localStorage.getItem(STORAGE_KEY) || 'null');
            if (cached) Object.assign(state, cached);
        } catch (e) {}
        applyVisuals();

        // Build preset cards
        var presetGrid = document.getElementById('preset-grid');
        if (presetGrid) {
            presetGrid.innerHTML = '';
            Object.keys(PRESETS).forEach(function (key) {
                var p = PRESETS[key];
                var btn = document.createElement('button');
                btn.type = 'button';
                btn.className = 'preset-card ' + p.cls;
                btn.setAttribute('data-preset', key);
                btn.innerHTML = '<span>' + p.name + '</span>';
                btn.addEventListener('click', function () {
                    state.preset = key;
                    state.useCustomBg = false;
                    if (state.autoExtract) {
                        state.accent = p.accent;
                    }
                    applyVisuals();
                    persistServerDebounced();
                });
                presetGrid.appendChild(btn);
            });
        }

        // Build manual accent color swatches
        var swatchRow = document.getElementById('accent-swatches');
        if (swatchRow) {
            swatchRow.innerHTML = '';
            ACCENT_SWATCHES.forEach(function (hex) {
                var sw = document.createElement('button');
                sw.type = 'button';
                sw.className = 'color-swatch';
                sw.style.backgroundColor = hex;
                sw.setAttribute('data-color', hex);
                sw.setAttribute('title', hex);
                sw.addEventListener('click', function () {
                    state.accent = hex;
                    applyVisuals();
                    persistServerDebounced();
                });
                swatchRow.appendChild(sw);
            });
        }

        // Wire sliders
        var bindSlider = function (id, prop) {
            var el = document.getElementById(id);
            if (!el) return;
            el.addEventListener('input', function () {
                state[prop] = Number(el.value);
                applyVisuals();
                persistServerDebounced();
            });
        };
        bindSlider('slider-blur', 'blur');
        bindSlider('slider-dim', 'dim');
        bindSlider('slider-opacity', 'cardOpacity');

        // Color picker
        var picker = document.getElementById('accent-picker');
        if (picker) {
            picker.addEventListener('input', function () {
                state.accent = picker.value;
                applyVisuals();
                persistServerDebounced();
            });
        }

        // Dark / Light toggles (both Settings & quick top-bar toggle)
        var setThemeMode = function (m) {
            state.mode = m;
            applyVisuals();
            persistServerDebounced();
        };
        var darkBtn = document.getElementById('theme-mode-dark');
        var lightBtn = document.getElementById('theme-mode-light');
        if (darkBtn) darkBtn.addEventListener('click', function () { setThemeMode('dark'); });
        if (lightBtn) lightBtn.addEventListener('click', function () { setThemeMode('light'); });

        var quickModeBtn = document.getElementById('btn-toggle-theme');
        if (quickModeBtn) {
            quickModeBtn.addEventListener('click', function () {
                setThemeMode(state.mode === 'dark' ? 'light' : 'dark');
            });
        }

        // Auto-extract switch
        var autoSw = document.getElementById('sw-auto-extract');
        if (autoSw) {
            autoSw.addEventListener('click', function () {
                state.autoExtract = !state.autoExtract;
                applyVisuals();
                persistServerDebounced();
            });
        }

        // Wallpaper upload input
        var fileInput = document.getElementById('bg-file-input');
        var uploadBtn = document.getElementById('btn-upload-bg');
        if (uploadBtn && fileInput) {
            uploadBtn.addEventListener('click', function () { fileInput.click(); });
            fileInput.addEventListener('change', function () {
                if (fileInput.files && fileInput.files[0]) {
                    handleWallpaperFile(fileInput.files[0], notify);
                    fileInput.value = '';
                }
            });
        }

        // Clear custom wallpaper
        var clearBtn = document.getElementById('btn-clear-bg');
        if (clearBtn) {
            clearBtn.addEventListener('click', function () {
                if (!apiRef) return;
                apiRef.clearWallpaper().then(function () {
                    state.customBgExists = false;
                    state.useCustomBg = false;
                    delete state.customBgDataUri;
                    applyVisuals();
                    persistServerDebounced();
                    if (notify) notify('Custom wallpaper removed', 'success');
                }).catch(function () {
                    if (notify) notify('Failed to remove wallpaper', 'error');
                });
            });
        }

        // Pull synced theme & wallpaper metadata from host server
        syncFromServer();
    }

    function syncFromServer() {
        if (!apiRef) return;
        apiRef.get('get_theme').then(function (res) {
            if (!res || !res.ok) return;
            if (res.theme) {
                state.mode = res.theme.mode || state.mode;
                state.preset = res.theme.preset || state.preset;
                state.useCustomBg = !!res.theme.useCustomBg;
                state.autoExtract = res.theme.autoExtract !== false;
                state.accent = res.theme.accent || state.accent;
                if (typeof res.theme.blur === 'number') state.blur = res.theme.blur;
                if (typeof res.theme.dim === 'number') state.dim = res.theme.dim;
                if (typeof res.theme.cardOpacity === 'number') state.cardOpacity = res.theme.cardOpacity;
            }
            if (res.custom_bg) {
                state.customBgExists = !!res.custom_bg.exists;
                state.bgUpdatedAt = res.custom_bg.updated_at || 0;
            }
            persistLocal();
            if (state.useCustomBg && state.customBgExists && apiRef.isKsuNative()) {
                apiRef.getWallpaperDataUri().then(function (r) {
                    if (r && r.exists && r.data_uri) {
                        state.customBgDataUri = r.data_uri;
                    }
                    applyVisuals();
                }).catch(applyVisuals);
            } else {
                applyVisuals();
            }
        }).catch(function () {});
    }

    global.NetDroidTheme = {
        init: init,
        syncFromServer: syncFromServer,
        getState: function () { return state; }
    };
})(window);
