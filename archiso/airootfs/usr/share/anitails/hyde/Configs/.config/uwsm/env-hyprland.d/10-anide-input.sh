#!/usr/bin/env sh
# AniDE IBus defaults; do not override another input method chosen by the user.
# ANIDE_INPUT_METHOD=none (or another value) disables these defaults.
case ${ANIDE_INPUT_METHOD:-auto} in
    auto|ibus)
        if command -v ibus-daemon >/dev/null 2>&1 &&
           { [ -z "${GTK_IM_MODULE:-}" ] || [ "$GTK_IM_MODULE" = ibus ]; } &&
           { [ -z "${QT_IM_MODULE:-}" ] || [ "$QT_IM_MODULE" = ibus ]; } &&
           { [ -z "${XMODIFIERS:-}" ] || [ "$XMODIFIERS" = '@im=ibus' ]; }; then
            export GTK_IM_MODULE=ibus QT_IM_MODULE=ibus XMODIFIERS='@im=ibus'
        fi
        ;;
esac
