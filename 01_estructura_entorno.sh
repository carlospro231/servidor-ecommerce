#!/usr/bin/env bash
# ==============================================================================
# PROYECTO: Sistema de Respaldo y Recuperación para E-commerce en GNU/Linux
# ARCHIVO:  01_estructura_entorno.sh
# MÓDULO:   01 - Preparación de Directorios FHS, Permisos y Datos Sintéticos
# ESTADO:   IMPLEMENTADO Y VALIDADO (100 %)
# ==============================================================================
#
# REGISTRO DE CRITERIOS FUNCIONALES (Leído por avance.sh — NO borrar formato)
# @MODULO_ID: 01
# @MODULO_NOMBRE: Estructura y entorno FHS
# @RESPONSABLE: Gomero Mendoza, Joseph Patrick
# @CRITERIO: M01_C01|20|VALIDADO|Verificación de dependencias (rsync, sha256sum, flock, cron)
# @CRITERIO: M01_C02|25|VALIDADO|Creación de /srv/ecommerce (catalogo, transacciones) y permisos 0750
# @CRITERIO: M01_C03|20|VALIDADO|Preparación del destino /mnt/respaldo_ecommerce y bitácora
# @CRITERIO: M01_C04|20|VALIDADO|Generación del archivo central de configuración ecommerce.conf
# @CRITERIO: M01_C05|15|VALIDADO|Generación de catálogo y transacciones sintéticas de prueba
# ==============================================================================

set -euo pipefail

# Rutas por defecto (se pueden sobrescribir con variables de entorno para pruebas)
BASE_PRODUCCION="${BASE_PRODUCCION:-/srv/ecommerce}"
BASE_RESPALDO="${BASE_RESPALDO:-/mnt/respaldo_ecommerce}"
ARCHIVO_CONF="${ARCHIVO_CONF:-$BASE_PRODUCCION/config/ecommerce.conf}"
ARCHIVO_LOG="${ARCHIVO_LOG:-$BASE_RESPALDO/logs/respaldo_ecommerce.log}"

mostrar_ayuda() {
    cat << 'EOF'
Uso: ./01_estructura_entorno.sh [OPCIÓN]

Opciones:
  --init                  Inicializa directorios de producción, respaldo, permisos 0750 y ecommerce.conf
  --check                 Verifica dependencias del sistema y espacio disponible en disco
  --crear-datos-prueba    Genera archivos sintéticos de catálogo y transacciones para pruebas
  --verificar             Ejecuta la batería de autoverificación en un sandbox temporal (/tmp)
  --help, -h              Muestra esta ayuda

Variables opcionales (para pruebas sin root o en Codespaces):
  BASE_PRODUCCION=/tmp/demo/prod BASE_RESPALDO=/tmp/demo/backup ./01_estructura_entorno.sh --init
EOF
}

registrar_log() {
    local nivel="$1"
    local mensaje="$2"
    local fecha
    fecha="$(date '+%Y-%m-%d %H:%M:%S')"
    mkdir -p "$(dirname "$ARCHIVO_LOG")" 2>/dev/null || true
    printf "[%s] [%s] [MOD01] %s\n" "$fecha" "$nivel" "$mensaje" >> "$ARCHIVO_LOG" 2>/dev/null || true
}

verificar_dependencias() {
    local criticas=(bash sha256sum flock find stat df awk sed grep realpath ln touch)
    local opcionales=(rsync crontab)
    local faltantes_criticas=0

    echo "[INFO] Verificando utilidades del sistema GNU/Linux..."
    for cmd in "${criticas[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            printf "  [OK]      %-12s -> %s\n" "$cmd" "$(command -v "$cmd")"
        else
            printf "  [FALTA]   %-12s (Obligatoria)\n" "$cmd"
            faltantes_criticas=$((faltantes_criticas + 1))
        fi
    done

    for cmd in "${opcionales[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            printf "  [OK]      %-12s -> %s\n" "$cmd" "$(command -v "$cmd")"
        else
            printf "  [AVISO]   %-12s (Recomendada en servidor: sudo apt install -y rsync cron)\n" "$cmd"
        fi
    done

    echo "[INFO] Espacio disponible en disco:"
    df -hP "$(dirname "$BASE_RESPALDO" 2>/dev/null || echo /tmp)" 2>/dev/null || df -hP /

    if [[ "$faltantes_criticas" -gt 0 ]]; then
        echo "[ERROR] Faltan $faltantes_criticas herramientas obligatorias." >&2
        return 3
    fi
    return 0
}

inicializar_entorno() {
    # Validar que no sean rutas peligrosas
    if [[ "$BASE_PRODUCCION" == "/" || "$BASE_RESPALDO" == "/" ]]; then
        echo "[ERROR] Ruta base inválida ('/'). Operación bloqueada por seguridad." >&2
        return 2
    fi

    umask 0027
    mkdir -p "$BASE_PRODUCCION/catalogo" "$BASE_PRODUCCION/transacciones" "$BASE_PRODUCCION/config"
    mkdir -p "$BASE_RESPALDO/logs"

    chmod 750 "$BASE_PRODUCCION" "$BASE_PRODUCCION/catalogo" "$BASE_PRODUCCION/transacciones" "$BASE_PRODUCCION/config"
    chmod 750 "$BASE_RESPALDO" "$BASE_RESPALDO/logs"

    if [[ ! -f "$ARCHIVO_CONF" ]]; then
        cat > "$ARCHIVO_CONF" << EOF
# Configuración central del sistema de respaldo E-commerce
BASE_PRODUCCION="$BASE_PRODUCCION"
DIR_CATALOGO="$BASE_PRODUCCION/catalogo"
DIR_TRANSACCIONES="$BASE_PRODUCCION/transacciones"
BASE_RESPALDO="$BASE_RESPALDO"
PUNTERO_ULTIMO="$BASE_RESPALDO/ultimo"
ARCHIVO_LOG="$ARCHIVO_LOG"
ARCHIVO_LOCK="/tmp/ecommerce_backup_\${USER:-root}.lock"
RETENCION_DIAS=14
UMBRAL_MAX_USO_DISCO_PCT=85
HORA_CRON="0 0 * * *"
EOF
        chmod 640 "$ARCHIVO_CONF"
    fi

    touch "$ARCHIVO_LOG"
    chmod 640 "$ARCHIVO_LOG"
    registrar_log "INFO" "Entorno inicializado en produccion=$BASE_PRODUCCION y respaldo=$BASE_RESPALDO (permisos 0750)."

    echo "[OK] Estructura inicializada correctamente:"
    echo "     Producción : $BASE_PRODUCCION (0750)"
    echo "     Respaldos  : $BASE_RESPALDO (0750)"
    echo "     Config     : $ARCHIVO_CONF"
    echo "     Bitácora   : $ARCHIVO_LOG"
    return 0
}

crear_datos_prueba() {
    if [[ ! -d "$BASE_PRODUCCION/catalogo" || ! -d "$BASE_PRODUCCION/transacciones" ]]; then
        inicializar_entorno
    fi

    cat > "$BASE_PRODUCCION/catalogo/productos.csv" << 'EOF'
sku,nombre,categoria,precio_pen,stock
SKU-001,Laptop Gamer 16GB,Computo,4299.00,15
SKU-002,Monitor IPS 27 Pulgadas,Perifericos,980.50,32
SKU-003,Teclado Mecanico RGB,Perifericos,249.90,48
SKU-004,Disco SSD NVMe 1TB,Almacenamiento,320.00,60
EOF

    cat > "$BASE_PRODUCCION/catalogo/ficha_sku001.json" << 'EOF'
{"sku":"SKU-001","nombre":"Laptop Gamer 16GB","activo":true,"actualizado":"2026-11-26"}
EOF

    dd if=/dev/zero of="$BASE_PRODUCCION/catalogo/imagen_catalogo_01.bin" bs=1K count=64 status=none

    cat > "$BASE_PRODUCCION/transacciones/ventas_2026_11.csv" << 'EOF'
id_pedido,fecha_hora,cliente_id,monto_pen,estado
ORD-1001,2026-11-26T10:15:00,CLI-882,4299.00,PAGADO
ORD-1002,2026-11-26T11:42:10,CLI-915,1230.40,PAGADO
ORD-1003,2026-11-26T14:05:33,CLI-304,320.00,PENDIENTE
EOF

    cat > "$BASE_PRODUCCION/transacciones/comprobante venta 1001.txt" << 'EOF'
BOLETA ELECTRONICA B001-0001001 | Total: S/ 4299.00 | Estado: APROBADO
EOF

    chmod 640 "$BASE_PRODUCCION/catalogo/"* "$BASE_PRODUCCION/transacciones/"*
    registrar_log "INFO" "Datos sintéticos de catálogo (3 archivos) y transacciones (2 archivos) generados."
    echo "[OK] Datos sintéticos de E-commerce creados en $BASE_PRODUCCION."
    return 0
}

modo_verificar() {
    local tmp_dir
    tmp_dir="$(mktemp -d /tmp/verif_m01_XXXXXX)"
    trap 'rm -rf "$tmp_dir"' RETURN

    local orig_prod="$BASE_PRODUCCION"
    local orig_resp="$BASE_RESPALDO"
    local orig_conf="$ARCHIVO_CONF"
    local orig_log="$ARCHIVO_LOG"

    BASE_PRODUCCION="$tmp_dir/srv_ecommerce"
    BASE_RESPALDO="$tmp_dir/mnt_respaldo"
    ARCHIVO_CONF="$BASE_PRODUCCION/config/ecommerce.conf"
    ARCHIVO_LOG="$BASE_RESPALDO/logs/respaldo_ecommerce.log"

    # M01_C01: Dependencias
    if verificar_dependencias >/dev/null 2>&1; then
        echo "RESULTADO|M01_C01|PASS|Dependencias del sistema verificadas correctamente"
    else
        echo "RESULTADO|M01_C01|FAIL|Faltan dependencias obligatorias del sistema"
    fi

    # M01_C02: Estructura /srv/ecommerce y permisos 0750
    if inicializar_entorno >/dev/null 2>&1 \
        && [[ -d "$BASE_PRODUCCION/catalogo" && -d "$BASE_PRODUCCION/transacciones" ]] \
        && [[ "$(stat -c '%a' "$BASE_PRODUCCION")" == "750" ]]; then
        echo "RESULTADO|M01_C02|PASS|Directorios catalogo/ y transacciones/ creados con permisos 0750"
    else
        echo "RESULTADO|M01_C02|FAIL|Error en creación o permisos 0750 de producción"
    fi

    # M01_C03: Destino de respaldos y bitácora
    if [[ -d "$BASE_RESPALDO/logs" && -f "$ARCHIVO_LOG" && "$(stat -c '%a' "$BASE_RESPALDO")" == "750" ]]; then
        echo "RESULTADO|M01_C03|PASS|Directorio de respaldos (0750) y bitácora inicializados"
    else
        echo "RESULTADO|M01_C03|FAIL|No se inicializó correctamente el directorio de respaldos o el log"
    fi

    # M01_C04: Archivo de configuración ecommerce.conf
    if [[ -f "$ARCHIVO_CONF" ]] && bash -n "$ARCHIVO_CONF" 2>/dev/null && grep -q 'RETENCION_DIAS=' "$ARCHIVO_CONF"; then
        echo "RESULTADO|M01_C04|PASS|Archivo ecommerce.conf válido en sintaxis Bash y con parámetros estándar"
    else
        echo "RESULTADO|M01_C04|FAIL|Archivo ecommerce.conf ausente o inválido"
    fi

    # M01_C05: Datos sintéticos de catálogo y transacciones
    if crear_datos_prueba >/dev/null 2>&1 \
        && [[ -f "$BASE_PRODUCCION/catalogo/productos.csv" && -f "$BASE_PRODUCCION/transacciones/ventas_2026_11.csv" ]]; then
        echo "RESULTADO|M01_C05|PASS|Catálogo y transacciones sintéticas creados para pruebas seguras"
    else
        echo "RESULTADO|M01_C05|FAIL|Error al generar datos sintéticos de prueba"
    fi

    BASE_PRODUCCION="$orig_prod"
    BASE_RESPALDO="$orig_resp"
    ARCHIVO_CONF="$orig_conf"
    ARCHIVO_LOG="$orig_log"
    return 0
}

case "${1:-}" in
    --init)
        inicializar_entorno
        ;;
    --check)
        verificar_dependencias
        ;;
    --crear-datos-prueba)
        crear_datos_prueba
        ;;
    --verificar)
        modo_verificar
        ;;
    --help|-h|"")
        mostrar_ayuda
        ;;
    *)
        echo "[ERROR] Opción no reconocida: $1. Usa --help para ver las opciones." >&2
        exit 1
        ;;
esac
