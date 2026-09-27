# The gallery: the first-party panel that draws every component. Summoned
# over IPC it maps one layer surface, holds every section and component it
# claims, shows a toast through its capability, and takes them all down
# when hidden.
set -euo pipefail
expect "the gallery summons over IPC" ok ipc shell summon panel vgs.gallery '{}'
expect_poll "the gallery maps one panel surface" 1 layer_count vgs:panel
gallery_sections() { ipc smoke readInstance panel vgs.gallery sectionCount; }
gallery_components() { ipc smoke readInstance panel vgs.gallery componentCount; }
expect_poll "the gallery draws its sections" 6 gallery_sections
at_least() { python3 -c 'import sys; print(int(sys.argv[1]) >= int(sys.argv[2]))' "$($1)" "$2"; }
expect "the gallery draws every component it lists" True at_least gallery_components 60
expect "the gallery shows a toast through its capability" ok ipc smoke invokeInstance panel vgs.gallery toast ''
expect_poll "the gallery's toast is in the record under its plugin" '["Saved"]' toast_titles visible
expect "hiding the gallery is allowed" ok ipc shell hide panel vgs.gallery
expect_poll "the gallery's surface is gone" 0 layer_count vgs:panel
expect_poll "hiding the gallery released its toast" '[]' toast_titles visible
