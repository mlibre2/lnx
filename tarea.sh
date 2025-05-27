#!/bin/bash

## Configuración de la BD (Modificar estos valores).
DB_NAME="kavac" # Nombre de la BD a respaldar.
DB_OWNER="kavac" # Dueño de la BD.
DB_PASSWORD="tiocpeHaknoyromJocBo" # Contraseña de la BD.

## Directorio donde se guardan archivos encriptados sql.gz.gpg
BACKUP_DIR="bak_postgres"

## Configuración de rotación de backups (días para conservar localmente)
ROTATION_DAYS=30  # Conservar backups por 30 días

## Generar nombre del archivo con fecha y hora actuales
TIMESTAMP=$(date +"%d-%m-%Y_%H%M%S")
BACKUP_FILE="${DB_NAME}_${TIMESTAMP}.sql"

## Realizar el respaldo de la BD.
export PGPASSWORD="$DB_PASSWORD"
echo "Respaldando la base de datos '$DB_NAME'..."
pg_dump -U "$DB_OWNER" -h 127.0.0.1 --no-owner --no-acl "$DB_NAME" > "$BACKUP_FILE"
unset PGPASSWORD

## Simulaciion del respaldo para pruebas....
# echo "prueba ${TIMESTAMP}" > "${BACKUP_FILE}"

ENCRYPTED_FILE="${BACKUP_FILE}.gz.gpg"

## Clave autogenerada con encriptado OpenSSL para abrir archivos GPG
##
## Para desencriptar directamente en Debian usar el sig. comando:
##
# gpg --batch --pinentry-mode loopback --passphrase-fd 3 -d nameFile.sql.gz.gpg 3<pass_gz.txt | gunzip - > nameFile.sql
#
## En caso de abrirlo en windows es requerido el programa "gpg4win"
##
## Nota: el archivo "pass_gz.txt" es donde esta la clave para desencriptar
##
PASS_FILE="pass_gz.txt"

## Variable global para control de ejecución (habilitar envio de archivos "encriptados" a windows)
EXECUTE_TRANSFER=true

## Acceso remoto a Windows (requerido OpenSSH-Win...)
## PC production
REMOTE_HOST="172.168.1.3"
REMOTE_USER="Soporte"

## PC prueba
# REMOTE_HOST="172.168.1.50"
# REMOTE_USER="Inf2"

## PC home
# REMOTE_HOST="192.168.0.198"

REMOTE_DESK="Desktop/$BACKUP_DIR/"

REMOTE_PATH="/C:/Users/$REMOTE_USER/$REMOTE_DESK"
# REMOTE_PATH="/E:/$REMOTE_USER/$REMOTE_DESK"

## Generar manualmente con la clave del usuario windows (se borra una vez encriptada)
WINDOWS_PASS_FILE="pass_win.txt"

## Clave encriptada de windows (se usara cada vez que se envia a la ruta remota de windows)
ENCRYPTED_WINDOWS_PASS="pass_win.enc"

## Todos los procesos se registran aqui
LOG_DIR="registros"
LOG_FILE="$LOG_DIR/$(date +"%d-%m-%Y").log"

## Crear el directorio si no existe
mkdir -p "$LOG_DIR"

## Función para registrar eventos
log() {
    echo "[$(date '+%H:%M:%S')] $1" >> "$LOG_FILE"
}

## Función para rotar backups antiguos
rotate_old_backups() {
    log "Iniciando rotación de backups antiguos (más de $ROTATION_DAYS días)..."
    
    ## Rotación local
    if [ -d "$BACKUP_DIR" ]; then
        find "$BACKUP_DIR" -name "${DB_NAME}_*.sql.gz.gpg" -type f -mtime +$ROTATION_DAYS -exec rm -v {} \; >> "$LOG_FILE" 2>&1
        log "Rotación local completada"
    else
        log "No se encontró directorio local $BACKUP_DIR para rotación"
    fi
}

## Función para manejar la contraseña de Windows
manage_windows_password() {
    ## Si ya existe el archivo encriptado, desencriptamos el contenido
    if [ -f "$ENCRYPTED_WINDOWS_PASS" ] && [ -f "$PASS_FILE" ]; then
        log "Desencriptando contraseña de Windows..."
        if ! windows_password=$(gpg --batch --quiet --yes --pinentry-mode loopback \
                                 --passphrase-file "$PASS_FILE" \
                                 -d "$ENCRYPTED_WINDOWS_PASS" 2>> "$LOG_FILE"); then
            EXECUTE_TRANSFER=false
            log "ERROR: Fallo al desencriptar la contraseña de Windows"
            #exit 1
        fi
        echo "$windows_password"
        return 0
    fi

    ## Si no existe el archivo encriptado pero sí el de texto plano
    if [ -f "$WINDOWS_PASS_FILE" ]; then
        log "Encriptando contenido de $WINDOWS_PASS_FILE..."
        windows_password=$(cat "$WINDOWS_PASS_FILE")
        
        ## Encriptamos el contenido (no el archivo)
        if ! echo "$windows_password" | gpg --batch --quiet --yes --pinentry-mode loopback \
                                         --passphrase-file "$PASS_FILE" \
                                         --symmetric \
                                         --cipher-algo AES256 \
                                         -o "$ENCRYPTED_WINDOWS_PASS" 2>> "$LOG_FILE"; then
            EXECUTE_TRANSFER=false
            log "ERROR: Fallo al encriptar la contraseña de Windows"
            #exit 1
        fi
        
        log "Contraseña encriptada guardada en $ENCRYPTED_WINDOWS_PASS"
        echo "$windows_password"
        return 0
    fi

    EXECUTE_TRANSFER=false
    log "ERROR: No se encontró $WINDOWS_PASS_FILE"
    #exit 1
}

## Verificar dependencias
check_dependencies() {
    local deps=("gpg" "gzip" "openssl" "scp" "ssh" "sshpass")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        log "Instalando dependencias faltantes: ${missing[*]}"
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y gnupg gzip openssl sshpass >> "$LOG_FILE" 2>&1
        elif command -v yum &> /dev/null; then
            yum install -y gnupg gzip openssl sshpass >> "$LOG_FILE" 2>&1
        else
            log "ERROR: No se pudo instalar dependencias. Gestor de paquetes no reconocido"
            exit 1
        fi
    fi
}

## Función para mover backups y limpiar
chk_dir_backups_move() {
    if [ ! -d "$BACKUP_DIR" ]; then
        log "El directorio $BACKUP_DIR no existe. Creándolo..."
        mkdir -p "$BACKUP_DIR"
        if [ $? -eq 0 ]; then
            log "Directorio $BACKUP_DIR creado exitosamente."
        else
            log "Error al crear el directorio $BACKUP_DIR." >&2
            return 1
        fi
    fi
    
    ## Mover el archivo
    mv "$ENCRYPTED_FILE" "$BACKUP_DIR/"
    ## Verificar si el movimiento fue exitoso
    if [ $? -eq 0 ]; then
        log "El archivo $ENCRYPTED_FILE se movió correctamente a $BACKUP_DIR"
    else
        log "Error al mover $ENCRYPTED_FILE." >&2
        return 1
    fi

    ## Eliminar archivos vulnerables solo si existen
    if [ -f "$BACKUP_FILE" ]; then
        rm "$BACKUP_FILE"
        log "Se elimino $BACKUP_FILE"
    fi

    if [ -f "$WINDOWS_PASS_FILE" ]; then
        rm "$WINDOWS_PASS_FILE"
        log "Se elimino $WINDOWS_PASS_FILE"
    fi
    return 0
}

## --- Inicio del proceso ---
log "------------------------------------------------"

log "Iniciando proceso de backup seguro"

## Verificar archivo de origen
if [ ! -f "$BACKUP_FILE" ]; then
    log "ERROR: Archivo a respaldar no encontrado: $BACKUP_FILE"
    exit 1
fi

## Verificar/crear contraseña GPG
if [ ! -f "$PASS_FILE" ]; then
    log "Generando nueva clave de cifrado en $PASS_FILE"
    if ! openssl rand -base64 32 > "$PASS_FILE" 2>> "$LOG_FILE"; then
        log "ERROR: No se pudo generar la clave de cifrado"
        exit 1
    fi
    chmod 600 "$PASS_FILE"
    log "Nueva clave generada. GUARDE ESTE ARCHIVO DE FORMA SEGURA: $PASS_FILE"
fi

## Verificar dependencias
check_dependencies

## Obtener contraseña de Windows
windows_password=$(manage_windows_password)

## Cifrar el archivo de backup
log "Cifrando $BACKUP_FILE..."
if ! gzip -9 -c "$BACKUP_FILE" 2>> "$LOG_FILE" | \
     gpg --batch --quiet --yes --pinentry-mode loopback \
         --passphrase-file "$PASS_FILE" \
         --symmetric \
         --cipher-algo AES256 \
         --s2k-digest-algo SHA512 \
         --s2k-count 65011712 \
         -o "$ENCRYPTED_FILE" 2>> "$LOG_FILE"; then
    log "ERROR: Falló el proceso de cifrado"
    exit 1
fi

## Verificar integridad
log "Verificando integridad del archivo cifrado..."
if ! gpg --batch --quiet --pinentry-mode loopback --passphrase-file "$PASS_FILE" -d "$ENCRYPTED_FILE" 2>> "$LOG_FILE" | gunzip -t 2>> "$LOG_FILE"; then
    log "ERROR: Falló la verificación de integridad"
    exit 1
fi

## Transferir archivo solo si todas las dependencias están OK
if $EXECUTE_TRANSFER; then
    log "Iniciando transferencia a ${REMOTE_USER}@${REMOTE_HOST}..."
    
    ## Primero verificar si el directorio remoto existe, si no existe, crearlo
    if ! sshpass -p "$windows_password" ssh -o StrictHostKeyChecking=no \
                                          -o ConnectTimeout=10 \
                                          "${REMOTE_USER}@${REMOTE_HOST}" \
                                          "if not exist \"${REMOTE_DESK}\" mkdir \"${REMOTE_DESK}\"" >> "$LOG_FILE" 2>&1; then
        EXECUTE_TRANSFER=false
        log "ERROR: No se pudo verificar/crear el directorio remoto ${REMOTE_DESK}"
        #exit 1
    else
        log "Directorio remoto verificado/creado correctamente: ${REMOTE_DESK}"
    fi
    
    ## Luego realizar la transferencia
    if ! sshpass -p "$windows_password" scp -o StrictHostKeyChecking=no \
                                           -o ConnectTimeout=10 \
                                           "$ENCRYPTED_FILE" \
                                           "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}" >> "$LOG_FILE" 2>&1; then
        EXECUTE_TRANSFER=false
        log "ERROR: Falló la transferencia del archivo"
        #exit 1
    else
        log "Transferencia completada exitosamente a ${REMOTE_HOST}:${REMOTE_PATH}"
    fi
else
    EXECUTE_TRANSFER=false
    log "Transferencia cancelada por fallos en dependencias previas"
fi

## Mover backup local y limpiar
chk_dir_backups_move

## Rotar backups antiguos
rotate_old_backups

log "Proceso completado exitosamente"
log "------------------------------------------------"

echo "Ok."
exit 0
