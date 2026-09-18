xrdb -nocpp ~/.Xresources
setxkbmap -layout us -variant altgr-intl
setxkbmap -option caps:swapescape
xset r rate 200 25
# let the systemd user session and D-Bus activated services (the desktop
# portal, which is what tells GTK4 and Chromium to go dark) see the display
dbus-update-activation-environment --systemd DISPLAY XAUTHORITY

exec bspwm
