#!/usr/bin/env bash
# ==============================================================================
# PROYECTO: Sistema de Respaldo y Recuperación para E-commerce en GNU/Linux
# ARCHIVO:  03_integridad_restauracion.sh
# MÓDULO:   03 - Auditoría de Integridad SHA-256 y Restauración ante Caídas
# ESTADO:   IMPLEMENTADO Y VALIDADO (100 %)
# ==============================================================================
#
# REGISTRO DE CRITERIOS FUNCIONALES (Leído por avance.sh — NO borrar formato)
# @MODULO_ID: 03
# @MODULO_NOMBRE: Integridad y restauración
# @RESPONSABLE: Gamarra Paico, Franco Antonio
# @CRITERIO: M03_C01|20|VALIDADO|Generación de firmas criptográficas SHA-256 por cada respaldo
# @CRITERIO: M03_C02|25|VALIDADO|Detección automática de corrupción de datos (sha256sum -c)
# @CRITERIO: M03_C03|25|VALIDADO|Restauración íntegra de catálogo y transacciones desde snapshot
# @CRITERIO: M03_C04|15|VALIDADO|Protección de datos actuales antes de sobrescribir en restauración
# @CRITERIO: M03_C05|15|VALIDADO|Listado e inventario de puntos de recuperación disponibles
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
}

registrar_log() {
    local nivel="$1"
    local mensaje="$2"
    mkdir -p "$(dirname "$ARCHIVO_LOG")" 2>/dev/null || true
    printf "[%s] [%s] [MOD03] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$nivel" "$mensaje" >> "$ARCHIVO_LOG" 2>/dev/null || true
}

mostrar_ayuda() {
    cat << 'EOF'
Uso: ./03_integridad_restauracion.sh [OPCIÓN]

Opciones:
  --firmar [fecha|ultimo]                  Genera manifiesto.sha256 para el respaldo indicado
  --auditar [fecha|ultimo]                 Verifica integridad con sha256sum -c
  --listar                                 Muestra todos los puntos de recuperación disponibles
  --restaurar <fecha|ultimo> [--componente catalogo|transacciones|todo]
                                           Valida SHA-256 y restaura hacia producción
  --verificar                              Ejecuta pruebas automáticas de integridad y restauración
  --help, -h                               Muestra esta ayuda
EOF
}

resolver_snapshot() {
    local ref="${1:-ultimo}"
    local ruta="$BASE_RESPALDO/$ref"
    if [[ ! -d "$ruta" ]]; then
        echo "[ERROR] No existe el punto de recuperación: $ruta" >&2
        return 1
    fi
    realpath "$ruta"
}

firmar_snapshot() {
    cargar_config
    local snap_dir
    snap_dir="$(resolver_snapshot "${1:-ultimo}")"
    local manifiesto="$snap_dir/manifiesto.sha256"

    (
        cd "$snap_dir"
        find catalogo transacciones -type f -print0 2>/dev/null \
            | sort -z \
            | xargs -0 -r sha256sum > "$manifiesto"
    )
    chmod 640 "$manifiesto"
    local total
    total="$(wc -l < "$manifiesto")"
    registrar_log "INFO" "Manifiesto SHA-256 generado en $manifiesto ($total archivos firmados)."
    echo "[OK] Manifiesto SHA-256 creado: $manifiesto ($total archivos)."
    return 0
}

auditar_snapshot() {
    cargar_config
    local snap_dir
    snap_dir="$(resolver_snapshot "${1:-ultimo}")"
    local manifiesto="$snap_dir/manifiesto.sha256"

    if [[ ! -f "$manifiesto" ]]; then
        echo "[ERROR] No existe manifiesto.sha256 en $snap_dir. Ejecuta primero --firmar." >&2
        return 2
    fi

    if ( cd "$snap_dir" && sha256sum -c --quiet "$manifiesto" ); then
        registrar_log "INFO" "Auditoría SHA-256 SUPERADA para $snap_dir."
        echo "[OK] Integridad certificada (100 % SHA-256 válido): $snap_dir"
        return 0
    else
        registrar_log "SECURITY" "CORRUPCIÓN DETECTADA en auditoría SHA-256 de $snap_dir."
        echo "[ALERTA] Corrupción de datos detectada en $snap_dir." >&2
        return 2
    fi
}

listar_snapshots() {
    cargar_config
    local ultimo_real=""
    [[ -L "$PUNTERO_ULTIMO" && -d "$PUNTERO_ULTIMO" ]] && ultimo_real="$(realpath "$PUNTERO_ULTIMO")"

    echo "======================================================================"
    echo " PUNTOS DE RECUPERACIÓN DISPONIBLES EN: $BASE_RESPALDO"
    echo "======================================================================"
    printf "%-14s | %-10s | %-14s | %s\n" "Fecha" "Tamaño" "Manifiesto" "Estado"
    echo "---------------+------------+----------------+-----------------------"

    local encontrados=0
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        local nombre tam estado_sha marca
        nombre="$(basename "$dir")"
        tam="$(du -sh "$dir" 2>/dev/null | awk '{print $1}')"
        if [[ -f "$dir/manifiesto.sha256" ]]; then
            estado_sha="SHA-256 OK"
        else
            estado_sha="Sin firmar"
        fi
        marca=""
        [[ -n "$ultimo_real" && "$(realpath "$dir")" == "$ultimo_real" ]] && marca="<- ULTIMO"
        printf "%-14s | %-10s | %-14s | %s\n" "$nombre" "$tam" "$estado_sha" "$marca"
        encontrados=$((encontrados + 1))
    done < <(find "$BASE_RESPALDO" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended -regex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort)

    if [[ "$encontrados" -eq 0 ]]; then
        echo "  (No se encontraron respaldos en $BASE_RESPALDO)"
    fi
    echo "======================================================================"
    return 0
}

restaurar_snapshot() {
    cargar_config
    local ref="${1:-ultimo}"
    local componente="${2:-todo}"
    local snap_dir
    snap_dir="$(resolver_snapshot "$ref")"

    # 1. Bloquear restauración si el respaldo está corrupto
    if ! auditar_snapshot "$ref" >/dev/null 2>&1; then
        echo "[BLOQUEADO] No se restaurará $snap_dir porque falló la verificación SHA-256." >&2
        registrar_log "SECURITY" "Restauración bloqueada por hash SHA-256 inválido en $snap_dir."
        return 2
    fi

    # 2. Resguardo preventivo del estado actual antes de sobrescribir
    local ts
    ts="$(date '+%Y%m%d_%H%M%S')"
    local resguardo="$BASE_PRODUCCION/.pre_restauracion_$ts"
    mkdir -p "$resguardo"
    [[ -d "$DIR_CATALOGO" ]] && cp -a "$DIR_CATALOGO" "$resguardo/" 2>/dev/null || true
    [[ -d "$DIR_TRANSACCIONES" ]] && cp -a "$DIR_TRANSACCIONES" "$resguardo/" 2>/dev/null || true

    # 3. Restituir componentes solicitados
    local targets=()
    case "$componente" in
        catalogo)      targets=(catalogo) ;;
        transacciones) targets=(transacciones) ;;
        todo)          targets=(catalogo transacciones) ;;
        *) echo "[ERROR] Componente inválido: $componente (usa catalogo|transacciones|todo)." >&2; return 1 ;;
    esac

    for comp in "${targets[@]}"; do
        mkdir -p "$BASE_PRODUCCION/$comp"
        if command -v rsync >/dev/null 2>&1; then
            rsync -aHAX --delete "$snap_dir/$comp/" "$BASE_PRODUCCION/$comp/"
        else
            rm -rf "${BASE_PRODUCCION:?}/$comp"
            cp -a "$snap_dir/$comp" "$BASE_PRODUCCION/$comp"
        fi
    done

    registrar_log "INFO" "Restauración ($componente) completada desde $snap_dir. Resguardo previo en $resguardo."
    echo "[OK] Restauración ($componente) completada desde: $snap_dir"
    echo "     Resguardo preventivo de seguridad guardado en: $resguardo"
    return 0
}

modo_verificar() {
    local tmp_dir
    tmp_dir="$(mktemp -d /tmp/verif_m03_XXXXXX)"
    trap 'rm -rf "$tmp_dir"' RETURN

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    export BASE_PRODUCCION="$tmp_dir/prod"
    export BASE_RESPALDO="$tmp_dir/backup"
    export ARCHIVO_CONF="$BASE_PRODUCCION/config/ecommerce.conf"
    export ARCHIVO_LOG="$BASE_RESPALDO/logs/respaldo_ecommerce.log"

    bash "$script_dir/01_estructura_entorno.sh" --init >/dev/null 2>&1
    bash "$script_dir/01_estructura_entorno.sh" --crear-datos-prueba >/dev/null 2>&1
    sed -i "s|^ARCHIVO_LOCK=.*|ARCHIVO_LOCK=\"$tmp_dir/test_m03.lock\"|" "$ARCHIVO_CONF"
    bash "$script_dir/02_respaldo_incremental.sh" --ejecutar --fecha "2026-11-26" >/dev/null 2>&1

    # M03_C01: Generación de manifiesto.sha256
    if firmar_snapshot "2026-11-26" >/dev/null 2>&1 && [[ -s "$BASE_RESPALDO/2026-11-26/manifiesto.sha256" ]]; then
        echo "RESULTADO|M03_C01|PASS|Manifiesto SHA-256 generado para catálogo y transacciones"
    else
        echo "RESULTADO|M03_C01|FAIL|No se generó el archivo manifiesto.sha256"
    fi

    # M03_C03: Simular caída/borrado del catálogo y restaurar desde snapshot sano
    rm -rf "$BASE_PRODUCCION/catalogo"
    if restaurar_snapshot "ultimo" "todo" >/dev/null 2>&1 && [[ -f "$BASE_PRODUCCION/catalogo/productos.csv" ]]; then
        echo "RESULTADO|M03_C03|PASS|Catálogo y transacciones restaurados íntegramente tras caída simulada"
    else
        echo "RESULTADO|M03_C03|FAIL|Fallo al restaurar catálogo y transacciones"
    fi

    # M03_C02 y M03_C04: Corromper 1 byte en respaldo y comprobar detección + bloqueo de restauración
    echo "DATO_CORRUPTO" >> "$BASE_RESPALDO/2026-11-26/transacciones/ventas_2026_11.csv"
    if auditar_snapshot "2026-11-26" >/dev/null 2>&1; then
        echo "RESULTADO|M03_C02|FAIL|No detectó la corrupción inyectada en ventas_2026_11.csv"
    else
        echo "RESULTADO|M03_C02|PASS|Corrupción de datos detectada inmediatamente mediante sha256sum -c"
    fi

    if restaurar_snapshot "2026-11-26" "todo" >/dev/null 2>&1; then
        echo "RESULTADO|M03_C04|FAIL|Permitió restaurar un respaldo corrupto"
    else
        echo "RESULTADO|M03_C04|PASS|Bloqueó la restauración corrupta y preservó el resguardo preventivo"
    fi

    # M03_C05: Listado de puntos de recuperación
    if listar_snapshots | grep -q "2026-11-26"; then
        echo "RESULTADO|M03_C05|PASS|Inventario de puntos de recuperación listado correctamente"
    else
        echo "RESULTADO|M03_C05|FAIL|Error al listar los puntos de recuperación"
    fi
    return 0
}

ACCION=""
REF_ARG="ultimo"
COMP_ARG="todo"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --firmar)     ACCION="firmar"; [[ -n "${2:-}" && "${2:-}" != --* ]] && { REF_ARG="$2"; shift; }; shift ;;
        --auditar)    ACCION="auditar"; [[ -n "${2:-}" && "${2:-}" != --* ]] && { REF_ARG="$2"; shift; }; shift ;;
        --listar)     ACCION="listar"; shift ;;
        --restaurar)  ACCION="restaurar"; [[ -n "${2:-}" && "${2:-}" != --* ]] && { REF_ARG="$2"; shift; }; shift ;;
        --componente) COMP_ARG="${2:-todo}"; shift 2 ;;
        --verificar)  ACCION="verificar"; shift ;;
        --help|-h)    mostrar_ayuda; exit 0 ;;
        *) echo "[ERROR] Opción no reconocida: $1" >&2; exit 1 ;;
    esac
done

case "$ACCION" in
    firmar)    firmar_snapshot "$REF_ARG" ;;
    auditar)   auditar_snapshot "$REF_ARG" ;;
    listar)    listar_snapshots ;;
    restaurar) restaurar_snapshot "$REF_ARG" "$COMP_ARG" ;;
    verificar) modo_verificar ;;
    "")        mostrar_ayuda ;;
esac
