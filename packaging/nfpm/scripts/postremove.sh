#!/bin/sh
set -e
update-desktop-database /usr/share/applications &>/dev/null || true
touch --no-create /usr/share/icons/hicolor &>/dev/null || true
gtk-update-icon-cache /usr/share/icons/hicolor &>/dev/null || true
