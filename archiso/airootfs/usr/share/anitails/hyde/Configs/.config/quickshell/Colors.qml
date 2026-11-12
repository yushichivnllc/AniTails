import QtQuick

QtObject {
    id: colors
    // Default end-4 Illogical Impulse (Material 3 dark) palette, overridden dynamically by Wallbash theme.json
    property color barBg: "#141313"          // colLayer0
    property color mainBg: "#141313"         // m3background
    property color surfaceBg: "#1c1b1c"      // colLayer1 (BarGroup background)
    property color layer2Bg: "#2b2a2a"       // colLayer2 (CircleUtilButton background)
    property color mainFg: "#e6e1e1"         // colOnLayer0 / colOnLayer1
    property color subFg: "#948f94"          // colSubtext / m3outline
    property color actBg: "#cbc4cb"          // colPrimary (active workspace pill)
    property color accentSecondary: "#4d4b4d"// colSecondaryContainer (occupied workspace pill)
    property color onSecondaryContainer: "#ece6e9"
    property color actFg: "#322f34"          // colOnPrimary
    property color hvrBg: "#2b2a2a"          // colLayer1Hover
    property color hvrFg: "#e6e1e1"
    property color borderColor: "#49464a"    // colOutlineVariant
    property color errorColor: "#ffb4ab"     // m3error
    property color onErrorColor: "#690005"   // m3onError
    property int cornerRadius: 23            // Appearance.rounding.screenRounding (23px)
    property int groupRadius: 12             // Appearance.rounding.small (12px)

    function applyJson(raw) {
        if (!raw) return;
        try {
            var data = JSON.parse(raw);
            if (data.barBg) barBg = data.barBg;
            if (data.mainBg) mainBg = data.mainBg;
            if (data.surfaceBg) surfaceBg = data.surfaceBg;
            if (data.layer2Bg) layer2Bg = data.layer2Bg;
            if (data.mainFg) mainFg = data.mainFg;
            if (data.subFg) subFg = data.subFg;
            if (data.actBg) actBg = data.actBg;
            if (data.accentSecondary) accentSecondary = data.accentSecondary;
            if (data.onSecondaryContainer) onSecondaryContainer = data.onSecondaryContainer;
            if (data.actFg) actFg = data.actFg;
            if (data.hvrBg) hvrBg = data.hvrBg;
            if (data.hvrFg) hvrFg = data.hvrFg;
            if (data.borderColor) borderColor = data.borderColor;
            if (data.cornerRadius !== undefined) cornerRadius = Number(data.cornerRadius) || 23;
        } catch (e) {
            // Keep existing theme values if JSON is mid-write
        }
    }
}
