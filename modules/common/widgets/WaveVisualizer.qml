import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Effects

Canvas { // Visualizer
    id: root
    property list<var> points
    property list<var> smoothPoints
    property real maxVisualizerValue: 850
    property int smoothing: 1
    property real nonLinearCurve: 0.72
    property bool live: true
    property color color: Appearance.m3colors.m3primary
    property real fillOpacity: 0.15
    property real bottomFillOpacity: -1
    property real strokeOpacity: 0
    property real strokeWidth: 0
    property bool smoothCurve: false
    property real effectSaturation: 0.2
    property real effectBlur: 1
    property int effectBlurMax: 7

    onPointsChanged: () => {
        root.requestPaint()
    }

    onPaint: {
        var ctx = getContext("2d");
        ctx.clearRect(0, 0, width, height);

        var points = root.points;
        var maxVal = root.maxVisualizerValue || 1;
        var h = height;
        var w = width;
        var n = points.length;
        if (n < 2 || h <= 0 || w <= 0) return;

        // Smoothing: simple moving average (optional)
        var smoothWindow = root.smoothing; // adjust for more/less smoothing
        root.smoothPoints = [];
        var maxPoint = 0;
        for (var i = 0; i < n; ++i) {
            var sum = 0, count = 0;
            for (var j = -smoothWindow; j <= smoothWindow; ++j) {
                var idx = Math.max(0, Math.min(n - 1, i + j));
                sum += points[idx];
                count++;
            }
            var avg = root.live ? (sum / count) : 0;
            if (avg > maxPoint) maxPoint = avg;
            root.smoothPoints.push(avg);
        }
        if (!root.live || maxPoint <= 0.001) return;

        var padTop = root.strokeWidth > 0 ? root.strokeWidth : 0;
        var usableH = Math.max(1, h - padTop);
        var coords = [];
        for (var i = 0; i < n; ++i) {
            var x = i * w / (n - 1);
            var norm = Math.min(1.0, Math.max(0.0, root.smoothPoints[i] / maxVal));
            var scaled = Math.pow(norm, root.nonLinearCurve);
            var y = h - scaled * usableH;
            coords.push({ x: x, y: y });
        }

        function traceCrest(startMove) {
            if (startMove) ctx.moveTo(coords[0].x, coords[0].y);
            else ctx.lineTo(coords[0].x, coords[0].y);

            if (root.smoothCurve && n >= 3) {
                for (var k = 1; k < n - 1; ++k) {
                    var xc = (coords[k].x + coords[k + 1].x) * 0.5;
                    var yc = (coords[k].y + coords[k + 1].y) * 0.5;
                    ctx.quadraticCurveTo(coords[k].x, coords[k].y, xc, yc);
                }
                ctx.lineTo(coords[n - 1].x, coords[n - 1].y);
            } else {
                for (var k = 1; k < n; ++k) {
                    ctx.lineTo(coords[k].x, coords[k].y);
                }
            }
        }

        ctx.beginPath();
        ctx.moveTo(0, h);
        traceCrest(false);
        ctx.lineTo(w, h);
        ctx.closePath();

        if (root.bottomFillOpacity >= 0) {
            var grad = ctx.createLinearGradient(0, 0, 0, h);
            grad.addColorStop(0.0, Qt.rgba(root.color.r, root.color.g, root.color.b, root.fillOpacity));
            grad.addColorStop(1.0, Qt.rgba(root.color.r, root.color.g, root.color.b, root.bottomFillOpacity));
            ctx.fillStyle = grad;
        } else {
            ctx.fillStyle = Qt.rgba(root.color.r, root.color.g, root.color.b, root.fillOpacity);
        }
        ctx.fill();

        if (root.strokeWidth > 0 && root.strokeOpacity > 0) {
            ctx.beginPath();
            traceCrest(true);
            ctx.lineWidth = root.strokeWidth;
            ctx.lineCap = "round";
            ctx.lineJoin = "round";
            ctx.strokeStyle = Qt.rgba(root.color.r, root.color.g, root.color.b, root.strokeOpacity);
            ctx.stroke();
        }
    }

    layer.enabled: true
    layer.effect: MultiEffect { // Blur a bit to obscure away the points
        source: root
        saturation: root.effectSaturation
        blurEnabled: root.effectBlur > 0 && root.effectBlurMax > 0
        blurMax: root.effectBlurMax
        blur: root.effectBlur
    }
}