import QtQuick
import QtQuick.Effects
import qs.modules.common

MultiEffect {
    property color sourceColor: "black"

    colorization: 1
    brightness: (sourceColor && sourceColor.hslLightness !== undefined) ? (1 - sourceColor.hslLightness) : 0

    Behavior on colorizationColor {
        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
    }
}
