import QtQuick
import qs.modules.common
import qs.modules.common.functions

/**
 * Material color scheme adapted to a given color. It's incomplete but enough for what we need...
 */
QtObject {
    id: root
    required property color color
    readonly property bool _darkMode: Appearance.m3colors.darkmode
    readonly property bool colorIsDark: color.hslLightness < 0.5

    // Clamp album-art chroma into safe surface vs foreground luminance bands so
    // saturated neon or near-white covers never wash out text contrast.
    readonly property color _surfaceTint: ColorUtils.colorWithLightness(
        root.color,
        _darkMode ? Math.min(Math.max(root.color.hslLightness, 0.14), 0.34) : Math.max(root.color.hslLightness, 0.86)
    )
    readonly property color _vibrantAccent: ColorUtils.colorWithLightness(
        ColorUtils.adaptToAccent(Appearance.colors.colPrimary, root.color),
        _darkMode ? 0.76 : 0.42
    )
    readonly property color _softTextTint: ColorUtils.colorWithLightness(
        root.color,
        _darkMode ? 0.90 : 0.20
    )

    property color colLayer0: ColorUtils.mix(Appearance.colors.colLayer0, _surfaceTint, _darkMode ? 0.56 : 0.76)
    property color colLayer1: ColorUtils.mix(Appearance.colors.colLayer1, _surfaceTint, 0.66)
    property color colOnLayer0: ColorUtils.mix(Appearance.colors.colOnLayer0, _softTextTint, 0.90)
    property color colOnLayer1: ColorUtils.mix(colOnLayer0, colLayer0, 0.84)
    property color colSubtext: ColorUtils.mix(colOnLayer0, colLayer0, 0.82)

    property color colPrimary: ColorUtils.mix(_vibrantAccent, Appearance.colors.colPrimary, 0.86)
    property color colPrimaryHover: ColorUtils.mix(colPrimary, colOnLayer0, 0.82)
    property color colPrimaryActive: ColorUtils.mix(colPrimary, colOnLayer0, 0.70)
    property color colSecondary: ColorUtils.mix(
        ColorUtils.colorWithLightness(ColorUtils.adaptToAccent(Appearance.colors.colSecondary, root.color), _darkMode ? 0.74 : 0.44),
        Appearance.colors.colSecondary,
        0.84
    )
    property color colSecondaryContainer: ColorUtils.mix(Appearance.m3colors.m3secondaryContainer, _surfaceTint, 0.72)
    property color colSecondaryContainerHover: ColorUtils.mix(Appearance.colors.colSecondaryContainerHover, _surfaceTint, 0.72)
    property color colSecondaryContainerActive: ColorUtils.mix(Appearance.colors.colSecondaryContainerActive, _surfaceTint, 0.72)
    property color colOnPrimary: ColorUtils.mix(
        ColorUtils.colorWithLightness(ColorUtils.adaptToAccent(Appearance.m3colors.m3onPrimary, root.color), _darkMode ? 0.14 : 0.96),
        Appearance.m3colors.m3onPrimary,
        0.86
    )
    property color colOnSecondaryContainer: ColorUtils.mix(Appearance.m3colors.m3onSecondaryContainer, _softTextTint, 0.86)
}
