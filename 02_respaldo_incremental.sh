#!/usr/bin/env bash
# ==============================================================================
# PROYECTO: Sistema de Respaldo y Recuperación para E-commerce en GNU/Linux
# ARCHIVO:  02_respaldo_incremental.sh
# MÓDULO:   02 - Motor de Respaldo Incremental con rsync y Enlaces Duros
# ESTADO:   IMPLEMENTADO Y VALIDADO (100 %)
# ==============================================================================
#
# REGISTRO DE CRITERIOS FUNCIONALES (Leído por avance.sh — NO borrar formato)
# @MODULO_ID: 02
# @MODULO_NOMBRE: Respaldo incremental rsync
# @RESPONSABLE: Marcelo Mego, Mathias Fabricio
# @CRITERIO: M02_C01|20|VALIDADO|Control de concurrencia mediante bloqueo exclusivo (flock)
# @CRITERIO: M02_C02|25|VALIDADO|Respaldo incremental con rsync -aHAX y enlaces duros (--link-dest)
# @CRITERIO: M02_C03|20|VALIDADO|Actualización atómica del puntero simbólico 'ultimo' (ln -sfn)
# @CRITERIO: M02_C04|15|VALIDADO|Modo de simulación preventiva (--dry-run) sin escritura en destino
# @CRITERIO: M02_C05|20|VALIDADO|Verificación de ahorro de almacenamiento (mismo inodo en no modificados)
# ==============================================================================

set -euo pipefail

BASE_PRODUCCION="${BASE_PRODUCCION:-/srv/ecommerce}"
BASE_RESPALDO="${BASE_RESPALDO:-/mnt/respaldo_ecommerce}"
ARCHIVO_CONF="${ARCHIVO_CONF:-$BASE_PRODUCCION/config/ecommerce.conf}"

cargar_config() {
    if [[ -f "$ARCHIVO_CONF" ]]; then
        # shellcheck disable=SC1090
        source "$ARCHIVO_CONF"
    fi
    DIR_CATALOGO="${DIR_CATALOGO:-$BASE_PRODUCCION/catalogo}"
    DIR_TRANSACCIONES="${DIR_TRANSACCIONES:-$BASE_PRODUCCION/transacciones}"
    PUNTERO_ULTIMO="${PUNTERO_ULTIMO:-$BASE_RESPALDO/ultimo}"
    ARCHIVO_LOG="${ARCHIVO_LOG:-$BASE_RESPALDO/logs/respaldo_ecommerce.log}"
    ARCHIVO_LOCK="${ARCHIVO_LOCK:-/tmp/ecommerce_backup_${USER:-root}.lock}"
}

registrar_log() {
    local nivel="$1"
    local mensaje="$2"
    mkdir -p "$(dirname "$ARCHIVO_LOG")" 2>/dev/null || true
    printf "[%s] [%s] [MOD02] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$nivel" "$mensaje" >> "$ARCHIVO_LOG" 2>/dev/null || true
}

mostrar_ayuda() {
    cat << 'EOF'
Uso: ./02_respaldo_incremental.sh [--ejecutar | --dry-run | --verificar] [--fecha YYYY-MM-DD]

Opciones:
  --ejecutar              Ejecuta el respaldo incremental de catalogo/ y transacciones/
  --dry-run               Simula el respaldo mostrando los archivos sin escribir en el destino
  --fecha <YYYY-MM-DD>    Define la carpeta de fecha destino (por defecto: fecha de hoy)
  --verificar             Ejecuta pruebas automáticas (flock, rsync/hard links, dry-run, inodos)
  --help, -h              Muestra esta ayuda
EOF
}

# Copia incremental con enlaces duros (usa rsync como motor principal;
# si rsync no está instalado en un contenedor mínimo, emula hard links con ln/cp)
sincronizar_directorio() {
    local origen="$1"
    local destino="$2"
    local ref_previa="$3"
    local dry_run="$4"

    if command -v rsync >/dev/null 2>&1; then
        local opts=(-aHAX --delete)
        [[ "$dry_run" == "true" ]] && opts+=(--dry-run -v)
        if [[ -n "$ref_previa" && -d "$ref_previa" ]]; then
            opts+=(--link-dest="$ref_previa")
        fi
        [[ "$dry_run" == "false" ]] && mkdir -p "$destino"
        rsync "${opts[@]}" "$origen/" "$destino/"
    else
        # Respaldo compatible POSIX usando enlaces físicos duros (hard links) cuando rsync no está presente
        if [[ "$dry_run" == "true" ]]; then
            echo "[DRY-RUN] Se sincronizaría: $origen -> $destino (ref: ${ref_previa:-ninguna})"
            find "$origen" -type f -print
            return 0
        fi
        mkdir -p "$destino"
        while IFS= read -r -d '' archivo; do
            local rel="${archivo#"$origen"/}"
            local dest_file="$destino/$rel"
            mkdir -p "$(dirname "$dest_file")"
            if [[ -n "$ref_previa" && -f "$ref_previa/$rel" ]] && cmp -s "$archivo" "$ref_previa/$rel"; then
                # Mismo contenido: enlaza al mismo inodo (hard link = 0 bytes extra)
                ln -f "$ref_previa/$rel" "$dest_file"
            else
                cp -p "$archivo" "$dest_file"
            fi
        done < <(find "$origen" -type f -print0)
    fi
}

ejecutar_respaldo() {
    local fecha_dest="$1"
    local dry_run="$2"

    cargar_config

    if [[ ! -d "$DIR_CATALOGO" || ! -d "$DIR_TRANSACCIONES" ]]; then
        echo "[ERROR] No existen los directorios de producción ($DIR_CATALOGO / $DIR_TRANSACCIONES). Ejecuta primero el Módulo 01." >&2
        return 3
    fi

    local dir_destino="$BASE_RESPALDO/$fecha_dest"
    local ref_catalogo=""
    local ref_transacciones=""

    if [[ -L "$PUNTERO_ULTIMO" && -d "$PUNTERO_ULTIMO" ]]; then
        local ruta_ultimo
        ruta_ultimo="$(realpath "$PUNTERO_ULTIMO")"
        if [[ "$ruta_ultimo" != "$dir_destino" ]]; then
            [[ -d "$ruta_ultimo/catalogo" ]] && ref_catalogo="$ruta_ultimo/catalogo"
            [[ -d "$ruta_ultimo/transacciones" ]] && ref_transacciones="$ruta_ultimo/transacciones"
        fi
    fi

    # Bloqueo exclusivo contra ejecución concurrente con flock
    exec 9>"$ARCHIVO_LOCK"
    if ! flock -n 9; then
        echo "[ERROR] Ya existe otro proceso de respaldo en ejecución (lock activo: $ARCHIVO_LOCK)." >&2
        registrar_log "WARN" "Respaldo abortado por bloqueo concurrente en $ARCHIVO_LOCK."
        exec 9>&-
        return 2
    fi

    if [[ "$dry_run" == "true" ]]; then
        echo "[DRY-RUN] Simulación de respaldo incremental hacia $dir_destino (CERO modificaciones):"
        sincronizar_directorio "$DIR_CATALOGO" "$dir_destino/catalogo" "$ref_catalogo" "true"
        sincronizar_directorio "$DIR_TRANSACCIONES" "$dir_destino/transacciones" "$ref_transacciones" "true"
        registrar_log "INFO" "Simulación Dry-run ejecutada para fecha $fecha_dest."
        exec 9>&-
        return 0
    fi

    mkdir -p "$dir_destino"
    sincronizar_directorio "$DIR_CATALOGO" "$dir_destino/catalogo" "$ref_catalogo" "false"
    sincronizar_directorio "$DIR_TRANSACCIONES" "$dir_destino/transacciones" "$ref_transacciones" "false"

    # Actualización atómica del puntero simbólico 'ultimo'
    ln -sfn "$dir_destino" "$PUNTERO_ULTIMO"
    registrar_log "INFO" "Respaldo incremental completado en $dir_destino (puntero 'ultimo' actualizado)."
    echo "[OK] Respaldo incremental guardado en: $dir_destino"
    echo "     Puntero simbólico 'ultimo' -> $(readlink "$PUNTERO_ULTIMO")"

    exec 9>&-
    return 0
}

modo_verificar() {
    local tmp_dir
    tmp_dir="$(mktemp -d /tmp/verif_m02_XXXXXX)"
    trap 'rm -rf "$tmp_dir"' RETURN

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    export BASE_PRODUCCION="$tmp_dir/prod"
    export BASE_RESPALDO="$tmp_dir/backup"
    export ARCHIVO_CONF="$BASE_PRODUCCION/config/ecommerce.conf"
    export ARCHIVO_LOG="$BASE_RESPALDO/logs/respaldo_ecommerce.log"
    export ARCHIVO_LOCK="$tmp_dir/test_m02.lock"

    bash "$script_dir/01_estructura_entorno.sh" --init >/dev/null 2>&1
    bash "$script_dir/01_estructura_entorno.sh" --crear-datos-prueba >/dev/null 2>&1
    # Sobrescribir lock en config temporal para aislar prueba
    sed -i "s|^ARCHIVO_LOCK=.*|ARCHIVO_LOCK=\"$tmp_dir/test_m02.lock\"|" "$ARCHIVO_CONF"

    # M02_C01: Prueba de bloqueo exclusivo flock
    (
        exec 8>"$tmp_dir/test_m02.lock"
        flock -n 8
        sleep 1
    ) &
    local bg_pid=$!
    sleep 0.2
    if ejecutar_respaldo "2026-11-24" "false" >/dev/null 2>&1; then
        echo "RESULTADO|M02_C01|FAIL|No bloqueó la ejecución concurrente con flock"
    else
        echo "RESULTADO|M02_C01|PASS|Bloqueo exclusivo con flock impidió ejecuciones simultáneas"
    fi
    wait "$bg_pid" 2>/dev/null || true

    # M02_C02 y M02_C03: Respaldo Día 1 y puntero 'ultimo'
    if ejecutar_respaldo "2026-11-25" "false" >/dev/null 2>&1 \
        && [[ -f "$BASE_RESPALDO/2026-11-25/catalogo/productos.csv" ]] \
        && [[ -f "$BASE_RESPALDO/2026-11-25/transacciones/ventas_2026_11.csv" ]]; then
        echo "RESULTADO|M02_C02|PASS|Respaldo de catalogo/ y transacciones/ completado preservando metadatos"
    else
        echo "RESULTADO|M02_C02|FAIL|Fallo al respaldar catalogo/ o transacciones/"
    fi

    if [[ -L "$BASE_RESPALDO/ultimo" ]] && [[ "$(realpath "$BASE_RESPALDO/ultimo")" == "$(realpath "$BASE_RESPALDO/2026-11-25")" ]]; then
        echo "RESULTADO|M02_C03|PASS|Puntero simbólico 'ultimo' apunta correctamente a 2026-11-25"
    else
        echo "RESULTADO|M02_C03|FAIL|El puntero simbólico 'ultimo' no se actualizó"
    fi

    # M02_C04: Modo --dry-run sin escribir en destino
    if ejecutar_respaldo "2026-11-26" "true" >/dev/null 2>&1 && [[ ! -d "$BASE_RESPALDO/2026-11-26" ]]; then
        echo "RESULTADO|M02_C04|PASS|Modo --dry-run simuló sin crear archivos ni carpetas en destino"
    else
        echo "RESULTADO|M02_C04|FAIL|El modo --dry-run modificó el directorio de destino"
    fi

    # M02_C05: Respaldo Día 2 verificando hard link (mismo inodo en archivo sin cambios)
    echo "ORD-1004,2026-11-26T18:00:00,CLI-999,550.00,PAGADO" >> "$BASE_PRODUCCION/transacciones/ventas_2026_11.csv"
    ejecutar_respaldo "2026-11-26" "false" >/dev/null 2>&1

    local inodo_cat_d1 inodo_cat_d2 inodo_tx_d1 inodo_tx_d2
    inodo_cat_d1="$(stat -c '%i' "$BASE_RESPALDO/2026-11-25/catalogo/productos.csv")"
    inodo_cat_d2="$(stat -c '%i' "$BASE_RESPALDO/2026-11-26/catalogo/productos.csv")"
    inodo_tx_d1="$(stat -c '%i' "$BASE_RESPALDO/2026-11-25/transacciones/ventas_2026_11.csv")"
    inodo_tx_d2="$(stat -c '%i' "$BASE_RESPALDO/2026-11-26/transacciones/ventas_2026_11.csv")"

    if [[ "$inodo_cat_d1" == "$inodo_cat_d2" && "$inodo_tx_d1" != "$inodo_tx_d2" ]]; then
        echo "RESULTADO|M02_C05|PASS|Hard link verificado: mismo inodo ($inodo_cat_d1) en catálogo sin cambios y nuevo inodo en ventas"
    else
        echo "RESULTADO|M02_C05|FAIL|No se verificó el enlace duro por inodo (cat: $inodo_cat_d1 vs $inodo_cat_d2)"
    fi
    return 0
}

ACCION=""
FECHA_ARG="$(date +%F)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ejecutar) ACCION="ejecutar"; shift ;;
        --dry-run)  ACCION="dryrun"; shift ;;
        --verificar) ACCION="verificar"; shift ;;
        --fecha)    FECHA_ARG="${2:-}"; shift 2 ;;
        --help|-h)  mostrar_ayuda; exit 0 ;;
        *) echo "[ERROR] Opción no reconocida: $1" >&2; exit 1 ;;
    esac
done

case "$ACCION" in
    ejecutar)  ejecutar_respaldo "$FECHA_ARG" "false" ;;
    dryrun)    ejecutar_respaldo "$FECHA_ARG" "true" ;;
    verificar) modo_verificar ;;
    "")        mostrar_ayuda ;;
esac
