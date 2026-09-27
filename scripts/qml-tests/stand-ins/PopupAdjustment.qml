import QtQuick

// Stands in for Quickshell's PopupAdjustment flags: the values are its own.
QtObject {
    enum Adjustment { None = 0, SlideX = 1, SlideY = 2, Slide = 3, FlipX = 4, FlipY = 8, Flip = 12, ResizeX = 16, ResizeY = 32, Resize = 48, All = 63 }
}
