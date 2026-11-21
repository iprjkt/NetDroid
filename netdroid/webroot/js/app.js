/* ==========================================================================
   NetDroid — Core Application State, API Transport, Polling & UI Controllers
   Supports Standalone BusyBox HTTP (localhost & LAN) AND KernelSU Native WebUI
   ========================================================================== */

(function () {
    'use strict';

    var TOKEN_KEY = 'netdroid_auth_token';
    var MOD_CGI = '/data/adb/modules/netdroid/webroot/cgi-bin';

    /* -------------------- Utilities -------------------- */
    function $(id) { return document.getElementById(id); }

    function escapeHtml(str) {
        return String(str == null ? '' : str)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;');
    }

    function formatUptime(sec) {
        sec = Math.max(0, Number(sec) || 0);
        var d = Math.floor(sec / 86400);
        var h = Math.floor((sec % 86400) / 3600);
        var m = Math.floor((sec % 3600) / 60);
        if (d > 0) return d + 'd ' + h + 'h';
        if (h > 0) return h + 'h ' + m + 'm';
        return m + 'm';
    }

    function toast(msg, type) {
        var box = $('toast-container');
        if (!box) return;
        var el = document.createElement('div');
        el.className = 'toast' + (type ? ' ' + type : '');
        el.textContent = msg;
        box.appendChild(el);
        setTimeout(function () {
            el.style.opacity = '0';
            el.style.transform = 'translateY(8px)';
            el.style.transition = 'all 0.2s ease';
            setTimeout(function () { el.remove(); }, 220);
        }, 2800);
    }

    /* -------------------- Dual-Mode API Client (HTTP + KSU Native) -------------------- */
    var ksuCbSeq = 0;

    function isKsuNative() {
        return typeof window.ksu === 'object' && typeof window.ksu.exec === 'function' &&
            (location.hostname === 'mui.kernelsu.org' || location.protocol === 'file:' || location.port === '');
    }

    function ksuExec(cmd) {
        return new Promise(function (resolve, reject) {
            var cbName = '__nd_ksu_cb_' + (++ksuCbSeq) + '_' + Date.now();
            window[cbName] = function (errno, stdout, stderr) {
                delete window[cbName];
                if (errno === 0 || stdout) {
                    resolve(stdout || '');
                } else {
                    reject(new Error(stderr || ('Exit ' + errno)));
                }
            };
            try {
                window.ksu.exec(cmd, '{}', cbName);
            } catch (e) {
                delete window[cbName];
                reject(e);
            }
        });
    }

    function shQuote(str) {
        return "'" + String(str).replace(/'/g, "'\\''") + "'";
    }

    function encodeForm(params) {
        var parts = [];
        Object.keys(params || {}).forEach(function (k) {
            if (params[k] !== undefined && params[k] !== null) {
                parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(String(params[k])));
            }
        });
        return parts.join('&');
    }

    function dataUrlToBlob(dataUrl) {
        var arr = dataUrl.split(',');
        var mime = (arr[0].match(/:(.*?);/) || [])[1] || 'image/webp';
        var bstr = atob(arr[1]);
        var n = bstr.length;
        var u8 = new Uint8Array(n);
        while (n--) u8[n] = bstr.charCodeAt(n);
        return new Blob([u8], { type: mime });
    }

    var ApiClient = {
        token: '',
        isKsuNative: isKsuNative,

        loadToken: function () {
            try { this.token = localStorage.getItem(TOKEN_KEY) || ''; } catch (e) { this.token = ''; }
        },

        setToken: function (t) {
            this.token = t || '';
            try {
                if (this.token) localStorage.setItem(TOKEN_KEY, this.token);
                else localStorage.removeItem(TOKEN_KEY);
            } catch (e) {}
        },

        request: function (method, action, params) {
            var self = this;
            var qs = 'action=' + encodeURIComponent(action);
            if (method === 'GET' && params) {
                var extra = encodeForm(params);
                if (extra) qs += '&' + extra;
            }

            if (isKsuNative()) {
                var body = method === 'POST' ? encodeForm(params || {}) : '';
                var cmd = 'NETDROID_CLI_RAW=1 REQUEST_METHOD=' + method +
                    ' QUERY_STRING=' + shQuote(qs);
                if (method === 'POST') {
                    cmd = 'printf %s ' + shQuote(body) + ' | CONTENT_LENGTH=' + body.length + ' ' +
                        cmd + ' sh ' + MOD_CGI + '/api.sh';
                } else {
                    cmd += ' sh ' + MOD_CGI + '/api.sh';
                }
                return ksuExec(cmd).then(function (out) {
                    return JSON.parse((out || '{}').trim());
                });
            }

            var headers = {};
            if (this.token) headers['X-NetDroid-Token'] = this.token;
            var opts = { method: method, headers: headers, cache: 'no-store' };
            if (method === 'POST') {
                headers['Content-Type'] = 'application/x-www-form-urlencoded';
                opts.body = encodeForm(params || {});
            }

            return fetch('/cgi-bin/api.sh?' + qs, opts).then(function (res) {
                return res.text().then(function (txt) {
                    var data = {};
                    try { data = JSON.parse(txt); } catch (e) { data = { ok: false, error: 'Invalid server response' }; }
                    if (res.status === 401 || data.auth_required) {
                        self.setToken('');
                        showPinOverlay();
                    }
                    return data;
                });
            });
        },

        get: function (action, params) {
            return this.request('GET', action, params);
        },

        post: function (action, params) {
            return this.request('POST', action, params);
        },

        uploadWallpaper: function (dataUrl, ext) {
            if (isKsuNative()) {
                var b64 = dataUrl.split(',')[1] || '';
                var tmp = '/data/adb/netdroid/.ksu_bg_b64';
                // Write base64 via chunks to avoid ARG_MAX limits
                var chunkSize = 40000;
                var chain = ksuExec(': > ' + tmp);
                for (var i = 0; i < b64.length; i += chunkSize) {
                    (function (chunk) {
                        chain = chain.then(function () {
                            return ksuExec('printf %s ' + shQuote(chunk) + ' >> ' + tmp);
                        });
                    })(b64.slice(i, i + chunkSize));
                }
                return chain.then(function () {
                    return ksuExec('sh ' + MOD_CGI + '/upload_bg.sh save_b64 ' + shQuote(ext) + ' < ' + tmp + ' && rm -f ' + tmp);
                }).then(function (out) {
                    return JSON.parse((out || '{}').trim());
                });
            }

            var blob = dataUrlToBlob(dataUrl);
            var headers = { 'Content-Type': blob.type };
            if (this.token) headers['X-NetDroid-Token'] = this.token;
            return fetch('/cgi-bin/upload_bg.sh?type=' + encodeURIComponent(ext), {
                method: 'POST',
                headers: headers,
                body: blob
            }).then(function (r) { return r.json(); });
        },

        clearWallpaper: function () {
            if (isKsuNative()) {
                return ksuExec('sh ' + MOD_CGI + '/upload_bg.sh clear').then(function (o) {
                    return JSON.parse((o || '{}').trim());
                });
            }
            var headers = {};
            if (this.token) headers['X-NetDroid-Token'] = this.token;
            return fetch('/cgi-bin/upload_bg.sh?action=clear', { method: 'POST', headers: headers })
                .then(function (r) { return r.json(); });
        },

        getWallpaperDataUri: function () {
            if (isKsuNative()) {
                return ksuExec('sh ' + MOD_CGI + '/upload_bg.sh datauri').then(function (o) {
                    return JSON.parse((o || '{}').trim());
                });
            }
            return fetch('/cgi-bin/upload_bg.sh?action=datauri').then(function (r) { return r.json(); });
        }
    };

    /* -------------------- Application State -------------------- */
    var appState = {
        activeTab: 'dashboard',
        authenticated: false,
        isLocal: true,
        speedSource: 'cellular', // 'cellular' | 'hotspot'
        dashboard: null,
        clients: [],
        apps: [],
        appsLoaded: false,
        appFilter: 'all', // 'all' | 'user' | 'system' | 'blocked'
        appSearch: '',
        settings: null,
        battery: null,
        dns: null,
        dnsPollTimer: null,
        pinBuffer: '',
        pollTimer: null,
        clientTimer: null,
        modeBusy: false
    };

    var chart = null;

    /* -------------------- PIN Authentication Lock Screen -------------------- */
    function showPinOverlay(info) {
        appState.authenticated = false;
        appState.pinBuffer = '';
        renderPinDots();
        var ov = $('pin-overlay');
        if (ov) ov.classList.add('visible');
        if (info && $('pin-hint')) {
            $('pin-hint').textContent = info.default_pin
                ? 'Default PIN is 1234 — change it in Settings after login'
                : 'Enter your NetDroid LAN security PIN';
        }
        if (info && $('pin-device-sub')) {
            $('pin-device-sub').textContent = 'Remote LAN access to ' + (info.model || info.device || 'NetDroid');
        }
    }

    function hidePinOverlay() {
        var ov = $('pin-overlay');
        if (ov) ov.classList.remove('visible');
        appState.pinBuffer = '';
        renderPinDots();
    }

    function renderPinDots() {
        var box = $('pin-dots');
        if (!box) return;
        var len = Math.max(4, appState.pinBuffer.length);
        var html = '';
        for (var i = 0; i < len; i++) {
            html += '<span class="pin-dot' + (i < appState.pinBuffer.length ? ' filled' : '') + '"></span>';
        }
        box.innerHTML = html;
    }

    function submitPin() {
        if (!appState.pinBuffer || appState.pinBuffer.length < 4) {
            $('pin-err').textContent = 'Enter at least 4 digits';
            return;
        }
        $('pin-err').textContent = '';
        ApiClient.post('login', { pin: appState.pinBuffer }).then(function (res) {
            if (res && res.ok && res.token) {
                ApiClient.setToken(res.token);
                appState.authenticated = true;
                hidePinOverlay();
                updateLogoutVisibility();
                toast('Unlocked remote dashboard', 'success');
                startPolling();
                loadSettings();
            } else {
                $('pin-err').textContent = (res && res.error) || 'Incorrect PIN';
                appState.pinBuffer = '';
                renderPinDots();
                var card = $('pin-card');
                if (card) {
                    card.classList.remove('shake');
                    void card.offsetWidth;
                    card.classList.add('shake');
                }
            }
        }).catch(function () {
            $('pin-err').textContent = 'Connection error';
        });
    }

    function setupPinKeypad() {
        document.querySelectorAll('.pin-key[data-digit]').forEach(function (btn) {
            btn.addEventListener('click', function () {
                if (appState.pinBuffer.length >= 12) return;
                appState.pinBuffer += btn.getAttribute('data-digit');
                $('pin-err').textContent = '';
                renderPinDots();
            });
        });

        var delBtn = $('pin-key-del');
        if (delBtn) {
            delBtn.addEventListener('click', function () {
                appState.pinBuffer = appState.pinBuffer.slice(0, -1);
                renderPinDots();
            });
        }

        var okBtn = $('pin-key-ok');
        if (okBtn) okBtn.addEventListener('click', submitPin);

        window.addEventListener('keydown', function (ev) {
            var ov = $('pin-overlay');
            if (!ov || !ov.classList.contains('visible')) return;
            if (ev.key >= '0' && ev.key <= '9') {
                if (appState.pinBuffer.length < 12) {
                    appState.pinBuffer += ev.key;
                    $('pin-err').textContent = '';
                    renderPinDots();
                }
            } else if (ev.key === 'Backspace') {
                appState.pinBuffer = appState.pinBuffer.slice(0, -1);
                renderPinDots();
            } else if (ev.key === 'Enter') {
                submitPin();
            }
        });
    }

    function updateLogoutVisibility() {
        var btn = $('btn-logout');
        if (btn) {
            btn.style.display = (!appState.isLocal && ApiClient.token) ? 'grid' : 'none';
        }
    }

    /* -------------------- Tab Navigation -------------------- */
    function switchTab(tabId, animate) {
        appState.activeTab = tabId;
        document.querySelectorAll('.tab-panel').forEach(function (p) {
            var isTarget = p.id === 'tab-' + tabId;
            p.classList.toggle('active', isTarget);
            p.classList.toggle('tab-anim', isTarget && animate !== false);
        });
        document.querySelectorAll('.nav-item').forEach(function (n) {
            n.classList.toggle('active', n.getAttribute('data-tab') === tabId);
        });

        if (tabId === 'dashboard' && chart) {
            setTimeout(function () { chart.resize(); chart.draw(); }, 40);
        } else if (tabId === 'clients') {
            fetchClients(false);
        } else if (tabId === 'firewall') {
            loadDns();
            if (!appState.appsLoaded) fetchApps(false);
        } else if (tabId === 'settings') {
            loadSettings();
            loadBattery();
        }
    }

    /* -------------------- Dashboard Rendering & Polling -------------------- */
    function renderDashboard(d) {
        if (!d || !d.ok) return;
        appState.dashboard = d;

        var fmtSpd = window.NetDroidCharts.formatSpeed;
        var fmtBytes = window.NetDroidCharts.formatBytes;

        // Top bar status
        $('conn-dot').classList.remove('offline');
        var devLabel = (d.device && (d.device.model || d.device.codename)) || 'NetDroid';
        var androidVer = (d.device && d.device.android) ? (' • Android ' + d.device.android) : '';
        $('brand-sub-text').textContent = devLabel + androidVer;

        // Mode Hero
        var isTeth = d.mode === 'tethering';
        $('hero-mode-title').textContent = isTeth ? 'Tethering Mode Active' : 'Normal Mode Active';
        $('btn-mode-normal').classList.toggle('active', !isTeth);
        $('btn-mode-tethering').classList.toggle('active', isTeth);
        $('btn-mode-tethering').classList.toggle('tethering-active', isTeth);

        // Hero status chips
        $('chip-ttl').textContent = 'TTL ' + d.ttl.current_ipv4 + ' / HL ' + d.ttl.current_ipv6;
        $('chip-ttl').className = 'm3-chip ' + (d.ttl.current_ipv4 === 65 ? 'accent' : '');

        var mangleEl = $('chip-mangle');
        mangleEl.textContent = d.ttl.mangle_active ? 'Mangle Active' : 'Mangle Off';
        mangleEl.className = 'm3-chip ' + (d.ttl.mangle_active ? 'success' : '');

        var bat = d.battery || {};
        var batIcon = (bat.status === 'Charging' || bat.status === 'Full') ? '⚡ ' : '';
        var batText = batIcon + bat.percent + '% • ' + bat.temp_c + '°C';
        var batCls = 'm3-chip';
        if (bat.charging_paused && bat.pause_reason === 'thermal') {
            batText = '🌡 ' + bat.percent + '% • ' + bat.temp_c + '°C • Thermal Pause';
            batCls = 'm3-chip danger';
        } else if (bat.charging_paused) {
            batText = '🛡 ' + bat.percent + '% • ' + bat.temp_c + '°C • ' + (bat.status || 'Idle/Bypass');
            batCls = 'm3-chip accent';
        } else if (bat.policy_active) {
            batText += ' • Limit ' + bat.stop_threshold + '%';
            batCls = Number(bat.temp_c) >= 42 ? 'm3-chip warning' : 'm3-chip success';
        } else if (Number(bat.temp_c) >= 42) {
            batCls = 'm3-chip warning';
        }
        $('chip-battery').textContent = batText;
        $('chip-battery').className = batCls;

        var adChip = $('chip-adblock');
        if (adChip && d.dns) {
            if (d.dns.adblock_enabled || d.dns.force_router_dns) {
                var cnt = Number(d.dns.blocked_domains_count) || 0;
                var cntStr = cnt >= 1000 ? (Math.round(cnt / 1000) + 'K') : String(cnt);
                adChip.textContent = d.dns.adblock_enabled
                    ? ('Adblock ' + cntStr + (d.dns.force_router_dns ? ' • Forced' : ''))
                    : ('DNS: ' + (d.dns.preset || 'Custom'));
                adChip.className = 'm3-chip success';
                adChip.style.display = 'inline-flex';
            } else {
                adChip.style.display = 'none';
            }
        }

        $('chip-procs').textContent = d.device.bg_app_procs + ' Bg Procs' +
            (d.firewall.restricted_apps > 0 ? (' (' + d.firewall.restricted_apps + ' muted)') : '');

        // LAN Access URL chip
        var lanChip = $('chip-lan-url');
        var lanIps = (d.network && d.network.lan_ips) || [];
        if (lanIps.length > 0) {
            var firstIp = lanIps[0].split(':')[1] || lanIps[0];
            var lanUrl = 'http://' + firstIp + ':' + d.port;
            lanChip.textContent = 'LAN: ' + lanUrl;
            lanChip.setAttribute('data-url', lanUrl);
            lanChip.style.display = 'inline-flex';
        } else {
            lanChip.style.display = 'none';
        }

        // Throughput
        var useHs = appState.speedSource === 'hotspot';
        var rxBps = useHs ? d.network.hs_rx_bps : d.network.cell_rx_bps;
        var txBps = useHs ? d.network.hs_tx_bps : d.network.cell_tx_bps;
        var rxTot = useHs ? d.network.hs_rx_total : d.network.cell_rx_total;
        var txTot = useHs ? d.network.hs_tx_total : d.network.cell_tx_total;
        var ifaces = useHs ? d.network.hs_ifaces : d.network.cell_ifaces;

        $('val-rx-speed').textContent = fmtSpd(rxBps);
        $('val-tx-speed').textContent = fmtSpd(txBps);
        $('val-rx-total').textContent = 'Total ' + fmtBytes(rxTot);
        $('val-tx-total').textContent = 'Total ' + fmtBytes(txTot);
        var ifaceList = (ifaces && ifaces !== 'none') ? ifaces.split(',') : [];
        var ifaceShort = ifaceList.length > 1
            ? (ifaceList[ifaceList.length - 1] + ' (+' + (ifaceList.length - 1) + ')')
            : (ifaceList[0] || 'idle');
        var ifaceEl = $('throughput-ifaces');
        ifaceEl.textContent = 'Interface: ' + ifaceShort;
        ifaceEl.title = ifaces || 'idle';

        if (chart) {
            chart.push(rxBps, txBps);
        }

        // Quota summary
        var qd = (d.quota && d.quota.data) || {};
        var sessTot = (Number(qd.session_rx) || 0) + (Number(qd.session_tx) || 0);
        var dayTot = (Number(qd.daily_rx) || 0) + (Number(qd.daily_tx) || 0);
        var monTot = (Number(qd.monthly_rx) || 0) + (Number(qd.monthly_tx) || 0);

        var dayLimitBytes = (Number(d.quota.daily_limit_mb) || 2048) * 1048576;
        var monLimitBytes = (Number(d.quota.monthly_limit_mb) || 30720) * 1048576;
        var warnPct = Number(d.quota.warn_pct) || 80;
        var critPct = Number(d.quota.crit_pct) || 90;

        var dayPct = dayLimitBytes > 0 ? Math.min(100, (dayTot / dayLimitBytes) * 100) : 0;
        var monPct = monLimitBytes > 0 ? Math.min(100, (monTot / monLimitBytes) * 100) : 0;
        var sessPct = dayLimitBytes > 0 ? Math.min(100, (sessTot / dayLimitBytes) * 100) : 0;

        window.NetDroidCharts.updateQuotaRing($('quota-ring-fill'), $('quota-ring-pct'), dayPct, warnPct, critPct);

        $('q-session-val').textContent = fmtBytes(sessTot) + ' (↓' + fmtBytes(qd.session_rx || 0) + ' ↑' + fmtBytes(qd.session_tx || 0) + ')';
        $('q-daily-val').textContent = fmtBytes(dayTot) + ' / ' + fmtBytes(dayLimitBytes);
        $('q-monthly-val').textContent = fmtBytes(monTot) + ' / ' + fmtBytes(monLimitBytes);

        setBar($('bar-session'), sessPct, warnPct, critPct);
        setBar($('bar-daily'), dayPct, warnPct, critPct);
        setBar($('bar-monthly'), monPct, warnPct, critPct);

        // Quota threshold warning banner
        var alertEl = $('quota-alert');
        var maxPct = Math.max(dayPct, monPct);
        var scopeLabel = dayPct >= monPct ? 'Daily' : 'Monthly';
        if (maxPct >= critPct) {
            alertEl.className = 'quota-alert show crit';
            alertEl.textContent = '⚠ ' + scopeLabel + ' data usage reached ' + Math.round(maxPct) + '% of your limit!';
        } else if (maxPct >= warnPct) {
            alertEl.className = 'quota-alert show warn';
            alertEl.textContent = '⚡ ' + scopeLabel + ' data usage reached ' + Math.round(maxPct) + '% warning threshold.';
        } else {
            alertEl.className = 'quota-alert';
        }

        // Quick glance strip
        $('glance-clients').textContent = String(d.network.clients_count || 0);
        $('glance-blocked').textContent = String((d.firewall.blocked_apps || 0) + (d.firewall.blocked_clients || 0));
        $('glance-ram').textContent = d.device.mem_used_mb + ' / ' + d.device.mem_total_mb + ' MB';
        $('glance-uptime').textContent = formatUptime(d.device.uptime_sec);
    }

    function setBar(el, pct, warn, crit) {
        if (!el) return;
        el.style.width = Math.max(2, Math.min(100, pct)).toFixed(1) + '%';
        el.classList.remove('warn', 'crit');
        if (pct >= crit) el.classList.add('crit');
        else if (pct >= warn) el.classList.add('warn');
    }

    function pollDashboard() {
        if (!appState.authenticated || document.hidden) return;
        ApiClient.get('dashboard').then(renderDashboard).catch(function () {
            $('conn-dot').classList.add('offline');
        });
    }

    function startPolling() {
        stopPolling();
        pollDashboard();
        appState.pollTimer = setInterval(pollDashboard, 1800);
        appState.clientTimer = setInterval(function () {
            if (appState.activeTab === 'clients' && appState.authenticated && !document.hidden) {
                fetchClients(false);
            }
        }, 4500);
    }

    function stopPolling() {
        if (appState.pollTimer) clearInterval(appState.pollTimer);
        if (appState.clientTimer) clearInterval(appState.clientTimer);
        appState.pollTimer = null;
        appState.clientTimer = null;
    }

    /* -------------------- Mode Switching -------------------- */
    function switchMode(targetMode) {
        if (appState.modeBusy) return;
        appState.modeBusy = true;
        $('btn-mode-normal').disabled = true;
        $('btn-mode-tethering').disabled = true;
        toast(targetMode === 'tethering'
            ? 'Enabling Tethering Mode (TTL=65 & Battery Saver)...'
            : 'Restoring Normal Mode & background apps...', 'info');

        ApiClient.post('set_mode', { mode: targetMode }).then(function (res) {
            if (res && res.ok) {
                toast(targetMode === 'tethering'
                    ? 'Tethering Mode active! TTL=' + res.current_ttl
                    : 'Normal Mode restored (TTL=' + res.current_ttl + ')', 'success');
                pollDashboard();
                if (appState.activeTab === 'settings') loadSettings();
            } else {
                toast((res && res.error) || 'Failed to switch mode', 'error');
            }
        }).catch(function () {
            toast('Mode switch request failed', 'error');
        }).finally(function () {
            appState.modeBusy = false;
            $('btn-mode-normal').disabled = false;
            $('btn-mode-tethering').disabled = false;
        });
    }

    /* -------------------- Connected Clients Manager -------------------- */
    function deviceIconSvg(host, connType) {
        var h = (host || '').toLowerCase();
        if (connType === 'USB Tethering') {
            return '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2v14"/><path d="M8 6l4-4 4 4"/><circle cx="12" cy="19" r="3"/><path d="M12 12l5-3v-2"/><path d="M12 14l-5-3v-2"/></svg>';
        }
        if (/laptop|pc|desktop|arch|ubuntu|fedora|macbook|win|thinkpad|linux/.test(h)) {
            return '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="12" rx="2"/><path d="M2 20h20"/></svg>';
        }
        return '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="6" y="2" width="12" height="20" rx="3"/><line x1="12" y1="18" x2="12.01" y2="18"/></svg>';
    }

    function fetchClients(forceRefresh) {
        ApiClient.get('clients', forceRefresh ? { refresh: '1' } : null).then(function (res) {
            if (!res || !res.ok) return;
            appState.clients = res.clients || [];
            renderClients();
        }).catch(function () {});
    }

    function renderClients() {
        var list = $('clients-list');
        if (!list) return;
        var clients = appState.clients;
        $('clients-count-badge').textContent = clients.length + (clients.length === 1 ? ' device' : ' devices');

        if (!clients.length) {
            list.innerHTML = '<div class="empty-state">No active hotspot or USB tethered clients detected.<br>Devices connected to your hotspot will appear here automatically.</div>';
            return;
        }

        // Sort: reachable first, then blocked, then hostname
        clients.sort(function (a, b) {
            var rank = function (c) { return c.status === 'REACHABLE' ? 0 : (c.status === 'STALE' ? 1 : 2); };
            return rank(a) - rank(b) || (a.hostname || '').localeCompare(b.hostname || '');
        });

        var html = '';
        clients.forEach(function (c) {
            var stClass = c.status === 'REACHABLE' ? 'reachable' : (c.status === 'STALE' ? 'stale' : 'blocked');
            html += '<div class="client-item' + (c.blocked ? ' blocked' : '') + '">' +
                '<div class="client-top-row">' +
                    '<div class="item-main">' +
                        '<div class="device-avatar">' + deviceIconSvg(c.hostname, c.connection_type) + '</div>' +
                        '<div class="item-info">' +
                            '<div class="item-title">' + escapeHtml(c.hostname || 'Unknown Device') + '</div>' +
                            '<div class="item-meta">' +
                                '<span>' + escapeHtml(c.ipv4 || 'No IPv4') + '</span>' +
                                '<span>' + escapeHtml(c.mac) + '</span>' +
                                (c.ipv6 ? '<span>' + escapeHtml(c.ipv6) + '</span>' : '') +
                            '</div>' +
                        '</div>' +
                    '</div>' +
                    '<div class="client-switch-col">' +
                        '<button type="button" class="m3-switch danger' + (c.blocked ? ' on' : '') + '" ' +
                            'data-block-mac="' + escapeHtml(c.mac) + '" ' +
                            'data-block-ip="' + escapeHtml(c.ipv4 || '') + '" ' +
                            'data-block-host="' + escapeHtml(c.hostname || '') + '" ' +
                            'data-blocked="' + (c.blocked ? '1' : '0') + '" ' +
                            'title="' + (c.blocked ? 'Unblock Internet' : 'Block Internet') + '"></button>' +
                        '<span class="client-switch-lbl">' + (c.blocked ? 'Blocked' : 'Allowed') + '</span>' +
                    '</div>' +
                '</div>' +
                '<div class="item-tags">' +
                    '<span class="tag-pill ' + stClass + '">' + escapeHtml(c.status) + '</span>' +
                    '<span class="tag-pill">' + escapeHtml(c.connection_type) + ' (' + escapeHtml(c.interface) + ')</span>' +
                    (c.blocked ? '<span class="tag-pill blocked">INTERNET BLOCKED</span>' : '') +
                '</div>' +
            '</div>';
        });

        list.innerHTML = html;

        list.querySelectorAll('button[data-block-mac]').forEach(function (sw) {
            sw.addEventListener('click', function () {
                var mac = sw.getAttribute('data-block-mac');
                var ip = sw.getAttribute('data-block-ip');
                var host = sw.getAttribute('data-block-host');
                var currentlyBlocked = sw.getAttribute('data-blocked') === '1';
                var nextBlocked = !currentlyBlocked;

                sw.disabled = true;
                ApiClient.post('set_client_rule', {
                    mac: mac,
                    ip: ip,
                    hostname: host,
                    blocked: nextBlocked ? '1' : '0'
                }).then(function (res) {
                    if (res && res.ok) {
                        toast((nextBlocked ? 'Blocked ' : 'Unblocked ') + (host || mac), nextBlocked ? 'error' : 'success');
                        fetchClients(false);
                        pollDashboard();
                    } else {
                        toast((res && res.error) || 'Failed to update client rule', 'error');
                    }
                }).catch(function () {
                    toast('Failed to update client rule', 'error');
                });
            });
        });
    }

    /* -------------------- Per-App Firewall Manager -------------------- */
    function fetchApps(forceRefresh) {
        var list = $('apps-list');
        if (list && !appState.appsLoaded) {
            list.innerHTML = '<div class="empty-state">Loading installed applications & UIDs...</div>';
        }
        ApiClient.get('apps', forceRefresh ? { refresh: '1' } : null).then(function (res) {
            if (!res || !res.ok) return;
            appState.apps = res.apps || [];
            appState.appsLoaded = true;
            renderApps();
        }).catch(function () {
            if (list) list.innerHTML = '<div class="empty-state">Failed to load installed packages.</div>';
        });
    }

    function renderApps() {
        var list = $('apps-list');
        if (!list) return;

        var q = (appState.appSearch || '').trim().toLowerCase();
        var filter = appState.appFilter;

        var filtered = appState.apps.filter(function (a) {
            if (filter === 'user' && !a.is_user) return false;
            if (filter === 'system' && a.is_user) return false;
            if (filter === 'blocked' && !a.wifi_blocked && !a.mobile_blocked) return false;
            if (q && a.package.toLowerCase().indexOf(q) === -1 && String(a.uid).indexOf(q) === -1) return false;
            return true;
        });

        $('apps-count-badge').textContent = filtered.length + ' / ' + appState.apps.length + ' apps';

        if (!filtered.length) {
            list.innerHTML = '<div class="empty-state">No applications match your current filter.</div>';
            return;
        }

        // Cap initial DOM render to 120 items for buttery scroll on low-end devices unless searching
        var limit = q ? 200 : 120;
        var slice = filtered.slice(0, limit);

        var html = '';
        slice.forEach(function (a) {
            var hasBlock = a.wifi_blocked || a.mobile_blocked;
            var shortName = a.package.split('.').pop();
            html += '<div class="app-item' + (hasBlock ? ' has-block' : '') + '">' +
                '<div class="item-main">' +
                    '<div class="item-info">' +
                        '<div class="item-title">' + escapeHtml(shortName) + '</div>' +
                        '<div class="item-meta">' +
                            '<span>' + escapeHtml(a.package) + '</span>' +
                            '<span>UID ' + a.uid + '</span>' +
                            '<span class="tag-pill">' + (a.is_user ? 'User' : 'System') + '</span>' +
                        '</div>' +
                    '</div>' +
                '</div>' +
                '<div class="fw-toggles">' +
                    '<button type="button" class="fw-pill' + (a.wifi_blocked ? ' blocked' : '') + '" ' +
                        'data-uid="' + a.uid + '" data-pkg="' + escapeHtml(a.package) + '" data-kind="wifi">' +
                        (a.wifi_blocked ? '✕ Wi-Fi' : '✓ Wi-Fi') +
                    '</button>' +
                    '<button type="button" class="fw-pill' + (a.mobile_blocked ? ' blocked' : '') + '" ' +
                        'data-uid="' + a.uid + '" data-pkg="' + escapeHtml(a.package) + '" data-kind="mobile">' +
                        (a.mobile_blocked ? '✕ Mobile' : '✓ Mobile') +
                    '</button>' +
                '</div>' +
            '</div>';
        });

        if (filtered.length > limit) {
            html += '<div class="empty-state">Showing first ' + limit + ' of ' + filtered.length + ' apps. Use search to find a specific package.</div>';
        }

        list.innerHTML = html;

        list.querySelectorAll('button.fw-pill').forEach(function (btn) {
            btn.addEventListener('click', function () {
                var uid = Number(btn.getAttribute('data-uid'));
                var pkg = btn.getAttribute('data-pkg');
                var kind = btn.getAttribute('data-kind');

                var appObj = appState.apps.find(function (x) { return x.uid === uid && x.package === pkg; }) ||
                             appState.apps.find(function (x) { return x.uid === uid; });
                if (!appObj) return;

                var nextWifi = kind === 'wifi' ? !appObj.wifi_blocked : appObj.wifi_blocked;
                var nextMobile = kind === 'mobile' ? !appObj.mobile_blocked : appObj.mobile_blocked;

                // Update all packages sharing the same UID
                appState.apps.forEach(function (x) {
                    if (x.uid === uid) {
                        x.wifi_blocked = nextWifi;
                        x.mobile_blocked = nextMobile;
                    }
                });
                renderApps();

                ApiClient.post('set_app_rule', {
                    uid: uid,
                    package: pkg,
                    wifi: nextWifi ? '1' : '0',
                    mobile: nextMobile ? '1' : '0'
                }).then(function (res) {
                    if (res && res.ok) {
                        pollDashboard();
                    } else {
                        toast((res && res.error) || 'Firewall update failed', 'error');
                        fetchApps(false);
                    }
                }).catch(function () {
                    toast('Firewall update failed', 'error');
                    fetchApps(false);
                });
            });
        });
    }

    /* -------------------- Smart Battery & Charging Controller -------------------- */
    function renderBattery(b) {
        if (!b || !b.ok) return;
        appState.battery = b;

        var badge = $('bat-ctrl-badge');
        if (badge) {
            badge.textContent = b.status || 'Unknown';
            if (b.charging_paused && b.pause_reason === 'thermal') badge.className = 'm3-chip danger';
            else if (b.charging_paused) badge.className = 'm3-chip accent';
            else if (b.policy_active) badge.className = 'm3-chip success';
            else badge.className = 'm3-chip';
        }

        $('bat-tel-curr').textContent = (b.current_ma != null ? b.current_ma : '--') + ' mA';
        var volts = b.voltage_mv ? (Number(b.voltage_mv) / 1000).toFixed(2) + ' V' : '-- V';
        $('bat-tel-volt').textContent = volts;
        $('bat-tel-temp').textContent = (b.temp_c != null ? b.temp_c : '--') + '°C';

        var nodeEl = $('bat-sysfs-node');
        if (nodeEl && b.supported_nodes) {
            var sn = b.supported_nodes;
            if (sn.switch_supported) {
                nodeEl.textContent = 'Sysfs: ' + sn.switch_node + (sn.idle_bypass ? ' (Idle/Bypass)' : ' (Suspend)');
            } else {
                nodeEl.textContent = 'No writable charging sysfs node detected on this kernel';
            }
        }

        $('sw-bat-enabled').classList.toggle('on', !!b.enabled);
        $('sw-bat-teth-only').classList.toggle('on', !!b.tethering_only);

        $('slider-bat-stop').value = b.stop_threshold || 80;
        $('val-bat-stop').textContent = (b.stop_threshold || 80) + '%';
        $('slider-bat-resume').value = b.resume_threshold || 65;
        $('val-bat-resume').textContent = (b.resume_threshold || 65) + '%';
        $('slider-bat-temp').value = b.max_temp || 42;
        $('val-bat-temp').textContent = Number(b.max_temp || 42).toFixed(1) + '°C';

        var currSec = $('bat-current-section');
        if (currSec && b.supported_nodes) {
            currSec.style.display = b.supported_nodes.current_supported ? 'block' : 'none';
        }
        document.querySelectorAll('[data-curr-ma]').forEach(function (btn) {
            btn.classList.toggle('active', Number(btn.getAttribute('data-curr-ma')) === Number(b.current_limit_ma || 0));
        });
    }

    function loadBattery() {
        ApiClient.get('battery').then(renderBattery).catch(function () {});
    }

    function saveBatteryConfig(overrides) {
        var stopVal = parseInt($('slider-bat-stop').value, 10) || 80;
        var resVal = parseInt($('slider-bat-resume').value, 10) || 65;
        if (resVal >= stopVal) {
            resVal = Math.max(30, stopVal - 5);
            $('slider-bat-resume').value = resVal;
            $('val-bat-resume').textContent = resVal + '%';
        }
        var activeCurrBtn = document.querySelector('[data-curr-ma].active');
        var payload = Object.assign({
            enabled: $('sw-bat-enabled').classList.contains('on') ? 'true' : 'false',
            tethering_only: $('sw-bat-teth-only').classList.contains('on') ? 'true' : 'false',
            stop_threshold: stopVal,
            resume_threshold: resVal,
            max_temp: parseFloat($('slider-bat-temp').value) || 42.0,
            current_limit_ma: activeCurrBtn ? Number(activeCurrBtn.getAttribute('data-curr-ma')) : 0
        }, overrides || {});

        ApiClient.post('battery', payload).then(function (r) {
            if (r && r.ok) {
                renderBattery(r);
                pollDashboard();
                toast('Smart charging policy enforced (' + r.status + ')', 'success');
            } else {
                toast((r && r.error) || 'Failed to save charging policy', 'error');
            }
        }).catch(function () {
            toast('Failed to save charging policy', 'error');
        });
    }

    /* -------------------- Network-Wide DNS & Adblock Controller -------------------- */
    function renderDns(d) {
        if (!d || !d.ok) return;
        appState.dns = d;

        var badge = $('dns-status-badge');
        if (badge) {
            if (d.adblock_enabled && d.force_router_dns) {
                badge.textContent = 'Adblock + Forced';
                badge.className = 'm3-chip success';
            } else if (d.adblock_enabled) {
                badge.textContent = 'Adblock Active';
                badge.className = 'm3-chip success';
            } else if (d.force_router_dns) {
                badge.textContent = 'DNS Forced';
                badge.className = 'm3-chip accent';
            } else {
                badge.textContent = 'Off';
                badge.className = 'm3-chip';
            }
        }

        $('sw-adblock').classList.toggle('on', !!d.adblock_enabled);
        $('sw-force-dns').classList.toggle('on', !!d.force_router_dns);

        document.querySelectorAll('[data-dns-preset]').forEach(function (btn) {
            btn.classList.toggle('active', btn.getAttribute('data-dns-preset') === d.preset);
        });

        var customWrap = $('dns-custom-wrap');
        if (customWrap) {
            customWrap.style.display = d.preset === 'custom' ? 'block' : 'none';
        }
        if ($('input-dns-v4') && document.activeElement !== $('input-dns-v4')) {
            $('input-dns-v4').value = d.custom_ipv4 || '';
        }
        if ($('input-dns-v6') && document.activeElement !== $('input-dns-v6')) {
            $('input-dns-v6').value = d.custom_ipv6 || '';
        }

        var cnt = Number(d.blocked_domains_count) || 0;
        $('dns-blocked-count').textContent = cnt.toLocaleString() + ' blocked domains';

        var updText = 'Blocklist not downloaded yet';
        if (d.updating) {
            updText = 'Downloading & merging blocklist...';
        } else if (d.last_error) {
            updText = 'Last error: ' + d.last_error;
        } else if (d.last_updated && Number(d.last_updated) > 0) {
            var dt = new Date(Number(d.last_updated) * 1000);
            updText = 'Updated ' + dt.toLocaleString() + ' • Upstream ' + (d.active_upstream_v4 || '');
        } else if (d.active_upstream_v4) {
            updText = 'Upstream: ' + d.active_upstream_v4;
        }
        $('dns-last-updated').textContent = updText;

        var updBtn = $('btn-update-dns-lists');
        if (updBtn) {
            updBtn.disabled = !!d.updating;
            updBtn.textContent = d.updating ? 'Updating...' : 'Update Lists Now';
        }

        renderDomainChips($('dns-wl-chips'), d.whitelist || [], 'allow', 'remove_whitelist');
        renderDomainChips($('dns-bl-chips'), d.blacklist || [], 'block', 'remove_blacklist');
    }

    function renderDomainChips(container, list, cls, removeParam) {
        if (!container) return;
        if (!list.length) {
            container.innerHTML = '<span style="font-size:0.72rem;color:var(--md-on-surface-variant);">None configured</span>';
            return;
        }
        var html = '';
        list.forEach(function (dom) {
            html += '<span class="domain-chip ' + cls + '">' +
                escapeHtml(dom) +
                '<button type="button" data-rm-dom="' + escapeHtml(dom) + '" aria-label="Remove ' + escapeHtml(dom) + '">&times;</button>' +
            '</span>';
        });
        container.innerHTML = html;
        container.querySelectorAll('button[data-rm-dom]').forEach(function (btn) {
            btn.addEventListener('click', function () {
                var dom = btn.getAttribute('data-rm-dom');
                var p = {};
                p[removeParam] = dom;
                ApiClient.post('dns', p).then(function (r) {
                    if (r && r.ok) {
                        renderDns(r);
                        toast('Removed ' + dom, 'success');
                    }
                });
            });
        });
    }

    function loadDns() {
        ApiClient.get('dns').then(function (r) {
            renderDns(r);
            if (r && r.updating && !appState.dnsPollTimer) {
                pollDnsUpdate();
            }
        }).catch(function () {});
    }

    function pollDnsUpdate() {
        clearInterval(appState.dnsPollTimer);
        appState.dnsPollTimer = setInterval(function () {
            ApiClient.get('dns').then(function (r) {
                renderDns(r);
                if (r && !r.updating) {
                    clearInterval(appState.dnsPollTimer);
                    appState.dnsPollTimer = null;
                    pollDashboard();
                    if (r.last_error) toast(r.last_error, 'error');
                    else toast('Blocklist updated: ' + (r.blocked_domains_count || 0).toLocaleString() + ' domains', 'success');
                }
            }).catch(function () {
                clearInterval(appState.dnsPollTimer);
                appState.dnsPollTimer = null;
            });
        }, 2000);
    }

    /* -------------------- Settings Manager -------------------- */
    function loadSettings() {
        ApiClient.get('settings').then(function (s) {
            if (!s || !s.ok) return;
            appState.settings = s;
            var mi = s.mode_info || {};

            // TTL controls
            $('input-custom-ttl').value = mi.configured_ttl || 65;
            document.querySelectorAll('.ttl-pill').forEach(function (p) {
                p.classList.toggle('active', Number(p.getAttribute('data-ttl')) === Number(mi.configured_ttl));
            });
            $('sw-mangle').classList.toggle('on', !!mi.mangle_enabled);
            $('sw-ttl-standalone').classList.toggle('on', !!mi.ttl_standalone);
            $('sw-autosync').classList.toggle('on', !!mi.auto_sync_disable);
            $('sw-bpf-offload').classList.toggle('on', !!mi.bpf_offload_disabled);

            var xtInfo = $('xt-support-badge');
            if (xtInfo) {
                var ok = mi.xt_ttl_supported || mi.xt_hl_supported;
                xtInfo.textContent = 'Kernel: ' + (mi.xt_ttl_supported ? 'xt_TTL ✓' : 'xt_TTL ✕') +
                    ' • ' + (mi.xt_hl_supported ? 'xt_HL ✓' : 'xt_HL ✕');
                xtInfo.className = 'm3-chip ' + (ok ? 'success' : 'warning');
            }

            // Quota controls (display GB in inputs with 2 decimal support)
            $('input-daily-gb').value = ((Number(s.quota_daily_mb) || 2048) / 1024).toFixed(1);
            $('input-monthly-gb').value = ((Number(s.quota_monthly_mb) || 30720) / 1024).toFixed(1);
            $('input-warn-pct').value = s.quota_warn_pct || 80;
            $('input-crit-pct').value = s.quota_crit_pct || 90;

            // Server & Security
            $('input-port').value = s.port || 8765;
            $('sw-auth-enabled').classList.toggle('on', !!s.auth_enabled);
            var bnd = $('boundary-badge');
            if (bnd) {
                bnd.textContent = s.security_boundary ? 'WAN Blocked (rmnet/ccmni/wwan)' : 'Boundary Inactive';
                bnd.className = 'm3-chip ' + (s.security_boundary ? 'success' : 'danger');
            }
            var pinNote = $('pin-status-note');
            if (pinNote) {
                pinNote.textContent = s.pin_is_default
                    ? 'Using default PIN (1234). Set a custom PIN for LAN security.'
                    : 'Custom PIN is configured.';
            }
        }).catch(function () {});
    }

    function wireControls() {
        // Navigation
        document.querySelectorAll('.nav-item').forEach(function (btn) {
            btn.addEventListener('click', function () {
                switchTab(btn.getAttribute('data-tab'));
            });
        });

        // Mode switcher
        $('btn-mode-normal').addEventListener('click', function () { switchMode('normal'); });
        $('btn-mode-tethering').addEventListener('click', function () { switchMode('tethering'); });

        // Copy LAN URL chip
        $('chip-lan-url').addEventListener('click', function () {
            var url = $('chip-lan-url').getAttribute('data-url');
            if (!url) return;
            if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(url).then(function () {
                    toast('Copied LAN URL: ' + url, 'success');
                }).catch(function () { toast(url, 'info'); });
            } else {
                toast(url, 'info');
            }
        });

        // Throughput source switch (Cellular vs Hotspot)
        $('src-cellular').addEventListener('click', function () {
            appState.speedSource = 'cellular';
            $('src-cellular').classList.add('active');
            $('src-hotspot').classList.remove('active');
            if (chart) chart.reset();
            if (appState.dashboard) renderDashboard(appState.dashboard);
        });
        $('src-hotspot').addEventListener('click', function () {
            appState.speedSource = 'hotspot';
            $('src-hotspot').classList.add('active');
            $('src-cellular').classList.remove('active');
            if (chart) chart.reset();
            if (appState.dashboard) renderDashboard(appState.dashboard);
        });

        // Reset session quota button on Dashboard
        $('btn-reset-session').addEventListener('click', function () {
            ApiClient.post('reset_quota', { scope: 'session' }).then(function (r) {
                if (r && r.ok) {
                    toast('Session usage counter reset', 'success');
                    pollDashboard();
                }
            });
        });

        // Clients refresh & manual block
        $('btn-refresh-clients').addEventListener('click', function () {
            fetchClients(true);
            toast('Refreshing connected clients...', 'info');
        });

        $('btn-manual-block').addEventListener('click', function () {
            var mac = ($('input-block-mac').value || '').trim();
            var ip = ($('input-block-ip').value || '').trim();
            if (!mac && !ip) {
                toast('Enter a MAC or IPv4 address', 'error');
                return;
            }
            ApiClient.post('set_client_rule', { mac: mac, ip: ip, hostname: 'Manual Rule', blocked: '1' })
                .then(function (r) {
                    if (r && r.ok) {
                        $('input-block-mac').value = '';
                        $('input-block-ip').value = '';
                        toast('Client blocked on FORWARD chain', 'success');
                        fetchClients(false);
                        pollDashboard();
                    } else {
                        toast((r && r.error) || 'Invalid MAC/IP', 'error');
                    }
                });
        });

        // Firewall search, filter chips, refresh, clear
        $('input-app-search').addEventListener('input', function (e) {
            appState.appSearch = e.target.value;
            renderApps();
        });

        document.querySelectorAll('.filter-chip[data-filter]').forEach(function (chip) {
            chip.addEventListener('click', function () {
                appState.appFilter = chip.getAttribute('data-filter');
                document.querySelectorAll('.filter-chip[data-filter]').forEach(function (c) {
                    c.classList.toggle('active', c === chip);
                });
                renderApps();
            });
        });

        $('btn-refresh-apps').addEventListener('click', function () {
            fetchApps(true);
            toast('Refreshing package list...', 'info');
        });

        $('btn-clear-fw').addEventListener('click', function () {
            if (!confirm('Clear all per-app and LAN client firewall blocks?')) return;
            ApiClient.post('clear_firewall').then(function (r) {
                if (r && r.ok) {
                    toast('All firewall rules cleared', 'success');
                    fetchApps(false);
                    fetchClients(false);
                    pollDashboard();
                }
            });
        });

        // Smart Charging Control events
        $('sw-bat-enabled').addEventListener('click', function () {
            $('sw-bat-enabled').classList.toggle('on');
            saveBatteryConfig();
        });
        $('sw-bat-teth-only').addEventListener('click', function () {
            $('sw-bat-teth-only').classList.toggle('on');
            saveBatteryConfig();
        });
        $('slider-bat-stop').addEventListener('input', function () {
            var stopVal = parseInt($('slider-bat-stop').value, 10);
            $('val-bat-stop').textContent = stopVal + '%';
            var resVal = parseInt($('slider-bat-resume').value, 10);
            if (resVal >= stopVal) {
                var clamped = Math.max(30, stopVal - 5);
                $('slider-bat-resume').value = clamped;
                $('val-bat-resume').textContent = clamped + '%';
            }
        });
        $('slider-bat-resume').addEventListener('input', function () {
            var stopVal = parseInt($('slider-bat-stop').value, 10);
            var resVal = parseInt($('slider-bat-resume').value, 10);
            if (resVal >= stopVal) {
                resVal = Math.max(30, stopVal - 5);
                $('slider-bat-resume').value = resVal;
            }
            $('val-bat-resume').textContent = resVal + '%';
        });
        $('slider-bat-temp').addEventListener('input', function () {
            $('val-bat-temp').textContent = parseFloat($('slider-bat-temp').value).toFixed(1) + '°C';
        });
        document.querySelectorAll('[data-curr-ma]').forEach(function (btn) {
            btn.addEventListener('click', function () {
                document.querySelectorAll('[data-curr-ma]').forEach(function (b) { b.classList.remove('active'); });
                btn.classList.add('active');
                saveBatteryConfig();
            });
        });
        $('btn-save-battery').addEventListener('click', function () { saveBatteryConfig(); });

        // Network-Wide DNS & Adblock events
        $('sw-adblock').addEventListener('click', function () {
            var next = !$('sw-adblock').classList.contains('on');
            $('sw-adblock').classList.toggle('on', next);
            ApiClient.post('dns', { adblock_enabled: next ? 'true' : 'false' }).then(function (r) {
                if (r && r.ok) {
                    renderDns(r);
                    pollDashboard();
                    toast(next ? 'Network-Wide Adblock enabled' : 'Network-Wide Adblock disabled', 'success');
                }
            });
        });
        $('sw-force-dns').addEventListener('click', function () {
            var next = !$('sw-force-dns').classList.contains('on');
            $('sw-force-dns').classList.toggle('on', next);
            ApiClient.post('dns', { force_router_dns: next ? 'true' : 'false' }).then(function (r) {
                if (r && r.ok) {
                    renderDns(r);
                    pollDashboard();
                    toast(next ? 'Force Router DNS active (port 53 redirected, DoT 853 blocked)' : 'Force Router DNS disabled', 'success');
                }
            });
        });
        document.querySelectorAll('[data-dns-preset]').forEach(function (btn) {
            btn.addEventListener('click', function () {
                var preset = btn.getAttribute('data-dns-preset');
                document.querySelectorAll('[data-dns-preset]').forEach(function (b) { b.classList.remove('active'); });
                btn.classList.add('active');
                $('dns-custom-wrap').style.display = preset === 'custom' ? 'block' : 'none';
                if (preset !== 'custom') {
                    ApiClient.post('dns', { preset: preset }).then(function (r) {
                        if (r && r.ok) {
                            renderDns(r);
                            toast('Upstream DNS set to ' + preset, 'success');
                        }
                    });
                }
            });
        });
        $('btn-save-custom-dns').addEventListener('click', function () {
            var v4 = ($('input-dns-v4').value || '').trim();
            var v6 = ($('input-dns-v6').value || '').trim();
            ApiClient.post('dns', { preset: 'custom', custom_ipv4: v4, custom_ipv6: v6 }).then(function (r) {
                if (r && r.ok) {
                    renderDns(r);
                    toast('Custom DNS saved & applied', 'success');
                } else {
                    toast((r && r.error) || 'Invalid custom DNS IP', 'error');
                }
            });
        });
        $('btn-update-dns-lists').addEventListener('click', function () {
            $('btn-update-dns-lists').disabled = true;
            $('btn-update-dns-lists').textContent = 'Updating...';
            $('dns-last-updated').textContent = 'Downloading & merging blocklist...';
            ApiClient.post('dns_update_lists', { async: '1' }).then(function (r) {
                if (r && r.ok) {
                    renderDns(r);
                    pollDnsUpdate();
                } else {
                    toast((r && r.error) || 'Failed to start update', 'error');
                    loadDns();
                }
            }).catch(function () {
                toast('Blocklist update request failed', 'error');
                loadDns();
            });
        });
        $('btn-add-wl').addEventListener('click', function () {
            var dom = ($('input-wl-domain').value || '').trim();
            if (!dom) return;
            ApiClient.post('dns', { add_whitelist: dom }).then(function (r) {
                if (r && r.ok) {
                    $('input-wl-domain').value = '';
                    renderDns(r);
                    toast('Whitelisted ' + dom, 'success');
                } else {
                    toast((r && r.error) || 'Invalid domain', 'error');
                }
            });
        });
        $('btn-add-bl').addEventListener('click', function () {
            var dom = ($('input-bl-domain').value || '').trim();
            if (!dom) return;
            ApiClient.post('dns', { add_blacklist: dom }).then(function (r) {
                if (r && r.ok) {
                    $('input-bl-domain').value = '';
                    renderDns(r);
                    toast('Blacklisted ' + dom, 'success');
                } else {
                    toast((r && r.error) || 'Invalid domain', 'error');
                }
            });
        });

        // Settings: TTL presets & custom apply
        document.querySelectorAll('.ttl-pill').forEach(function (pill) {
            pill.addEventListener('click', function () {
                var val = pill.getAttribute('data-ttl');
                $('input-custom-ttl').value = val;
                applyTtlSettings();
            });
        });
        $('btn-apply-ttl').addEventListener('click', applyTtlSettings);

        $('sw-mangle').addEventListener('click', function () {
            $('sw-mangle').classList.toggle('on');
            applyTtlSettings();
        });
        $('sw-ttl-standalone').addEventListener('click', function () {
            $('sw-ttl-standalone').classList.toggle('on');
            applyTtlSettings();
        });

        $('sw-autosync').addEventListener('click', function () {
            var next = !$('sw-autosync').classList.contains('on');
            $('sw-autosync').classList.toggle('on', next);
            ApiClient.post('save_settings', { auto_sync_disable: next ? '1' : '0' })
                .then(function () { toast('Auto-sync preference saved', 'success'); });
        });

        $('sw-bpf-offload').addEventListener('click', function () {
            var next = !$('sw-bpf-offload').classList.contains('on');
            $('sw-bpf-offload').classList.toggle('on', next);
            ApiClient.post('save_settings', { bpf_offload_disable: next ? '1' : '0' })
                .then(function () {
                    toast(next ? 'BPF tethering offload disabled (strict iptables)' : 'BPF tethering offload restored', 'success');
                });
        });

        // Settings: Save Quota Limits
        $('btn-save-quota').addEventListener('click', function () {
            var dailyMb = Math.round((parseFloat($('input-daily-gb').value) || 2) * 1024);
            var monthlyMb = Math.round((parseFloat($('input-monthly-gb').value) || 30) * 1024);
            var warnPct = parseInt($('input-warn-pct').value, 10) || 80;
            var critPct = parseInt($('input-crit-pct').value, 10) || 90;
            ApiClient.post('save_settings', {
                quota_daily_mb: dailyMb,
                quota_monthly_mb: monthlyMb,
                quota_warn_pct: warnPct,
                quota_crit_pct: critPct
            }).then(function (r) {
                if (r && r.ok) {
                    toast('Quota limits updated', 'success');
                    pollDashboard();
                } else {
                    toast((r && r.error) || 'Invalid quota values', 'error');
                }
            });
        });

        ['daily', 'monthly'].forEach(function (sc) {
            var b = $('btn-reset-' + sc);
            if (b) {
                b.addEventListener('click', function () {
                    ApiClient.post('reset_quota', { scope: sc }).then(function (r) {
                        if (r && r.ok) {
                            toast('Reset ' + sc + ' quota counter', 'success');
                            pollDashboard();
                        }
                    });
                });
            }
        });

        // Settings: Server Port, Auth & PIN
        $('sw-auth-enabled').addEventListener('click', function () {
            var next = !$('sw-auth-enabled').classList.contains('on');
            $('sw-auth-enabled').classList.toggle('on', next);
            ApiClient.post('save_settings', { auth_enabled: next ? '1' : '0' })
                .then(function () {
                    toast(next ? 'LAN PIN authentication enabled' : 'LAN PIN authentication disabled', 'success');
                });
        });

        $('btn-save-port').addEventListener('click', function () {
            var port = parseInt($('input-port').value, 10);
            if (!port || port < 1024 || port > 65535) {
                toast('Port must be between 1024 and 65535', 'error');
                return;
            }
            ApiClient.post('save_settings', { port: port }).then(function (r) {
                if (r && r.ok) {
                    toast(r.port_changed ? ('Server moving to port ' + port + '...') : 'Port unchanged', 'success');
                    if (r.port_changed && !isKsuNative()) {
                        setTimeout(function () {
                            location.href = location.protocol + '//' + location.hostname + ':' + port + '/';
                        }, 1800);
                    }
                } else {
                    toast((r && r.error) || 'Failed to update port', 'error');
                }
            });
        });

        $('btn-change-pin').addEventListener('click', function () {
            var curPin = ($('input-cur-pin').value || '').trim();
            var newPin = ($('input-new-pin').value || '').trim();
            if (!/^\d{4,12}$/.test(newPin)) {
                toast('New PIN must be 4 to 12 digits', 'error');
                return;
            }
            ApiClient.post('change_pin', { current_pin: curPin, new_pin: newPin }).then(function (r) {
                if (r && r.ok) {
                    $('input-cur-pin').value = '';
                    $('input-new-pin').value = '';
                    toast('Security PIN updated!', 'success');
                    loadSettings();
                } else {
                    toast((r && r.error) || 'Failed to change PIN', 'error');
                }
            });
        });

        $('btn-restart-server').addEventListener('click', function () {
            ApiClient.post('restart_server').then(function (r) {
                if (r && r.ok) toast('Restarting NetDroid HTTP daemon...', 'info');
            });
        });

        $('btn-logout').addEventListener('click', function () {
            ApiClient.post('logout').finally(function () {
                ApiClient.setToken('');
                stopPolling();
                updateLogoutVisibility();
                showPinOverlay({ default_pin: false });
            });
        });

        // Pause polling when tab hidden
        document.addEventListener('visibilitychange', function () {
            if (!document.hidden && appState.authenticated) {
                pollDashboard();
            }
        });
    }

    function applyTtlSettings() {
        var ttl = parseInt($('input-custom-ttl').value, 10);
        if (!ttl || ttl < 1 || ttl > 255) {
            toast('TTL must be between 1 and 255', 'error');
            return;
        }
        var mangle = $('sw-mangle').classList.contains('on') ? '1' : '0';
        var standalone = $('sw-ttl-standalone').classList.contains('on') ? '1' : '0';

        ApiClient.post('set_ttl', { ttl: ttl, mangle: mangle, standalone: standalone }).then(function (r) {
            if (r && r.ok) {
                toast('Applied TTL=' + r.current_ttl + ' / HL=' + r.current_hop_limit, 'success');
                loadSettings();
                pollDashboard();
            } else {
                toast((r && r.error) || 'Failed to apply TTL', 'error');
            }
        });
    }

    /* -------------------- Bootstrapping -------------------- */
    function boot() {
        ApiClient.loadToken();
        chart = new window.NetDroidCharts.ThroughputChart($('throughput-canvas'), $('chart-tooltip'), 48);

        window.NetDroidTheme.init(ApiClient, function () {
            if (chart) chart.draw();
        }, toast);

        setupPinKeypad();
        wireControls();

        // Check hash for initial tab (#clients, #firewall, #settings)
        var initialHash = (location.hash || '').replace('#', '');
        if (/^(dashboard|clients|firewall|settings)$/.test(initialHash)) {
            switchTab(initialHash, false);
        }

        // Check authentication status
        ApiClient.get('auth_status').then(function (info) {
            appState.isLocal = !!(info && info.is_local);
            updateLogoutVisibility();

            if (info && info.authenticated) {
                appState.authenticated = true;
                hidePinOverlay();
                startPolling();
                loadSettings();
                loadBattery();
                if (appState.activeTab === 'clients') fetchClients(false);
                if (appState.activeTab === 'firewall') { loadDns(); fetchApps(false); }
            } else {
                showPinOverlay(info || {});
            }
        }).catch(function () {
            $('conn-dot').classList.add('offline');
            $('brand-sub-text').textContent = 'Unable to reach NetDroid daemon';
        });
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', boot);
    } else {
        boot();
    }
})();
