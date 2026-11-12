import QtQuick

Canvas {
    id: root
    property int cornerSize: 23
    property color fillColor: "#141313"
    // "top-left" | "top-right" | "bottom-left" | "bottom-right"
    property string corner: "top-left"

    width: cornerSize
    height: cornerSize
    antialiasing: true
    smooth: true

    onFillColorChanged: requestPaint()
    onCornerSizeChanged: requestPaint()
    onCornerChanged: requestPaint()

    onPaint: {
        var ctx = getContext("2d");
        ctx.reset();
        ctx.fillStyle = root.fillColor;
        ctx.beginPath();

        if (root.corner === "top-left") {
            ctx.moveTo(0, 0);
            ctx.lineTo(width, 0);
            ctx.arc(width, height, width, -Math.PI / 2, Math.PI, true);
        } else if (root.corner === "top-right") {
            ctx.moveTo(width, 0);
            ctx.lineTo(0, 0);
            ctx.arc(0, height, width, -Math.PI / 2, 0, false);
        } else if (root.corner === "bottom-left") {
            ctx.moveTo(0, height);
            ctx.lineTo(width, height);
            ctx.arc(width, 0, width, Math.PI / 2, Math.PI, false);
        } else if (root.corner === "bottom-right") {
            ctx.moveTo(width, height);
            ctx.lineTo(0, height);
            ctx.arc(0, 0, width, Math.PI / 2, 0, true);
        }

        ctx.closePath();
        ctx.fill();
    }
}
