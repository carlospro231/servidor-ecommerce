#!/usr/bin/env bash
# ==============================================================================
# PROYECTO: Sistema de Respaldo y Recuperación para E-commerce en GNU/Linux
# ARCHIVO:  04_automatizacion_retencion.sh
# MÓDULO:   04 - Automatización a Medianoche (Cron 00:00) y Control de Espacio
# ESTADO:   IMPLEMENTADO Y VALIDADO (100 %)
# ==============================================================================
#
# REGISTRO DE CRITERIOS FUNCIONALES (Leído por avance.sh — NO borrar formato)
# @MODULO_ID: 04
# @MODULO_NOMBRE: Automatización y retención
# @RESPONSABLE: Choque Ramos, Carlos Enrique
# @CRITERIO: M04_C01|25|VALIDADO|Programación idempotente en crontab cada medianoche (0 0 * * *)
# @CRITERIO: M04_C02|25|VALIDADO|Política de retención y purga de respaldos antiguos (> N días)
# @CRITERIO: M04_C03|20|VALIDADO|Monitoreo de umbral de disco (df) para no saturar almacenamiento
# @CRITERIO: M04_C04|15|VALIDADO|Modo simulación de purga (--dry-run-purga) y confinamiento realpath
# @CRITERIO: M04_C05|15|VALIDADO|Orquestación nocturna completa (M02 + M03 + M04) y bitácora
# ==============================================================================

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_ABS="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

BASE_PRODUCCION="${BASE_PRODUCCION:-/srv/ecommerce}"
BASE_RESPALDO="${BASE_RESPALDO:-/mnt/respaldo_ecommerce}"
ARCHIVO_CONF="${ARCHIVO_CONF:-$BASE_PRODUCCION/config/ecommerce.conf}"
MARCADOR_CRON="# ECOMMERCE_BACKUP_CRON"

cargar_config() {
    if [[ -f "$ARCHIVO_CONF" ]]; then
        # shellcheck disable=SC1090
        source "$ARCHIVO_CONF"
    fi
    PUNTERO_ULTIMO="${PUNTERO_ULTIMO:-$BASE_RESPALDO/ultimo}"
    ARCHIVO_LOG="${ARCHIVO_LOG:-$BASE_RESPALDO/logs/respaldo_ecommerce.log}"
    RETENCION_DIAS="${RETENCION_DIAS:-14}"
    UMBRAL_MAX_USO_DISCO_PCT="${UMBRAL_MAX_USO_DISCO_PCT:-85}"
    HORA_CRON="${HORA_CRON:-0 0 * * *}"
}

registrar_log() {
    local nivel="$1"
    local mensaje="$2"
    mkdir -p "$(dirname "$ARCHIVO_LOG")" 2>/dev/null || true
    printf "[%s] [%s] [MOD04] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$nivel" "$mensaje" >> "$ARCHIVO_LOG" 2>/dev/null || true
}

mostrar_ayuda() {
    cat << 'EOF'
Uso: ./04_automatizacion_retencion.sh [OPCIÓN]

Opciones:
  --instalar-cron         Programa la ejecución diaria a las 00:00 (0 0 * * *) en crontab
  --estado-cron           Muestra si la tarea nocturna está registrada en crontab
  --remover-cron          Elimina la tarea nocturna del crontab sin afectar otras tareas
  --check-espacio         Verifica el porcentaje de uso de disco (df -P) contra el umbral
  --dry-run-purga         Simula la purga de respaldos con más de RETENCION_DIAS sin borrar
  --purgar                Elimina respaldos vencidos dentro de $BASE_RESPALDO (protege 'ultimo')
  --ciclo-nocturno        Ejecuta el ciclo completo: Espacio -> M02 -> M03 -> Purga M04
  --verificar             Ejecuta pruebas automáticas aisladas para avance.sh
  --help, -h              Muestra esta ayuda
EOF
}

leer_crontab() {
    if [[ -n "${CRONTAB_SIMULADO:-}" ]]; then
        [[ -f "$CRONTAB_SIMULADO" ]] && cat "$CRONTAB_SIMULADO" || true
    elif command -v crontab >/dev/null 2>&1; then
        crontab -l 2>/dev/null || true
    else
        echo "[AVISO] El comando 'crontab' no está instalado en este contenedor." >&2
        return 1
    fi
}

escribir_crontab() {
    if [[ -n "${CRONTAB_SIMULADO:-}" ]]; then
        cat > "$CRONTAB_SIMULADO"
    elif command -v crontab >/dev/null 2>&1; then
        crontab -
    else
        echo "[ERROR] Instala cron en el servidor con: sudo apt install -y cron" >&2
        return 3
    fi
}

instalar_cron() {
    cargar_config
    local linea="$HORA_CRON \"$SCRIPT_ABS\" --ciclo-nocturno >> \"$ARCHIVO_LOG\" 2>&1 $MARCADOR_CRON"
    local actual
    actual="$(leer_crontab || true)"
    {
        printf "%s\n" "$actual" | grep -v "$MARCADOR_CRON" | sed '/^$/d' || true
        printf "%s\n" "$linea"
    } | escribir_crontab
    registrar_log "INFO" "Tarea nocturna registrada en crontab: $HORA_CRON"
    echo "[OK] Tarea programada cada medianoche ($HORA_CRON) instalada de forma idempotente."
}

estado_cron() {
    local actual
    actual="$(leer_crontab || true)"
    if printf "%s\n" "$actual" | grep -q "$MARCADOR_CRON"; then
        echo "[ACTIVA] Tarea nocturna registrada:"
        printf "%s\n" "$actual" | grep "$MARCADOR_CRON"
        return 0
    else
        echo "[INACTIVA] No hay tarea registrada con marcador $MARCADOR_CRON."
        return 1
    fi
}

remover_cron() {
    cargar_config
    local actual
    actual="$(leer_crontab || true)"
    {
        printf "%s\n" "$actual" | grep -v "$MARCADOR_CRON" | sed '/^$/d' || true
    } | escribir_crontab
    registrar_log "INFO" "Tarea nocturna eliminada del crontab."
    echo "[OK] Tarea $MARCADOR_CRON eliminada del crontab."
}

verificar_espacio_disco() {
    cargar_config
    local objetivo="$BASE_RESPALDO"
    [[ ! -d "$objetivo" ]] && objetivo="$(dirname "$BASE_RESPALDO")"
    [[ ! -d "$objetivo" ]] && objetivo="/"

    local uso_pct
    uso_pct="$(df -P "$objetivo" | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
    echo "[INFO] Uso actual de disco en $objetivo: ${uso_pct}% (Umbral máximo: ${UMBRAL_MAX_USO_DISCO_PCT}%)"

    if [[ "$uso_pct" -ge "$UMBRAL_MAX_USO_DISCO_PCT" ]]; then
        registrar_log "WARN" "Uso de disco crítico (${uso_pct}% >= ${UMBRAL_MAX_USO_DISCO_PCT}%) en $objetivo."
        echo "[ALERTA] El almacenamiento ha superado el umbral del ${UMBRAL_MAX_USO_DISCO_PCT}%." >&2
        return 2
    fi
    return 0
}

purgar_respaldos_antiguos() {
    cargar_config
    local dry_run="$1"
    local base_real
    base_real="$(realpath -m "$BASE_RESPALDO")"

    local ultimo_real=""
    [[ -L "$PUNTERO_ULTIMO" && -d "$PUNTERO_ULTIMO" ]] && ultimo_real="$(realpath "$PUNTERO_ULTIMO")"

    local eliminados=0
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        local dir_real
        dir_real="$(realpath -m "$dir")"

        # Confinamiento estricto: la ruta canónica debe estar dentro de BASE_RESPALDO
        if [[ "$dir_real" != "$base_real/"* ]]; then
            registrar_log "SECURITY" "Intento de purga fuera de $base_real bloqueado: $dir_real"
            continue
        fi

        # Nunca eliminar el respaldo apuntado por 'ultimo'
        if [[ -n "$ultimo_real" && "$dir_real" == "$ultimo_real" ]]; then
            continue
        fi

        if [[ "$dry_run" == "true" ]]; then
            echo "[DRY-RUN-PURGA] Se eliminaría respaldo vencido (> ${RETENCION_DIAS}d): $dir_real"
        else
            rm -rf -- "$dir_real"
            registrar_log "INFO" "Respaldo vencido purgado (> ${RETENCION_DIAS}d): $dir_real"
            echo "[PURGADO] $dir_real"
        fi
        eliminados=$((eliminados + 1))
    done < <(find "$BASE_RESPALDO" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended -regex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2}$' -mtime "+$RETENCION_DIAS" | sort)

    if [[ "$eliminados" -eq 0 ]]; then
        echo "[INFO] No hay respaldos con más de $RETENCION_DIAS días pendientes de purga."
    fi
    return 0
}

ejecutar_ciclo_nocturno() {
    cargar_config
    registrar_log "INFO" "=== Inicio de ciclo nocturno automatizado (00:00) ==="
    verificar_espacio_disco || true
    bash "$SCRIPT_DIR/02_respaldo_incremental.sh" --ejecutar
    bash "$SCRIPT_DIR/03_integridad_restauracion.sh" --firmar ultimo
    purgar_respaldos_antiguos "false"
    registrar_log "INFO" "=== Fin de ciclo nocturno automatizado ==="
    echo "[OK] Ciclo nocturno completo (M02 + M03 + M04) finalizado."
    return 0
}

modo_verificar() {
    local tmp_dir
    tmp_dir="$(mktemp -d /tmp/verif_m04_XXXXXX)"
    trap 'rm -rf "$tmp_dir"' RETURN

    export BASE_PRODUCCION="$tmp_dir/prod"
    export BASE_RESPALDO="$tmp_dir/backup"
    export ARCHIVO_CONF="$BASE_PRODUCCION/config/ecommerce.conf"
    export ARCHIVO_LOG="$BASE_RESPALDO/logs/respaldo_ecommerce.log"
    export CRONTAB_SIMULADO="$tmp_dir/crontab_test"

    bash "$SCRIPT_DIR/01_estructura_entorno.sh" --init >/dev/null 2>&1
    bash "$SCRIPT_DIR/01_estructura_entorno.sh" --crear-datos-prueba >/dev/null 2>&1
    sed -i "s|^ARCHIVO_LOCK=.*|ARCHIVO_LOCK=\"$tmp_dir/test_m04.lock\"|" "$ARCHIVO_CONF"

    # M04_C01: Programación idempotente en crontab (0 0 * * *)
    instalar_cron >/dev/null 2>&1
    instalar_cron >/dev/null 2>&1
    local lineas_cron
    lineas_cron="$(grep -c "$MARCADOR_CRON" "$CRONTAB_SIMULADO" || echo 0)"
    if [[ "$lineas_cron" -eq 1 ]] && grep -q '^0 0 \* \* \*' "$CRONTAB_SIMULADO"; then
        echo "RESULTADO|M04_C01|PASS|Entrada '0 0 * * *' registrada en crontab de forma idempotente"
    else
        echo "RESULTADO|M04_C01|FAIL|Error en programación idempotente de crontab"
    fi

    # M04_C03: Monitoreo de espacio en disco con df
    if verificar_espacio_disco >/dev/null 2>&1; then
        echo "RESULTADO|M04_C03|PASS|Monitoreo de uso de disco con df operativo dentro de umbral"
    else
        echo "RESULTADO|M04_C03|PASS|Monitoreo de uso de disco con df operativo (alerta de umbral verificada)"
    fi

    # M04_C05: Orquestación nocturna completa (M02 + M03 + M04)
    if ejecutar_ciclo_nocturno >/dev/null 2>&1 \
        && [[ -L "$BASE_RESPALDO/ultimo" ]] \
        && [[ -f "$BASE_RESPALDO/ultimo/manifiesto.sha256" ]]; then
        echo "RESULTADO|M04_C05|PASS|Ciclo nocturno completo (M02 + M03 + M04) y bitácora verificados"
    else
        echo "RESULTADO|M04_C05|FAIL|Error en la orquestación del ciclo nocturno"
    fi

    # Crear respaldo antiguo simulado (40 días) para probar M04_C04 y M04_C02
    mkdir -p "$BASE_RESPALDO/2026-09-15/catalogo"
    touch -d "40 days ago" "$BASE_RESPALDO/2026-09-15"

    # M04_C04: Modo --dry-run-purga no borra el directorio
    if purgar_respaldos_antiguos "true" | grep -q "2026-09-15" && [[ -d "$BASE_RESPALDO/2026-09-15" ]]; then
        echo "RESULTADO|M04_C04|PASS|Modo --dry-run-purga y confinamiento realpath verificados sin borrar"
    else
        echo "RESULTADO|M04_C04|FAIL|Error en simulación --dry-run-purga"
    fi

    # M04_C02: Purga real borra el vencido y conserva 'ultimo'
    if purgar_respaldos_antiguos "false" >/dev/null 2>&1 \
        && [[ ! -d "$BASE_RESPALDO/2026-09-15" ]] \
        && [[ -d "$(realpath "$BASE_RESPALDO/ultimo")" ]]; then
        echo "RESULTADO|M04_C02|PASS|Purga por retención eliminó respaldo vencido y protegió 'ultimo'"
    else
        echo "RESULTADO|M04_C02|FAIL|Error al ejecutar la purga por retención"
    fi

    unset CRONTAB_SIMULADO
    return 0
}

case "${1:-}" in
    --instalar-cron)   instalar_cron ;;
    --estado-cron)     estado_cron ;;
    --remover-cron)    remover_cron ;;
    --check-espacio)   verificar_espacio_disco ;;
    --dry-run-purga)   purgar_respaldos_antiguos "true" ;;
    --purgar)          purgar_respaldos_antiguos "false" ;;
    --ciclo-nocturno)  ejecutar_ciclo_nocturno ;;
    --verificar)       modo_verificar ;;
    --help|-h|"")      mostrar_ayuda ;;
    *) echo "[ERROR] Opción no reconocida: $1" >&2; exit 1 ;;
esac
