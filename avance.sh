#!/usr/bin/env bash
# ==============================================================================
# PROYECTO: Sistema de Respaldo y Recuperación para E-commerce en GNU/Linux
# ARCHIVO:  avance.sh
# FUNCIÓN:  Sistema Funcional de Seguimiento Individual, por Módulo y Global
# ==============================================================================
# Uso:
#   chmod +x avance.sh
#   ./avance.sh                  # Tabla resumen + auditoría Git
#   ./avance.sh --detalle        # Desglose de los 20 criterios funcionales
#   ./avance.sh --verificar      # Ejecuta '--verificar' en los 4 módulos
#   ./avance.sh --git            # Revisa sincronización con GitHub
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MODULOS=(
    "01_estructura_entorno.sh"
    "02_respaldo_incremental.sh"
    "03_integridad_restauracion.sh"
    "04_automatizacion_retencion.sh"
)

if [[ -t 1 ]]; then
    C_RESET="\033[0m"
    C_BOLD="\033[1m"
    C_GREEN="\033[32m"
    C_YELLOW="\033[33m"
    C_CYAN="\033[36m"
    C_RED="\033[31m"
else
    C_RESET=""
    C_BOLD=""
    C_GREEN=""
    C_YELLOW=""
    C_CYAN=""
    C_RED=""
fi

consultar_resultado_verificador() {
    local crit_id="$1"
    local salida="$2"
    local linea
    linea=$(printf "%s\n" "$salida" | grep -E "^RESULTADO\|${crit_id}\|" | head -n 1 || true)
    if [[ -z "$linea" ]]; then
        echo "NO_DISP"
    else
        echo "$linea" | awk -F'|' '{print $3}'
    fi
}

auditar_estado_git() {
    echo -e "${C_BOLD}==============================================================================${C_RESET}"
    echo -e "${C_BOLD} AUDITORÍA DE PERSISTENCIA Y SINCRONIZACIÓN CON GITHUB${C_RESET}"
    echo -e "${C_BOLD}==============================================================================${C_RESET}"

    if ! command -v git >/dev/null 2>&1 || ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo -e " ${C_YELLOW}[AVISO]${C_RESET} Directorio fuera de un repositorio Git o sin inicializar (.git)."
        return 0
    fi

    local rama_actual
    rama_actual=$(git branch --show-current 2>/dev/null || echo "desconocida")
    echo -e " Rama activa actual : ${C_CYAN}${rama_actual:-HEAD}${C_RESET}"

    local cambios_locales
    cambios_locales=$(git status --porcelain 2>/dev/null || true)
    if [[ -n "$cambios_locales" ]]; then
        echo -e " ${C_RED}[ALERTA: CAMBIOS SIN GUARDAR EN GIT]${C_RESET}"
        while IFS= read -r lin; do
            [[ -n "$lin" ]] && echo "   $lin"
        done <<< "$cambios_locales"
    else
        echo -e " ${C_GREEN}[OK]${C_RESET} Árbol de trabajo limpio (sin modificaciones pendientes de commit)."
    fi
}

MODO="${1:-resumen}"
[[ "$MODO" == "--git" ]] && { auditar_estado_git; exit 0; }

SUMA_PUNTOS_GLOBAL=0
TOTAL_CRITERIOS=0
CRIT_PENDIENTES=0
CRIT_IMPLEMENTADOS=0
CRIT_VALIDADOS=0

declare -a FILAS_TABLA=()
declare -a DETALLES_CRITERIOS=()

for archivo in "${MODULOS[@]}"; do
    [[ ! -f "$archivo" ]] && continue
    mod_id=$(grep -E '^# @MODULO_ID:' "$archivo" | head -n 1 | sed 's/^# @MODULO_ID:[[:space:]]*//')
    mod_nombre=$(grep -E '^# @MODULO_NOMBRE:' "$archivo" | head -n 1 | sed 's/^# @MODULO_NOMBRE:[[:space:]]*//')
    responsable=$(grep -E '^# @RESPONSABLE:' "$archivo" | head -n 1 | sed 's/^# @RESPONSABLE:[[:space:]]*//')

    salida_verif=$(bash "$SCRIPT_DIR/$archivo" --verificar 2>/dev/null || true)

    puntos_modulo=0
    c_val=0
    c_fail=0

    while IFS= read -r linea_crit; do
        [[ -z "$linea_crit" ]] && continue
        datos="${linea_crit#*@CRITERIO: }"
        IFS='|' read -r c_id c_peso c_estado c_desc <<< "$datos"
        TOTAL_CRITERIOS=$((TOTAL_CRITERIOS + 1))

        res_verif=$(consultar_resultado_verificador "$c_id" "$salida_verif")
        estado_efectivo="$c_estado"

        if [[ "$res_verif" == "FAIL" ]]; then
            estado_efectivo="FALLO"
            c_fail=$((c_fail + 1))
        elif [[ "$res_verif" == "SKIP" ]]; then
            estado_efectivo="PENDIENTE"
        elif [[ "$c_estado" == "PENDIENTE" && "$res_verif" == "PASS" ]]; then
            estado_efectivo="IMPLEMENTADO"
        fi

        aporte=0
        case "$estado_efectivo" in
            VALIDADO)
                aporte=$((c_peso))
                c_val=$((c_val + 1))
                CRIT_VALIDADOS=$((CRIT_VALIDADOS + 1))
                ;;
            IMPLEMENTADO)
                aporte=$(( (c_peso + 1) / 2 ))
                CRIT_IMPLEMENTADOS=$((CRIT_IMPLEMENTADOS + 1))
                ;;
            *)
                aporte=0
                CRIT_PENDIENTES=$((CRIT_PENDIENTES + 1))
                ;;
        esac

        puntos_modulo=$((puntos_modulo + aporte))
        DETALLES_CRITERIOS+=("${mod_id}|${c_id}|${c_peso}|${c_estado}|${res_verif}|${aporte}|${c_desc}")
    done < <(grep -E '^# @CRITERIO:' "$archivo")

    estado_modulo="Pendiente"
    if [[ "$c_val" -eq 5 && "$puntos_modulo" -eq 100 && "$c_fail" -eq 0 ]]; then
        estado_modulo="Completado"
    elif [[ "$puntos_modulo" -gt 0 ]]; then
        estado_modulo="En desarrollo"
    fi

    SUMA_PUNTOS_GLOBAL=$((SUMA_PUNTOS_GLOBAL + puntos_modulo))
    FILAS_TABLA+=("${responsable}|${mod_nombre}|${puntos_modulo} %|${estado_modulo}")
done

AVANCE_GLOBAL=$(( SUMA_PUNTOS_GLOBAL / 4 ))
ESTADO_GLOBAL="Pendiente"
[[ "$AVANCE_GLOBAL" -gt 0 ]] && ESTADO_GLOBAL="En desarrollo"
[[ "$AVANCE_GLOBAL" -eq 100 && "$CRIT_VALIDADOS" -eq "$TOTAL_CRITERIOS" ]] && ESTADO_GLOBAL="Completado"

echo -e "${C_BOLD}==============================================================================${C_RESET}"
echo -e "${C_BOLD} SEGUIMIENTO DE AVANCE — CLIENTE 1: RESPALDO E-COMMERCE LINUX${C_RESET}"
echo -e "${C_BOLD}==============================================================================${C_RESET}"
printf "%-30s | %-25s | %-8s | %-14s\n" "Integrante" "Módulo" "Avance" "Estado"
echo "-------------------------------+---------------------------+----------+---------------"
for fila in "${FILAS_TABLA[@]}"; do
    IFS='|' read -r f_resp f_mod f_av f_est <<< "$fila"
    printf "%-30s | %-25s | %8s | %-14s\n" "$f_resp" "$f_mod" "$f_av" "$f_est"
done
echo "-------------------------------+---------------------------+----------+---------------"
printf "%-30s | %-25s | %8s | %-14s\n" "Proyecto global" "Integración (4 módulos)" "${AVANCE_GLOBAL} %" "$ESTADO_GLOBAL"
echo "=============================================================================="

echo ""
echo -e "${C_BOLD}RESUMEN DE CRITERIOS FUNCIONALES (${TOTAL_CRITERIOS} criterios):${C_RESET}"
echo " - Criterios validados (100 %): ${CRIT_VALIDADOS} / ${TOTAL_CRITERIOS}"
echo " - Implementados sin validar  : ${CRIT_IMPLEMENTADOS} / ${TOTAL_CRITERIOS}"
echo " - Pendientes / con fallo     : ${CRIT_PENDIENTES} / ${TOTAL_CRITERIOS}"

if [[ "$MODO" == "--detalle" || "$MODO" == "--verificar" ]]; then
    echo ""
    printf "%-8s | %-4s | %-10s | %-6s | %-7s | %s\n" "Criterio" "Peso" "Declarado" "Prueba" "Puntos" "Descripción funcional"
    echo "---------+------+------------+--------+---------+-----------------------------------"
    for item in "${DETALLES_CRITERIOS[@]}"; do
        IFS='|' read -r d_mod d_id d_peso d_est d_verif d_pts d_desc <<< "$item"
        printf "%-8s | %4s | %-10s | %-6s | %7s | %s\n" "$d_id" "$d_peso" "$d_est" "$d_verif" "${d_pts}/${d_peso}" "$d_desc"
    done
fi

echo ""
auditar_estado_git
exit 0
