#!/bin/bash
#
# Готовит аддон для склада ноды — тем же кодом, которым он ставится на сервер
# (scripts/update.sh), поэтому раскладка файлов на складе и на сервере одна.
# Запускает хост (service/utils/addons-store.sh) одноразовым контейнером из
# этого образа, от nobody, с доступом только к /out:
#
#   addon-store.sh resolve <аддон> <latest|beta>       печатает версию
#   addon-store.sh prepare <аддон> <версия> <каталог>  кладёт дерево файлов в каталог
#
# Аддоны: metamod, css, swiftly, modsharp, dotnet. Лог — в stderr, в stdout
# только результат (его читает хост).
#
set -Eeuo pipefail
source /scripts/update.sh
# Склад самому себе не источник: версия и файлы — только из сети
ADDON_STORE="/nonexistent"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

usage() { echo "Использование: $0 resolve <аддон> <latest|beta> | prepare <аддон> <версия> <каталог>" >&2; exit 2; }

type="${2:-}"
case "$type" in metamod|css|swiftly|modsharp|dotnet) ;; *) usage ;; esac

case "${1:-}" in
    resolve)
        case "${3:-latest}" in
            latest) SWIFTLY_BETA=0 ;;
            beta)   SWIFTLY_BETA=1 ;;
            *)      usage ;;
        esac
        # «последняя» — без закреплений сервера
        unset METAMOD_VERSION CSS_VERSION SWIFTLY_VERSION MODSHARP_VERSION
        v="$(addon_target "$type")"
        [[ "$v" =~ ^[A-Za-z0-9._+-]+$ ]] || exit 1
        printf '%s\n' "$v"
        ;;
    prepare)
        version="${3:-}" dest="${4:-}"
        [[ "$version" =~ ^[A-Za-z0-9._+-]+$ ]] && [ -n "$dest" ] || usage
        prepare_tree "$type" "$version" "$dest"
        ;;
    *) usage ;;
esac
