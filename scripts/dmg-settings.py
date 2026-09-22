# dmgbuild settings for the brouter DMG. Used by scripts/dmg.sh.
# Pass -D app=<path to brouter.app> -D background=<path to background.tiff>.

app = defines["app"]

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}

background = defines["background"]
window_rect = ((200, 120), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 13
icon_locations = {"brouter.app": (170, 190), "Applications": (470, 190)}
