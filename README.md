# Sistema Automatizado de Respaldo Incremental, Integridad y Recuperación para E-commerce en GNU/Linux

> **Cliente 1 — Empresa de Comercio Electrónico (E-commerce)**  
> **Estado del repositorio:** **100 % Implementado y Verificado** (`20 / 20` criterios funcionales aprobados).

## 1. Estructura del Repositorio

```text
proyecto-ecomerce/
├── README.md                         # Documentación del proyecto y guía de ejecución
├── 01_estructura_entorno.sh          # Módulo 01 (Joseph Gomero): Entorno FHS, permisos 0750 y datos sintéticos
├── 02_respaldo_incremental.sh        # Módulo 02 (Mathias Marcelo): Respaldo incremental rsync --link-dest y flock
├── 03_integridad_restauracion.sh     # Módulo 03 (Franco Gamarra): Auditoría SHA-256 y restauración ante caídas
├── 04_automatizacion_retencion.sh    # Módulo 04 (Carlos Choque): Cron medianoche (0 0 * * *) y purga por retención
└── avance.sh                         # Verificador funcional de progreso (100 % operativo)
```

## 2. Comprobación Rápida en GitHub Codespaces o VMware

```bash
chmod +x *.sh
./avance.sh --verificar
```

## 3. Guion de Demostración Completa en Vivo (Modo Seguro en `/tmp` o en `/srv` con `sudo`)

Para demostrar todo el ciclo en Codespaces sin necesitar `sudo`:

```bash
export BASE_PRODUCCION="/tmp/demo_ecommerce/produccion"
export BASE_RESPALDO="/tmp/demo_ecommerce/respaldo"

# 1. Crear estructura (0750) y datos sintéticos de catálogo y transacciones
./01_estructura_entorno.sh --init
./01_estructura_entorno.sh --crear-datos-prueba

# 2. Respaldo Día 1 + Firma SHA-256
./02_respaldo_incremental.sh --ejecutar --fecha 2026-11-25
./03_integridad_restauracion.sh --firmar 2026-11-25

# 3. Modificar solo ventas y ejecutar Respaldo Día 2 (demuestra ahorro de disco con enlaces duros)
echo "ORD-1004,2026-11-26T18:30:00,CLI-777,890.00,PAGADO" >> "$BASE_PRODUCCION/transacciones/ventas_2026_11.csv"
./02_respaldo_incremental.sh --ejecutar --fecha 2026-11-26
./03_integridad_restauracion.sh --firmar 2026-11-26

# Comprobar que productos.csv comparte el MISMO INODO en ambas fechas (0 bytes duplicados)
stat -c "Inodo %i -> %n" "$BASE_RESPALDO"/2026-11-25/catalogo/productos.csv "$BASE_RESPALDO"/2026-11-26/catalogo/productos.csv

# 4. Listar puntos de recuperación, simular caída del catálogo y restaurar con validación SHA-256
./03_integridad_restauracion.sh --listar
rm -rf "$BASE_PRODUCCION/catalogo"
./03_integridad_restauracion.sh --restaurar ultimo --componente todo

# 5. Verificar espacio en disco y programar cron a medianoche (00:00)
./04_automatizacion_retencion.sh --check-espacio
./04_automatizacion_retencion.sh --dry-run-purga
```

En tu máquina virtual **Ubuntu Server (VMware Workstation)**, instala las herramientas opcionales recomendadas y ejecuta con `sudo` sobre las rutas reales `/srv/ecommerce` y `/mnt/respaldo_ecommerce`:

```bash
sudo apt update && sudo apt install -y rsync cron
sudo ./01_estructura_entorno.sh --init
sudo ./01_estructura_entorno.sh --crear-datos-prueba
sudo ./04_automatizacion_retencion.sh --ciclo-nocturno
sudo ./04_automatizacion_retencion.sh --instalar-cron
sudo ./04_automatizacion_retencion.sh --estado-cron
```
