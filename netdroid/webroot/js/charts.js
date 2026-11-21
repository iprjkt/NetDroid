/* ==========================================================================
   NetDroid — Real-Time Throughput Canvas Chart & SVG Quota Ring Engine
   ========================================================================== */

(function (global) {
    'use strict';

    function formatSpeed(bps) {
        var v = Number(bps) || 0;
        if (v < 0) v = 0;
        if (v >= 1048576) return (v / 1048576).toFixed(2) + ' MB/s';
        if (v >= 1024) return (v / 1024).toFixed(1) + ' KB/s';
        return Math.round(v) + ' B/s';
    }

    function formatBytes(bytes) {
        var v = Number(bytes) || 0;
        if (v < 0) v = 0;
        if (v >= 1073741824) return (v / 1073741824).toFixed(2) + ' GB';
        if (v >= 1048576) return (v / 1048576).toFixed(1) + ' MB';
        if (v >= 1024) return (v / 1024).toFixed(1) + ' KB';
        return Math.round(v) + ' B';
    }

    function cssVar(name, fallback) {
        var val = getComputedStyle(document.documentElement).getPropertyValue(name);
        return val ? val.trim() : fallback;
    }

    function hexToRgba(color, alpha) {
        if (!color) return 'rgba(168,199,250,' + alpha + ')';
        if (color.indexOf('rgb') === 0) {
            var m = color.match(/\d+/g);
            if (m && m.length >= 3) {
                return 'rgba(' + m[0] + ',' + m[1] + ',' + m[2] + ',' + alpha + ')';
            }
        }
        var hex = color.replace('#', '');
        if (hex.length === 3) {
            hex = hex[0] + hex[0] + hex[1] + hex[1] + hex[2] + hex[2];
        }
        var num = parseInt(hex, 16);
        if (isNaN(num)) return 'rgba(168,199,250,' + alpha + ')';
        return 'rgba(' + ((num >> 16) & 255) + ',' + ((num >> 8) & 255) + ',' + (num & 255) + ',' + alpha + ')';
    }

    function ThroughputChart(canvasEl, tooltipEl, maxPoints) {
        this.canvas = canvasEl;
        this.tooltip = tooltipEl;
        this.ctx = canvasEl ? canvasEl.getContext('2d') : null;
        this.maxPoints = maxPoints || 48;
        this.rx = new Array(this.maxPoints).fill(0);
        this.tx = new Array(this.maxPoints).fill(0);
        this.hoverIndex = -1;

        var self = this;
        if (this.canvas) {
            this.resize();
            window.addEventListener('resize', function () {
                self.resize();
                self.draw();
            });
            var onMove = function (evt) {
                var rect = self.canvas.getBoundingClientRect();
                var clientX = evt.touches ? evt.touches[0].clientX : evt.clientX;
                var x = clientX - rect.left;
                var padL = 12, padR = 12;
                var w = Math.max(1, rect.width - padL - padR);
                var ratio = Math.max(0, Math.min(1, (x - padL) / w));
                self.hoverIndex = Math.round(ratio * (self.maxPoints - 1));
                self.draw();
            };
            var onLeave = function () {
                self.hoverIndex = -1;
                if (self.tooltip) self.tooltip.classList.remove('visible');
                self.draw();
            };
            this.canvas.addEventListener('mousemove', onMove);
            this.canvas.addEventListener('touchmove', onMove, { passive: true });
            this.canvas.addEventListener('mouseleave', onLeave);
            this.canvas.addEventListener('touchend', onLeave);
        }
    }

    ThroughputChart.prototype.resize = function () {
        if (!this.canvas || !this.ctx) return;
        var rect = this.canvas.getBoundingClientRect();
        if (rect.width === 0 || rect.height === 0) return;
        var dpr = Math.min(window.devicePixelRatio || 1, 2);
        this.canvas.width = Math.round(rect.width * dpr);
        this.canvas.height = Math.round(rect.height * dpr);
        this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        this.width = rect.width;
        this.height = rect.height;
    };

    ThroughputChart.prototype.reset = function () {
        this.rx = new Array(this.maxPoints).fill(0);
        this.tx = new Array(this.maxPoints).fill(0);
        this.draw();
    };

    ThroughputChart.prototype.push = function (rxBps, txBps) {
        this.rx.push(Math.max(0, Number(rxBps) || 0));
        this.tx.push(Math.max(0, Number(txBps) || 0));
        if (this.rx.length > this.maxPoints) this.rx.shift();
        if (this.tx.length > this.maxPoints) this.tx.shift();
        this.draw();
    };

    ThroughputChart.prototype.drawSeries = function (data, maxVal, color, padL, padT, plotW, plotH, fillAlpha) {
        var ctx = this.ctx;
        var n = data.length;
        if (n < 2) return;

        var pts = [];
        for (var i = 0; i < n; i++) {
            var x = padL + (i / (n - 1)) * plotW;
            var y = padT + plotH - (Math.min(data[i], maxVal) / maxVal) * plotH;
            pts.push({ x: x, y: y });
        }

        // Smooth curve path using quadratic midpoints
        ctx.beginPath();
        ctx.moveTo(pts[0].x, pts[0].y);
        for (var j = 1; j < pts.length - 1; j++) {
            var xc = (pts[j].x + pts[j + 1].x) * 0.5;
            var yc = (pts[j].y + pts[j + 1].y) * 0.5;
            ctx.quadraticCurveTo(pts[j].x, pts[j].y, xc, yc);
        }
        ctx.lineTo(pts[pts.length - 1].x, pts[pts.length - 1].y);

        // Stroke
        ctx.strokeStyle = color;
        ctx.lineWidth = 2.6;
        ctx.lineJoin = 'round';
        ctx.lineCap = 'round';
        ctx.stroke();

        // Gradient area fill
        ctx.lineTo(pts[pts.length - 1].x, padT + plotH);
        ctx.lineTo(pts[0].x, padT + plotH);
        ctx.closePath();

        var grad = ctx.createLinearGradient(0, padT, 0, padT + plotH);
        grad.addColorStop(0, hexToRgba(color, fillAlpha));
        grad.addColorStop(1, hexToRgba(color, 0.0));
        ctx.fillStyle = grad;
        ctx.fill();
    };

    ThroughputChart.prototype.draw = function () {
        if (!this.ctx || !this.width || !this.height) {
            this.resize();
            if (!this.width) return;
        }
        var ctx = this.ctx;
        var w = this.width;
        var h = this.height;
        ctx.clearRect(0, 0, w, h);

        var padL = 12, padR = 12, padT = 22, padB = 14;
        var plotW = Math.max(10, w - padL - padR);
        var plotH = Math.max(10, h - padT - padB);

        var peak = 16384; // Minimum scale 16 KB/s so idle line stays clean
        for (var i = 0; i < this.rx.length; i++) {
            if (this.rx[i] > peak) peak = this.rx[i];
            if (this.tx[i] > peak) peak = this.tx[i];
        }
        var maxVal = peak * 1.18;

        var primary = cssVar('--md-primary', '#a8c7fa');
        var tertiary = cssVar('--md-tertiary', '#f2b8f5');
        var textMuted = cssVar('--md-on-surface-variant', '#b8c0d0');
        var gridColor = cssVar('--md-outline', 'rgba(255,255,255,0.12)');

        // Subtle horizontal gridlines + scale labels
        ctx.strokeStyle = gridColor;
        ctx.lineWidth = 1;
        ctx.font = '600 10px -apple-system, BlinkMacSystemFont, sans-serif';
        ctx.fillStyle = textMuted;
        ctx.textAlign = 'right';

        var steps = 3;
        for (var s = 0; s <= steps; s++) {
            var y = padT + (s / steps) * plotH;
            ctx.beginPath();
            ctx.moveTo(padL, y);
            ctx.lineTo(w - padR, y);
            ctx.stroke();

            if (s < steps) {
                var val = maxVal * (1 - s / steps);
                ctx.fillText(formatSpeed(val), w - padR - 4, y - 4);
            }
        }

        // Draw Upload first, then Download on top
        this.drawSeries(this.tx, maxVal, tertiary, padL, padT, plotW, plotH, 0.24);
        this.drawSeries(this.rx, maxVal, primary, padL, padT, plotW, plotH, 0.34);

        // Hover crosshair & tooltip
        if (this.hoverIndex >= 0 && this.hoverIndex < this.rx.length) {
            var hx = padL + (this.hoverIndex / (this.rx.length - 1)) * plotW;
            var hyRx = padT + plotH - (Math.min(this.rx[this.hoverIndex], maxVal) / maxVal) * plotH;
            var hyTx = padT + plotH - (Math.min(this.tx[this.hoverIndex], maxVal) / maxVal) * plotH;

            ctx.strokeStyle = hexToRgba(primary, 0.55);
            ctx.lineWidth = 1.2;
            ctx.setLineDash([4, 4]);
            ctx.beginPath();
            ctx.moveTo(hx, padT);
            ctx.lineTo(hx, padT + plotH);
            ctx.stroke();
            ctx.setLineDash([]);

            ctx.fillStyle = primary;
            ctx.beginPath();
            ctx.arc(hx, hyRx, 4.5, 0, Math.PI * 2);
            ctx.fill();

            ctx.fillStyle = tertiary;
            ctx.beginPath();
            ctx.arc(hx, hyTx, 4, 0, Math.PI * 2);
            ctx.fill();

            if (this.tooltip) {
                this.tooltip.textContent = 'DL ' + formatSpeed(this.rx[this.hoverIndex]) + '  •  UL ' + formatSpeed(this.tx[this.hoverIndex]);
                this.tooltip.classList.add('visible');
            }
        }
    };

    // Animated SVG Quota Ring updater
    function updateQuotaRing(circleEl, pctEl, percent, warnPct, critPct) {
        if (!circleEl) return;
        var radius = Number(circleEl.getAttribute('r')) || 52;
        var circ = 2 * Math.PI * radius;
        var clamped = Math.max(0, Math.min(100, Number(percent) || 0));
        circleEl.style.strokeDasharray = circ.toFixed(2);
        circleEl.style.strokeDashoffset = (circ * (1 - clamped / 100)).toFixed(2);

        if (clamped >= (critPct || 90)) {
            circleEl.style.stroke = cssVar('--md-error-solid', '#ef5350');
        } else if (clamped >= (warnPct || 80)) {
            circleEl.style.stroke = cssVar('--md-warning', '#ffcf56');
        } else {
            circleEl.style.stroke = cssVar('--md-primary', '#a8c7fa');
        }

        if (pctEl) {
            pctEl.textContent = Math.round(clamped) + '%';
        }
    }

    global.NetDroidCharts = {
        ThroughputChart: ThroughputChart,
        updateQuotaRing: updateQuotaRing,
        formatSpeed: formatSpeed,
        formatBytes: formatBytes
    };
})(window);
