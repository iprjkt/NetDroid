/* ==========================================================================
   NetDroid — Pocket Homelab Controller
   1. SSH Server (Dropbear/OpenSSH) & Embedded Web Console
   2. LAN Shared Folder (Pocket NAS) with Chunked Streaming Upload & Offline QR
   ========================================================================== */

(function (global) {
    'use strict';

    function $(id) { return document.getElementById(id); }

    function esc(str) {
        return String(str == null ? '' : str)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;')
            .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    }

    function fmtBytes(b) {
        return global.NetDroidCharts ? global.NetDroidCharts.formatBytes(b) : (b + ' B');
    }

    function fmtTime(ts) {
        if (!ts) return '';
        var d = new Date(Number(ts) * 1000);
        return d.toLocaleDateString() + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    }

    /* ======================================================================
       Compact 100% Offline QR Code Generator (Byte Mode, EC Level L, V1-V6)
       Renders a clean crisp <svg> with zero external dependencies.
       ====================================================================== */
    var QR = (function () {
        var EXP = new Array(512), LOG = new Array(256);
        var x = 1;
        for (var i = 0; i < 255; i++) {
            EXP[i] = x; LOG[x] = i;
            x <<= 1;
            if (x & 0x100) x ^= 0x11d;
        }
        for (var j = 255; j < 512; j++) EXP[j] = EXP[j - 255];

        function gfMul(a, b) { return (a === 0 || b === 0) ? 0 : EXP[LOG[a] + LOG[b]]; }

        function rsPoly(ecLen) {
            var p = [1];
            for (var i = 0; i < ecLen; i++) {
                var next = new Array(p.length + 1).fill(0);
                for (var j = 0; j < p.length; j++) {
                    next[j] ^= p[j];
                    next[j + 1] ^= gfMul(p[j], EXP[i]);
                }
                p = next;
            }
            return p;
        }

        function rsEncode(data, ecLen) {
            var gen = rsPoly(ecLen);
            var msg = data.slice().concat(new Array(ecLen).fill(0));
            for (var i = 0; i < data.length; i++) {
                var coef = msg[i];
                if (coef !== 0) {
                    for (var j = 0; j < gen.length; j++) {
                        msg[i + j] ^= gfMul(gen[j], coef);
                    }
                }
            }
            return msg.slice(data.length);
        }

        // Version specs for EC Level L: [size, totalDataCW, ecCWPerBlock, alignCoords]
        var VERS = [
            null,
            { sz: 21, dc: 19,  ec: 7,  al: [] },
            { sz: 25, dc: 34,  ec: 10, al: [6, 18] },
            { sz: 29, dc: 55,  ec: 15, al: [6, 22] },
            { sz: 33, dc: 80,  ec: 20, al: [6, 26] },
            { sz: 37, dc: 108, ec: 26, al: [6, 30] },
            { sz: 41, dc: 136, ec: 36, al: [6, 34] }
        ];

        function makeSvg(text) {
            var bytes = [];
            for (var i = 0; i < text.length; i++) {
                var c = text.charCodeAt(i);
                if (c < 128) bytes.push(c);
                else if (c < 2048) { bytes.push(192 | (c >> 6), 128 | (c & 63)); }
                else { bytes.push(224 | (c >> 12), 128 | ((c >> 6) & 63), 128 | (c & 63)); }
            }
            var ver = 0;
            for (var v = 1; v <= 6; v++) {
                if (bytes.length + 2 <= VERS[v].dc) { ver = v; break; }
            }
            if (!ver) return '<div style="padding:12px;font-size:0.75rem;">URL too long for compact QR</div>';

            var spec = VERS[ver];
            var sz = spec.sz;
            var bits = [];
            function pushBits(val, len) {
                for (var b = len - 1; b >= 0; b--) bits.push((val >> b) & 1);
            }
            pushBits(4, 4); // Byte mode
            pushBits(bytes.length, 8);
            for (var bi = 0; bi < bytes.length; bi++) pushBits(bytes[bi], 8);
            pushBits(0, Math.min(4, spec.dc * 8 - bits.length));
            while (bits.length % 8 !== 0) bits.push(0);

            var data = [];
            for (var k = 0; k < bits.length; k += 8) {
                var bv = 0;
                for (var bb = 0; bb < 8; bb++) bv = (bv << 1) | bits[k + bb];
                data.push(bv);
            }
            var padBytes = [0xec, 0x11], pi = 0;
            while (data.length < spec.dc) { data.push(padBytes[pi % 2]); pi++; }

            var cw;
            if (ver === 6) {
                // Version 6-L uses 2 blocks of 68 data + 18 EC each
                var d1 = data.slice(0, 68), d2 = data.slice(68);
                var e1 = rsEncode(d1, 18), e2 = rsEncode(d2, 18);
                cw = [];
                for (var q = 0; q < 68; q++) { cw.push(d1[q], d2[q]); }
                for (var r = 0; r < 18; r++) { cw.push(e1[r], e2[r]); }
            } else {
                cw = data.concat(rsEncode(data, spec.ec));
            }

            var mat = [], isFunc = [];
            for (var y = 0; y < sz; y++) {
                mat.push(new Array(sz).fill(0));
                isFunc.push(new Array(sz).fill(false));
            }

            function setMod(r, c, dark) {
                if (r >= 0 && r < sz && c >= 0 && c < sz) {
                    mat[r][c] = dark ? 1 : 0;
                    isFunc[r][c] = true;
                }
            }

            function drawFinder(r0, c0) {
                for (var dr = -1; dr <= 7; dr++) {
                    for (var dc = -1; dc <= 7; dc++) {
                        var dark = (dr >= 0 && dr <= 6 && dc >= 0 && dc <= 6) &&
                            (dr === 0 || dr === 6 || dc === 0 || dc === 6 || (dr >= 2 && dr <= 4 && dc >= 2 && dc <= 4));
                        setMod(r0 + dr, c0 + dc, dark);
                    }
                }
            }
            drawFinder(0, 0);
            drawFinder(0, sz - 7);
            drawFinder(sz - 7, 0);

            // Alignment pattern
            if (spec.al.length === 2) {
                var ar = spec.al[1], ac = spec.al[1];
                for (var dr = -2; dr <= 2; dr++) {
                    for (var dc = -2; dc <= 2; dc++) {
                        setMod(ar + dr, ac + dc, Math.max(Math.abs(dr), Math.abs(dc)) !== 1);
                    }
                }
            }

            // Timing patterns & dark module
            for (var t = 8; t < sz - 8; t++) {
                setMod(6, t, t % 2 === 0);
                setMod(t, 6, t % 2 === 0);
            }
            setMod(sz - 8, 8, true);

            // Reserve format info
            for (var f = 0; f < 9; f++) {
                if (f !== 6) { isFunc[8][f] = true; isFunc[f][8] = true; }
            }
            for (var f2 = 0; f2 < 8; f2++) {
                isFunc[8][sz - 1 - f2] = true;
                isFunc[sz - 1 - f2][8] = true;
            }

            // Place data bits with mask 0 ((r + c) % 2 === 0)
            var bitIdx = 0;
            var totalBits = cw.length * 8;
            for (var col = sz - 1; col >= 1; col -= 2) {
                if (col === 6) col = 5;
                var up = (((sz - 1 - col) >> 1) % 2) === 0;
                for (var step = 0; step < sz; step++) {
                    var row = up ? (sz - 1 - step) : step;
                    for (var dx = 0; dx < 2; dx++) {
                        var cc = col - dx;
                        if (isFunc[row][cc]) continue;
                        var bit = 0;
                        if (bitIdx < totalBits) {
                            bit = (cw[bitIdx >> 3] >> (7 - (bitIdx & 7))) & 1;
                            bitIdx++;
                        }
                        if (((row + cc) & 1) === 0) bit ^= 1;
                        mat[row][cc] = bit;
                    }
                }
            }

            // Format bits for EC Level L (01) + Mask 0 (000) -> 0x77c4 (111011111000100)
            var fmt = 0x77c4;
            for (var fi = 0; fi < 15; fi++) {
                var fb = (fmt >> fi) & 1;
                if (fi < 6) mat[fi][8] = fb;
                else if (fi < 8) mat[fi + 1][8] = fb;
                else mat[sz - 15 + fi][8] = fb;

                if (fi < 8) mat[8][sz - 1 - fi] = fb;
                else if (fi < 9) mat[8][15 - fi] = fb;
                else mat[8][14 - fi] = fb;
            }

            var pad = 3;
            var vb = sz + pad * 2;
            var rects = '';
            for (var rr = 0; rr < sz; rr++) {
                for (var cc2 = 0; cc2 < sz; cc2++) {
                    if (mat[rr][cc2]) {
                        rects += '<rect x="' + (cc2 + pad) + '" y="' + (rr + pad) + '" width="1" height="1"/>';
                    }
                }
            }
            return '<svg viewBox="0 0 ' + vb + ' ' + vb + '" width="196" height="196" xmlns="http://www.w3.org/2000/svg" shape-rendering="crispEdges">' +
                '<rect width="' + vb + '" height="' + vb + '" fill="#ffffff" rx="2"/>' +
                '<g fill="#111318">' + rects + '</g></svg>';
        }

        return { makeSvg: makeSvg };
    })();

    /* ======================================================================
       Part 1: SSH Server & Embedded Web Console Controller
       ====================================================================== */
    var termState = {
        cwd: '/data/adb/netdroid',
        history: [],
        histIdx: -1,
        running: false
    };

    var sshState = null;

    function ansiToHtml(raw) {
        var safe = esc(raw);
        // Basic ANSI SGR color support
        var colorMap = {
            '30': '#6b7280', '31': '#f87171', '32': '#4ade80', '33': '#facc15',
            '34': '#60a5fa', '35': '#e879f9', '36': '#22d3ee', '37': '#e5e7eb',
            '90': '#9ca3af', '91': '#fca5a5', '92': '#86efac', '93': '#fde047',
            '94': '#93c5fd', '95': '#f0abfc', '96': '#67e8f9', '97': '#ffffff'
        };
        var openSpan = false;
        var out = safe.replace(/\x1b\[([0-9;]*)m/g, function (_, codes) {
            var res = '';
            if (openSpan) { res += '</span>'; openSpan = false; }
            if (!codes || codes === '0') return res;
            var parts = codes.split(';');
            var styles = [];
            parts.forEach(function (c) {
                if (c === '1') styles.push('font-weight:700');
                else if (colorMap[c]) styles.push('color:' + colorMap[c]);
            });
            if (styles.length) {
                openSpan = true;
                res += '<span style="' + styles.join(';') + '">';
            }
            return res;
        });
        if (openSpan) out += '</span>';
        // Strip remaining CSI control sequences cleanly
        return out.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, '');
    }

    function appendTermLine(html, cls) {
        var out = $('term-output');
        if (!out) return;
        var div = document.createElement('div');
        div.className = 'term-line' + (cls ? ' ' + cls : '');
        div.innerHTML = html;
        out.appendChild(div);
        // Keep DOM light (max 240 blocks)
        while (out.childNodes.length > 240) out.removeChild(out.firstChild);
        out.scrollTop = out.scrollHeight;
    }

    function updatePromptLabel() {
        var lbl = $('term-cwd-label');
        if (lbl) lbl.textContent = termState.cwd || '/data/adb/netdroid';
    }

    function execTermCommand(cmdText) {
        var api = global.NetDroidApi;
        var toast = global.NetDroidToast || function () {};
        if (!api) return;
        var cmd = String(cmdText || '').trim();
        if (!cmd) return;

        if (cmd === 'clear') {
            if ($('term-output')) $('term-output').innerHTML = '';
            return;
        }

        if (termState.history[termState.history.length - 1] !== cmd) {
            termState.history.push(cmd);
            if (termState.history.length > 60) termState.history.shift();
        }
        termState.histIdx = termState.history.length;

        appendTermLine('<span class="term-prompt-tag">root@netdroid:' + esc(termState.cwd) + '#</span> ' + esc(cmd), 'cmd');
        termState.running = true;
        if ($('btn-term-run')) $('btn-term-run').disabled = true;

        api.post('term_exec', { cmd: cmd }).then(function (r) {
            if (r && r.ok) {
                if (r.cwd) { termState.cwd = r.cwd; updatePromptLabel(); }
                if (r.output) {
                    appendTermLine(ansiToHtml(r.output), r.exit_code !== 0 ? 'err' : '');
                } else if (r.exit_code !== 0) {
                    appendTermLine('Command exited with status ' + r.exit_code, 'err');
                }
            } else {
                appendTermLine(esc((r && r.error) || 'Execution error'), 'err');
            }
        }).catch(function () {
            toast('Terminal request failed', 'error');
        }).finally(function () {
            termState.running = false;
            if ($('btn-term-run')) $('btn-term-run').disabled = false;
        });
    }

    function renderSsh(s) {
        if (!s || !s.ok) return;
        sshState = s;

        var badge = $('ssh-status-badge');
        if (badge) {
            if (s.running) {
                badge.textContent = 'Running • PID ' + s.pid;
                badge.className = 'm3-chip success';
            } else if (s.daemon === 'none') {
                badge.textContent = 'No Daemon Found';
                badge.className = 'm3-chip danger';
            } else {
                badge.textContent = 'Stopped';
                badge.className = 'm3-chip';
            }
        }

        var dBadge = $('ssh-daemon-chip');
        if (dBadge) {
            dBadge.textContent = s.daemon === 'dropbear'
                ? ('Dropbear • Port ' + s.port)
                : (s.daemon === 'openssh' ? ('OpenSSH • Port ' + s.port) : 'SSH Unavailable');
        }

        $('sw-ssh-enabled').classList.toggle('on', !!s.enabled);
        $('sw-ssh-passwd').classList.toggle('on', !!s.password_auth);
        if ($('input-ssh-port') && document.activeElement !== $('input-ssh-port')) {
            $('input-ssh-port').value = s.port || 2222;
        }

        var ip = (s.lan_ips && s.lan_ips[0]) || '127.0.0.1';
        var connCmd = 'ssh root@' + ip + ' -p ' + (s.port || 2222);
        var connBtn = $('btn-copy-ssh-cmd');
        if (connBtn) {
            connBtn.textContent = connCmd;
            connBtn.setAttribute('data-cmd', connCmd);
        }

        // Active sessions
        var sessBox = $('ssh-sessions-list');
        if (sessBox) {
            var sess = s.sessions || [];
            if (!sess.length) {
                sessBox.innerHTML = '<span style="font-size:0.74rem;color:var(--md-on-surface-variant);">No active SSH sessions</span>';
            } else {
                sessBox.innerHTML = sess.map(function (x) {
                    return '<span class="m3-chip success">' + esc(x.remote) + ' (PID ' + esc(x.pid) + ')</span>';
                }).join('');
            }
        }

        // Authorized keys
        var keyList = $('ssh-keys-list');
        if (keyList) {
            var keys = s.keys || [];
            if (!keys.length) {
                keyList.innerHTML = '<div class="empty-state" style="padding:14px;">No SSH public keys added yet.<br>Paste your <code>.pub</code> key above for passwordless login.</div>';
            } else {
                keyList.innerHTML = keys.map(function (k) {
                    return '<div class="ssh-key-item">' +
                        '<div class="item-info">' +
                            '<div class="item-title" style="font-size:0.86rem;">' + esc(k.label) + '</div>' +
                            '<div class="item-meta"><span>' + esc(k.type) + '</span><span>' + esc(k.preview) + '</span></div>' +
                        '</div>' +
                        '<button type="button" class="m3-btn m3-btn-danger m3-btn-sm" data-rm-ssh-key="' + k.index + '">Delete</button>' +
                    '</div>';
                }).join('');

                keyList.querySelectorAll('[data-rm-ssh-key]').forEach(function (btn) {
                    btn.addEventListener('click', function () {
                        var idx = btn.getAttribute('data-rm-ssh-key');
                        global.NetDroidApi.post('ssh', { remove_key: idx }).then(function (r) {
                            if (r && r.ok) {
                                renderSsh(r);
                                global.NetDroidToast('SSH key removed', 'success');
                            }
                        });
                    });
                });
            }
        }
    }

    function loadSsh() {
        if (!global.NetDroidApi) return;
        global.NetDroidApi.get('ssh').then(renderSsh).catch(function () {});
    }

    /* ======================================================================
       Part 2: LAN Shared Folder (Pocket NAS) Controller
       ====================================================================== */
    var shareState = {
        path: '/',
        rootPath: '/sdcard/NetDroidShare',
        configuredRoot: '/sdcard/NetDroidShare',
        fallbackActive: false,
        fallbackReason: '',
        readOnly: false,
        viewMode: 'list', // 'list' | 'grid'
        items: [],
        storage: null,
        storages: [],
        uploading: false
    };

    function fileIconSvg(item) {
        if (item.is_dir) {
            return '<svg width="22" height="22" viewBox="0 0 24 24" fill="currentColor" opacity="0.9"><path d="M10 4H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-8l-2-2z"/></svg>';
        }
        var m = item.mime || '';
        if (m.indexOf('image/') === 0) {
            return '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="3"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21 15 16 10 5 21"/></svg>';
        }
        if (m.indexOf('video/') === 0) {
            return '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="4" width="20" height="16" rx="3"/><polygon points="10 9 16 12 10 15 10 9" fill="currentColor" stroke="none"/></svg>';
        }
        if (m.indexOf('audio/') === 0) {
            return '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/></svg>';
        }
        if (m.indexOf('zip') !== -1 || m.indexOf('android') !== -1 || m.indexOf('compressed') !== -1) {
            return '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"><path d="M21 8v13H3V8"/><path d="M1 3h22v5H1z"/><path d="M10 12h4"/></svg>';
        }
        return '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>';
    }

    function joinPath(base, name) {
        var b = String(base || '/').replace(/\/+$/, '');
        var n = String(name || '').replace(/^\/+/, '');
        return (b ? b + '/' : '/') + n;
    }

    function storageIconSvg(isExt) {
        if (isExt) {
            return '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="14" width="20" height="7" rx="2"/><path d="M6 14V5a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v9"/><line x1="6" y1="17.5" x2="6.01" y2="17.5"/><line x1="10" y1="17.5" x2="10.01" y2="17.5"/></svg>';
        }
        return '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"><rect x="6" y="2" width="12" height="20" rx="3"/><line x1="12" y1="18" x2="12.01" y2="18"/></svg>';
    }

    function applyShareRoot(newRoot) {
        var cleaned = String(newRoot || '').trim();
        if (!cleaned) return;
        global.NetDroidApi.post('share_manage', { op: 'config', root_path: cleaned }).then(function (r) {
            if (r && r.ok) {
                shareState.path = '/';
                shareState.rootPath = r.active_root || r.root_path || cleaned;
                shareState.configuredRoot = r.configured_root || shareState.rootPath;
                shareState.fallbackActive = !!r.fallback_active;
                shareState.fallbackReason = r.fallback_reason || '';
                shareState.items = r.items || [];
                shareState.storage = r.storage || {};
                if (r.storages) shareState.storages = r.storages;
                renderShare(r);
                global.NetDroidToast('Shared root: ' + shareState.rootPath, 'success');
            } else {
                global.NetDroidToast((r && r.error) || 'Cannot set shared path', 'error');
            }
        }).catch(function () {
            global.NetDroidToast('Failed to update shared path', 'error');
        });
    }

    function rescanStorages(notify) {
        if (!global.NetDroidApi) return;
        global.NetDroidApi.get('share_storages').then(function (r) {
            if (!r || !r.ok) return;
            shareState.storages = r.storages || [];
            shareState.configuredRoot = r.configured_root || shareState.configuredRoot;
            shareState.rootPath = r.active_root || shareState.rootPath;
            shareState.fallbackActive = !!r.fallback_active;
            shareState.fallbackReason = r.fallback_reason || '';
            renderStoragesUI();
            if (notify) {
                var extCnt = shareState.storages.filter(function (s) { return s.type === 'external'; }).length;
                global.NetDroidToast(extCnt > 0
                    ? ('Detected ' + extCnt + ' external USB/HDD drive' + (extCnt > 1 ? 's' : ''))
                    : 'No external USB/HDD drives mounted (Internal Storage active)', 'info');
            }
        }).catch(function () {});
    }

    function renderStoragesUI() {
        // Fallback warning banner
        var fb = $('share-fallback-banner');
        var fbTxt = $('share-fallback-text');
        if (fb && fbTxt) {
            if (shareState.fallbackActive) {
                fbTxt.textContent = '⚠ ' + (shareState.fallbackReason || ('External drive (' + shareState.configuredRoot + ') is disconnected. Serving Internal Storage fallback.'));
                fb.classList.add('show');
            } else {
                fb.classList.remove('show');
            }
        }

        // Storage volume cards
        var grid = $('share-storage-list');
        if (grid) {
            var vols = shareState.storages || [];
            var activeRoot = shareState.rootPath || '/sdcard/NetDroidShare';
            grid.innerHTML = vols.map(function (v) {
                var isExt = v.type === 'external';
                var isSelected = isExt
                    ? (activeRoot === v.path || activeRoot.indexOf(v.mount_point + '/') === 0 || activeRoot === v.mount_point)
                    : (activeRoot.indexOf('/sdcard') === 0 || activeRoot.indexOf('/storage/emulated/0') === 0);
                var pct = Number(v.used_pct) || 0;
                return '<button type="button" class="storage-vol-card' + (isExt ? ' external' : '') + (isSelected ? ' active' : '') + '" data-vol-path="' + esc(v.path) + '">' +
                    '<div class="storage-vol-top">' +
                        '<div class="storage-vol-title-wrap">' +
                            '<div class="storage-vol-icon">' + storageIconSvg(isExt) + '</div>' +
                            '<div style="min-width:0;flex:1;">' +
                                '<div class="storage-vol-name">' + esc(v.label) + '</div>' +
                                '<div class="storage-vol-path">' + esc(v.path) + '</div>' +
                            '</div>' +
                        '</div>' +
                        '<span class="fs-badge">' + esc(v.fstype || 'fs') + '</span>' +
                    '</div>' +
                    '<div class="m3-progress-track" style="height:6px;">' +
                        '<div class="m3-progress-fill' + (pct >= 90 ? ' crit' : (pct >= 80 ? ' warn' : '')) + '" style="width:' + Math.max(2, Math.min(100, pct)) + '%;"></div>' +
                    '</div>' +
                    '<div class="storage-vol-meta">' +
                        '<span>' + fmtBytes(v.free_bytes || 0) + ' free</span>' +
                        '<span>' + fmtBytes(v.total_bytes || 0) + ' total</span>' +
                    '</div>' +
                '</button>';
            }).join('');

            grid.querySelectorAll('[data-vol-path]').forEach(function (card) {
                card.addEventListener('click', function () {
                    applyShareRoot(card.getAttribute('data-vol-path'));
                });
            });
        }

        // Custom path input + quick suggestion chips
        var pathInput = $('input-share-custom-path');
        if (pathInput && document.activeElement !== pathInput) {
            pathInput.value = shareState.configuredRoot || shareState.rootPath || '/sdcard/NetDroidShare';
        }
        var chipsBox = $('share-path-presets');
        if (chipsBox) {
            var presets = [
                { lbl: 'NetDroidShare', path: '/sdcard/NetDroidShare' },
                { lbl: 'Download', path: '/sdcard/Download' },
                { lbl: 'Internal Root', path: '/sdcard' }
            ];
            (shareState.storages || []).forEach(function (v) {
                if (v.type === 'external') {
                    presets.push({ lbl: v.uuid + '/Shared', path: v.path + '/Shared' });
                }
            });
            chipsBox.innerHTML = presets.map(function (pr) {
                var act = (shareState.rootPath === pr.path) ? ' accent' : '';
                return '<button type="button" class="m3-chip clickable' + act + '" data-preset-path="' + esc(pr.path) + '">' + esc(pr.lbl) + '</button>';
            }).join('');
            chipsBox.querySelectorAll('[data-preset-path]').forEach(function (b) {
                b.addEventListener('click', function () {
                    applyShareRoot(b.getAttribute('data-preset-path'));
                });
            });
        }
    }

    function loadShare(targetPath) {
        if (!global.NetDroidApi) return;
        var p = targetPath != null ? targetPath : shareState.path;
        global.NetDroidApi.get('share_list', { path: p }).then(function (r) {
            if (!r || !r.ok) {
                if (p !== '/') { loadShare('/'); return; }
                global.NetDroidToast((r && r.error) || 'Failed to read shared folder', 'error');
                return;
            }
            shareState.path = r.path || '/';
            shareState.rootPath = r.active_root || r.root_path || '/sdcard/NetDroidShare';
            shareState.configuredRoot = r.configured_root || shareState.rootPath;
            shareState.fallbackActive = !!r.fallback_active;
            shareState.fallbackReason = r.fallback_reason || '';
            shareState.readOnly = !!r.read_only;
            shareState.items = r.items || [];
            shareState.storage = r.storage || {};
            if (r.storages) shareState.storages = r.storages;
            renderShare(r);
        }).catch(function () {});
    }

    function renderShare(r) {
        // Storage volume switcher & fallback banner
        renderStoragesUI();

        // Active storage bar
        var st = r.storage || {};
        var pct = Number(st.used_pct) || 0;
        if ($('share-storage-text')) {
            $('share-storage-text').textContent = fmtBytes(st.free_bytes || 0) + ' free of ' + fmtBytes(st.total_bytes || 0) + ' (' + shareState.rootPath + ')';
        }
        if ($('share-storage-pct')) $('share-storage-pct').textContent = pct + '% used';
        if ($('share-storage-fill')) {
            $('share-storage-fill').style.width = Math.max(2, Math.min(100, pct)) + '%';
            $('share-storage-fill').className = 'm3-progress-fill' + (pct >= 90 ? ' crit' : (pct >= 80 ? ' warn' : ''));
        }

        // Mode selector pill (Read & Write vs Read-Only)
        if ($('share-mode-rw')) $('share-mode-rw').classList.toggle('active', !shareState.readOnly);
        if ($('share-mode-ro')) $('share-mode-ro').classList.toggle('active', shareState.readOnly);

        // Hide upload/mkdir in Read-Only mode
        if ($('share-upload-zone')) $('share-upload-zone').style.display = shareState.readOnly ? 'none' : 'flex';
        if ($('btn-share-mkdir')) $('btn-share-mkdir').style.display = shareState.readOnly ? 'none' : 'inline-flex';

        // Optional WebDAV row
        var wdRow = $('share-webdav-row');
        if (wdRow && r.webdav) {
            wdRow.style.display = r.webdav.supported ? 'flex' : 'none';
            if ($('sw-share-webdav')) $('sw-share-webdav').classList.toggle('on', !!r.webdav.running);
        }

        // Breadcrumbs
        var bc = $('share-breadcrumbs');
        if (bc) {
            var segs = shareState.path.split('/').filter(Boolean);
            var html = '<button type="button" class="crumb-btn' + (segs.length === 0 ? ' active' : '') + '" data-crumb="/">Root</button>';
            var acc = '';
            segs.forEach(function (sg, idx) {
                acc += '/' + sg;
                var isLast = idx === segs.length - 1;
                html += '<span class="crumb-sep">/</span>' +
                    '<button type="button" class="crumb-btn' + (isLast ? ' active' : '') + '" data-crumb="' + esc(acc) + '">' + esc(sg) + '</button>';
            });
            bc.innerHTML = html;
            bc.querySelectorAll('[data-crumb]').forEach(function (b) {
                b.addEventListener('click', function () { loadShare(b.getAttribute('data-crumb')); });
            });
        }

        // File items (List or Grid)
        var box = $('share-file-list');
        if (!box) return;
        box.className = shareState.viewMode === 'grid' ? 'file-grid' : 'item-list';

        var items = shareState.items;
        if (!items.length) {
            box.innerHTML = '<div class="empty-state">This folder is empty.<br>' +
                (shareState.readOnly ? 'Switch to Read &amp; Write mode to upload files.' : 'Drop files above or tap Upload Files to transfer over LAN.') + '</div>';
            return;
        }

        var tokParam = (global.NetDroidApi && global.NetDroidApi.token)
            ? ('&token=' + encodeURIComponent(global.NetDroidApi.token))
            : '';

        var html = '';
        items.forEach(function (it) {
            var fullRel = joinPath(shareState.path, it.name);
            var dlUrl = '/cgi-bin/share.sh?action=download&file=' + encodeURIComponent(fullRel) + tokParam;
            html += '<div class="file-item' + (it.is_dir ? ' is-dir' : '') + '">' +
                '<div class="file-main" data-open-rel="' + esc(fullRel) + '" data-is-dir="' + (it.is_dir ? '1' : '0') + '" data-dl-url="' + esc(dlUrl) + '">' +
                    '<div class="file-avatar' + (it.is_dir ? ' dir' : '') + '">' + fileIconSvg(it) + '</div>' +
                    '<div class="item-info">' +
                        '<div class="item-title" title="' + esc(it.name) + '">' + esc(it.name) + '</div>' +
                        '<div class="item-meta">' +
                            '<span>' + (it.is_dir ? 'Folder' : fmtBytes(it.size)) + '</span>' +
                            '<span>' + esc(fmtTime(it.mtime)) + '</span>' +
                        '</div>' +
                    '</div>' +
                '</div>' +
                '<div class="file-actions">' +
                    (!it.is_dir ? '<a class="m3-btn m3-btn-tonal m3-btn-sm" href="' + esc(dlUrl) + '" download="' + esc(it.name) + '">Download</a>' : '<button type="button" class="m3-btn m3-btn-tonal m3-btn-sm" data-open-dir="' + esc(fullRel) + '">Open</button>') +
                    (!shareState.readOnly ? '<button type="button" class="m3-btn m3-btn-outlined m3-btn-sm" data-ren-name="' + esc(it.name) + '">Rename</button>' : '') +
                    (!shareState.readOnly ? '<button type="button" class="m3-btn m3-btn-danger m3-btn-sm" data-del-name="' + esc(it.name) + '">Delete</button>' : '') +
                '</div>' +
            '</div>';
        });
        box.innerHTML = html;

        // Bind navigation / rename / delete
        box.querySelectorAll('[data-open-rel]').forEach(function (el) {
            el.addEventListener('click', function () {
                if (el.getAttribute('data-is-dir') === '1') {
                    loadShare(el.getAttribute('data-open-rel'));
                } else if (!global.NetDroidApi.isKsuNative()) {
                    window.open(el.getAttribute('data-dl-url'), '_blank');
                }
            });
        });
        box.querySelectorAll('[data-open-dir]').forEach(function (btn) {
            btn.addEventListener('click', function () { loadShare(btn.getAttribute('data-open-dir')); });
        });
        box.querySelectorAll('[data-ren-name]').forEach(function (btn) {
            btn.addEventListener('click', function () {
                var oldName = btn.getAttribute('data-ren-name');
                var newName = prompt('Rename "' + oldName + '" to:', oldName);
                if (!newName || newName.trim() === oldName) return;
                global.NetDroidApi.post('share_manage', {
                    op: 'rename', path: shareState.path, name: oldName, new_name: newName.trim()
                }).then(function (res) {
                    if (res && res.ok) {
                        global.NetDroidToast('Renamed to ' + newName.trim(), 'success');
                        loadShare();
                    } else {
                        global.NetDroidToast((res && res.error) || 'Rename failed', 'error');
                    }
                });
            });
        });
        box.querySelectorAll('[data-del-name]').forEach(function (btn) {
            btn.addEventListener('click', function () {
                var nm = btn.getAttribute('data-del-name');
                if (!confirm('Delete "' + nm + '" permanently?')) return;
                global.NetDroidApi.post('share_manage', {
                    op: 'delete', path: shareState.path, name: nm
                }).then(function (res) {
                    if (res && res.ok) {
                        global.NetDroidToast('Deleted ' + nm, 'success');
                        loadShare();
                    } else {
                        global.NetDroidToast((res && res.error) || 'Delete failed', 'error');
                    }
                });
            });
        });
    }

    // Zero-RAM streaming multi-file upload (2 MB chunks via XHR with live progress & MB/s)
    function uploadFiles(fileList) {
        if (!fileList || !fileList.length) return;
        if (shareState.readOnly) {
            global.NetDroidToast('Shared folder is Read-Only', 'error');
            return;
        }
        if (shareState.uploading) {
            global.NetDroidToast('An upload is already in progress', 'info');
            return;
        }
        if (global.NetDroidApi && global.NetDroidApi.isKsuNative()) {
            global.NetDroidToast('Open http://127.0.0.1:8765 in browser for large file uploads', 'info');
            return;
        }

        var files = Array.prototype.slice.call(fileList);
        shareState.uploading = true;
        var progWrap = $('share-upload-progress');
        var progFill = $('share-upload-bar');
        var progText = $('share-upload-status');
        if (progWrap) progWrap.style.display = 'block';

        var CHUNK_SIZE = 16 * 1024 * 1024; // 16 MB chunks minimize BusyBox CGI fork overhead on large ROMs/ISOs
        var idx = 0;

        function nextFile() {
            if (idx >= files.length) {
                shareState.uploading = false;
                if (progWrap) progWrap.style.display = 'none';
                global.NetDroidToast('Uploaded ' + files.length + (files.length === 1 ? ' file' : ' files'), 'success');
                loadShare();
                return;
            }
            var file = files[idx++];
            var offset = 0;
            var startedAt = Date.now();

            function sendChunk() {
                var end = Math.min(file.size, offset + CHUNK_SIZE);
                var blob = file.size > 0 ? file.slice(offset, end) : new Blob([]);
                var isAppend = offset > 0 ? '1' : '0';
                var url = '/cgi-bin/share.sh?action=upload&path=' + encodeURIComponent(shareState.path) +
                    '&name=' + encodeURIComponent(file.name) + '&append=' + isAppend;

                var xhr = new XMLHttpRequest();
                xhr.open('POST', url, true);
                if (global.NetDroidApi && global.NetDroidApi.token) {
                    xhr.setRequestHeader('X-NetDroid-Token', global.NetDroidApi.token);
                }
                xhr.setRequestHeader('Content-Type', 'application/octet-stream');

                xhr.upload.onprogress = function (ev) {
                    if (!ev.lengthComputable) return;
                    var done = offset + ev.loaded;
                    var pct = file.size > 0 ? Math.min(100, Math.round((done / file.size) * 100)) : 100;
                    var sec = Math.max(0.1, (Date.now() - startedAt) / 1000);
                    var spd = global.NetDroidCharts.formatSpeed(done / sec);
                    if (progFill) progFill.style.width = pct + '%';
                    if (progText) {
                        progText.textContent = 'Uploading ' + file.name + ' (' + idx + '/' + files.length + ') — ' +
                            pct + '% • ' + fmtBytes(done) + ' / ' + fmtBytes(file.size) + ' • ' + spd;
                    }
                };

                xhr.onload = function () {
                    var res = {};
                    try { res = JSON.parse(xhr.responseText); } catch (e) {}
                    if (xhr.status >= 200 && xhr.status < 300 && res.ok) {
                        offset = end;
                        if (offset < file.size) {
                            sendChunk();
                        } else {
                            nextFile();
                        }
                    } else {
                        shareState.uploading = false;
                        if (progWrap) progWrap.style.display = 'none';
                        global.NetDroidToast((res && res.error) || ('Upload failed for ' + file.name), 'error');
                    }
                };

                xhr.onerror = function () {
                    shareState.uploading = false;
                    if (progWrap) progWrap.style.display = 'none';
                    global.NetDroidToast('Network error uploading ' + file.name, 'error');
                };

                xhr.send(blob);
            }
            sendChunk();
        }
        nextFile();
    }

    function openShareQrModal() {
        var lanChip = $('chip-lan-url');
        var baseUrl = (lanChip && lanChip.getAttribute('data-url')) || (location.origin !== 'null' ? location.origin : 'http://127.0.0.1:8765');
        var shareUrl = baseUrl.replace(/\/+$/, '') + '/#share';
        if ($('qr-url-text')) $('qr-url-text').textContent = shareUrl;
        if ($('qr-svg-box')) $('qr-svg-box').innerHTML = QR.makeSvg(shareUrl);
        if ($('qr-modal-overlay')) $('qr-modal-overlay').classList.add('visible');
    }

    /* ======================================================================
       Wire Events
       ====================================================================== */
    function init() {
        // SSH Controls
        if ($('sw-ssh-enabled')) {
            $('sw-ssh-enabled').addEventListener('click', function () {
                var next = !$('sw-ssh-enabled').classList.contains('on');
                $('sw-ssh-enabled').classList.toggle('on', next);
                global.NetDroidApi.post('ssh', { enabled: next ? 'true' : 'false' }).then(function (r) {
                    if (r && r.ok) {
                        renderSsh(r);
                        global.NetDroidToast(r.running ? ('SSH daemon started on port ' + r.port) : 'SSH daemon stopped', 'success');
                    } else {
                        global.NetDroidToast((r && r.error) || 'SSH toggle failed', 'error');
                    }
                });
            });
        }
        if ($('sw-ssh-passwd')) {
            $('sw-ssh-passwd').addEventListener('click', function () {
                var next = !$('sw-ssh-passwd').classList.contains('on');
                $('sw-ssh-passwd').classList.toggle('on', next);
                global.NetDroidApi.post('ssh', { password_auth: next ? 'true' : 'false' }).then(function (r) {
                    if (r && r.ok) {
                        renderSsh(r);
                        global.NetDroidToast(next ? 'PIN password SSH login enabled' : 'SSH set to Public Key only', 'success');
                    }
                });
            });
        }
        if ($('btn-save-ssh-port')) {
            $('btn-save-ssh-port').addEventListener('click', function () {
                var p = parseInt($('input-ssh-port').value, 10);
                if (!p || p < 1024 || p > 65535) {
                    global.NetDroidToast('Port must be 1024–65535', 'error');
                    return;
                }
                global.NetDroidApi.post('ssh', { port: p }).then(function (r) {
                    if (r && r.ok) {
                        renderSsh(r);
                        global.NetDroidToast('SSH port updated to ' + r.port, 'success');
                    } else {
                        global.NetDroidToast((r && r.error) || 'Failed to update port', 'error');
                    }
                });
            });
        }
        if ($('btn-copy-ssh-cmd')) {
            $('btn-copy-ssh-cmd').addEventListener('click', function () {
                var cmd = $('btn-copy-ssh-cmd').getAttribute('data-cmd') || '';
                if (navigator.clipboard && navigator.clipboard.writeText) {
                    navigator.clipboard.writeText(cmd).then(function () {
                        global.NetDroidToast('Copied: ' + cmd, 'success');
                    });
                } else {
                    global.NetDroidToast(cmd, 'info');
                }
            });
        }
        if ($('btn-add-ssh-key')) {
            $('btn-add-ssh-key').addEventListener('click', function () {
                var lbl = ($('input-ssh-key-label').value || '').trim();
                var key = ($('input-ssh-key-pub').value || '').trim();
                if (!key) { global.NetDroidToast('Paste a valid SSH .pub key', 'error'); return; }
                global.NetDroidApi.post('ssh', { label: lbl, add_key: key }).then(function (r) {
                    if (r && r.ok) {
                        $('input-ssh-key-label').value = '';
                        $('input-ssh-key-pub').value = '';
                        renderSsh(r);
                        global.NetDroidToast('SSH public key added', 'success');
                    } else {
                        global.NetDroidToast((r && r.error) || 'Invalid SSH key', 'error');
                    }
                });
            });
        }

        // Web Console Controls
        var termIn = $('term-input');
        if ($('btn-term-run')) {
            $('btn-term-run').addEventListener('click', function () {
                if (!termIn) return;
                var v = termIn.value;
                termIn.value = '';
                execTermCommand(v);
            });
        }
        if (termIn) {
            termIn.addEventListener('keydown', function (ev) {
                if (ev.key === 'Enter') {
                    ev.preventDefault();
                    var v = termIn.value;
                    termIn.value = '';
                    execTermCommand(v);
                } else if (ev.key === 'ArrowUp') {
                    ev.preventDefault();
                    if (termState.histIdx > 0) {
                        termState.histIdx--;
                        termIn.value = termState.history[termState.histIdx] || '';
                    }
                } else if (ev.key === 'ArrowDown') {
                    ev.preventDefault();
                    if (termState.histIdx < termState.history.length - 1) {
                        termState.histIdx++;
                        termIn.value = termState.history[termState.histIdx] || '';
                    } else {
                        termState.histIdx = termState.history.length;
                        termIn.value = '';
                    }
                } else if (ev.key === 'Tab') {
                    ev.preventDefault();
                    triggerTabComplete();
                } else if (ev.ctrlKey && ev.key.toLowerCase() === 'c') {
                    ev.preventDefault();
                    triggerCtrlC();
                }
            });
        }

        function triggerCtrlC() {
            global.NetDroidApi.post('term_kill').then(function () {
                appendTermLine('^C', 'err');
                if (termIn) termIn.value = '';
            });
        }

        function triggerTabComplete() {
            if (!termIn) return;
            var val = termIn.value;
            var parts = val.split(/\s+/);
            var last = parts[parts.length - 1] || '';
            global.NetDroidApi.post('term_complete', { token: last }).then(function (r) {
                if (!r || !r.ok || !r.matches || !r.matches.length) return;
                if (r.matches.length === 1) {
                    parts[parts.length - 1] = r.matches[0];
                    termIn.value = parts.join(' ');
                } else {
                    appendTermLine(esc(r.matches.join('   ')), 'hint');
                }
                termIn.focus();
            });
        }

        if ($('btn-term-ctrlc')) $('btn-term-ctrlc').addEventListener('click', triggerCtrlC);
        if ($('btn-term-tab')) $('btn-term-tab').addEventListener('click', triggerTabComplete);
        if ($('btn-term-up')) $('btn-term-up').addEventListener('click', function () {
            if (termState.histIdx > 0 && termIn) {
                termState.histIdx--;
                termIn.value = termState.history[termState.histIdx] || '';
                termIn.focus();
            }
        });
        if ($('btn-term-down')) $('btn-term-down').addEventListener('click', function () {
            if (!termIn) return;
            if (termState.histIdx < termState.history.length - 1) {
                termState.histIdx++;
                termIn.value = termState.history[termState.histIdx] || '';
            } else {
                termState.histIdx = termState.history.length;
                termIn.value = '';
            }
            termIn.focus();
        });
        if ($('btn-term-clear')) $('btn-term-clear').addEventListener('click', function () {
            if ($('term-output')) $('term-output').innerHTML = '';
        });

        document.querySelectorAll('[data-term-snip]').forEach(function (btn) {
            btn.addEventListener('click', function () {
                execTermCommand(btn.getAttribute('data-term-snip'));
            });
        });

        // Pocket NAS / Share Controls
        if ($('share-mode-rw')) {
            $('share-mode-rw').addEventListener('click', function () {
                global.NetDroidApi.post('share_manage', { op: 'config', read_only: 'false' }).then(function (r) {
                    if (r && r.ok) { shareState.readOnly = false; renderShare(r); global.NetDroidToast('Mode: Read & Write', 'success'); }
                });
            });
        }
        if ($('share-mode-ro')) {
            $('share-mode-ro').addEventListener('click', function () {
                global.NetDroidApi.post('share_manage', { op: 'config', read_only: 'true' }).then(function (r) {
                    if (r && r.ok) { shareState.readOnly = true; renderShare(r); global.NetDroidToast('Mode: Read-Only', 'success'); }
                });
            });
        }
        if ($('btn-rescan-storages')) {
            $('btn-rescan-storages').addEventListener('click', function () {
                rescanStorages(true);
                loadShare();
            });
        }
        if ($('btn-fallback-rescan')) {
            $('btn-fallback-rescan').addEventListener('click', function () {
                rescanStorages(true);
                loadShare('/');
            });
        }
        if ($('btn-apply-custom-path')) {
            $('btn-apply-custom-path').addEventListener('click', function () {
                var p = ($('input-share-custom-path') && $('input-share-custom-path').value || '').trim();
                if (!p) { global.NetDroidToast('Enter a valid storage path', 'error'); return; }
                applyShareRoot(p);
            });
        }
        if ($('input-share-custom-path')) {
            $('input-share-custom-path').addEventListener('keydown', function (ev) {
                if (ev.key === 'Enter') {
                    ev.preventDefault();
                    applyShareRoot($('input-share-custom-path').value);
                }
            });
        }
        if ($('sw-share-webdav')) {
            $('sw-share-webdav').addEventListener('click', function () {
                var next = !$('sw-share-webdav').classList.contains('on');
                global.NetDroidApi.post('share_manage', { op: 'config', webdav_enabled: next ? 'true' : 'false' }).then(function (r) {
                    if (r && r.ok) { renderShare(r); global.NetDroidToast(next ? 'WebDAV started (:8766)' : 'WebDAV stopped', 'success'); }
                });
            });
        }
        if ($('share-view-list')) {
            $('share-view-list').addEventListener('click', function () {
                shareState.viewMode = 'list';
                $('share-view-list').classList.add('active');
                $('share-view-grid').classList.remove('active');
                loadShare();
            });
        }
        if ($('share-view-grid')) {
            $('share-view-grid').addEventListener('click', function () {
                shareState.viewMode = 'grid';
                $('share-view-grid').classList.add('active');
                $('share-view-list').classList.remove('active');
                loadShare();
            });
        }
        if ($('btn-share-refresh')) $('btn-share-refresh').addEventListener('click', function () { loadShare(); });
        if ($('btn-share-mkdir')) {
            $('btn-share-mkdir').addEventListener('click', function () {
                var nm = prompt('New folder name:');
                if (!nm || !nm.trim()) return;
                global.NetDroidApi.post('share_manage', { op: 'mkdir', path: shareState.path, name: nm.trim() }).then(function (r) {
                    if (r && r.ok) { global.NetDroidToast('Folder created', 'success'); loadShare(); }
                    else global.NetDroidToast((r && r.error) || 'Failed to create folder', 'error');
                });
            });
        }

        // File upload drag & drop + picker
        var upInput = $('share-file-input');
        var upZone = $('share-upload-zone');
        if ($('btn-share-upload') && upInput) {
            $('btn-share-upload').addEventListener('click', function () { upInput.click(); });
            upInput.addEventListener('change', function () {
                if (upInput.files && upInput.files.length) {
                    uploadFiles(upInput.files);
                    upInput.value = '';
                }
            });
        }
        if (upZone) {
            ['dragenter', 'dragover'].forEach(function (evName) {
                upZone.addEventListener(evName, function (e) {
                    e.preventDefault(); e.stopPropagation();
                    upZone.classList.add('dragover');
                });
            });
            ['dragleave', 'drop'].forEach(function (evName) {
                upZone.addEventListener(evName, function (e) {
                    e.preventDefault(); e.stopPropagation();
                    upZone.classList.remove('dragover');
                });
            });
            upZone.addEventListener('drop', function (e) {
                if (e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files.length) {
                    uploadFiles(e.dataTransfer.files);
                }
            });
        }

        // QR Share Modal
        if ($('btn-share-qr')) $('btn-share-qr').addEventListener('click', openShareQrModal);
        if ($('btn-qr-close')) $('btn-qr-close').addEventListener('click', function () {
            if ($('qr-modal-overlay')) $('qr-modal-overlay').classList.remove('visible');
        });
        if ($('qr-modal-overlay')) {
            $('qr-modal-overlay').addEventListener('click', function (e) {
                if (e.target === $('qr-modal-overlay')) $('qr-modal-overlay').classList.remove('visible');
            });
        }
        if ($('btn-qr-copy')) {
            $('btn-qr-copy').addEventListener('click', function () {
                var u = ($('qr-url-text') && $('qr-url-text').textContent) || '';
                if (navigator.clipboard && navigator.clipboard.writeText) {
                    navigator.clipboard.writeText(u).then(function () { global.NetDroidToast('Copied share link!', 'success'); });
                }
            });
        }
    }

    global.NetDroidHomelab = {
        init: init,
        loadSsh: loadSsh,
        loadShare: loadShare
    };
})(window);
