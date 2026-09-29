# The gallery: the first-party panel that draws every component. Summoned
# over IPC it maps one layer surface, holds every section and component it
# claims, shows a toast through its capability, and takes them all down
# when hidden.
set -euo pipefail
expect "the gallery summons over IPC" ok ipc shell summon panel vgs.gallery '{}'
expect_poll "the gallery maps one panel surface" 1 layer_count vgs:panel
# Every component the module's qmldir lists is drawn, read back by type
# name; the headings have a size, so they show.
expect_poll "the gallery draws every component of the module" '[]' ipc smoke galleryMissing panel vgs.gallery
render expect_poll "the gallery's headings are drawn with a size" 9 ipc smoke galleryHeadings panel vgs.gallery
geometry expect "every example stays inside the gallery" '[]' ipc smoke galleryOverflow panel vgs.gallery
expect "the gallery shows a toast through its capability" ok ipc smoke invokeInstance panel vgs.gallery toast ''
expect_poll "the gallery's toast is in the record under its plugin" '["Saved"]' toast_titles visible
expect "hiding the gallery is allowed" ok ipc shell hide panel vgs.gallery
expect_poll "the gallery's surface is gone" 0 layer_count vgs:panel
expect_poll "hiding the gallery released its toast" '[]' toast_titles visible
