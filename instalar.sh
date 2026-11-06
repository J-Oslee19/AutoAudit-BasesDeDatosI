#!/usr/bin/env bash
# AutoAudit - Ubuntu 26.04 LTS / PostgreSQL 18
set +x
set -euo pipefail
export LC_ALL=C

error() {
  printf 'AutoAudit: %s\n' "$*" >&2
  exit 1
}

case "${1:-}" in
  -h|--help)
    printf '%s\n' 'Uso: bash instalar.sh [base]' \
      '     bash instalar.sh --password HOST [base]' \
      'Base por defecto: autoaudit. Puerto: PGPORT o 5432.'
    exit 0 ;;
  --password)
    [[ $# -ge 2 && $2 =~ ^[a-zA-Z0-9.:_-]+$ && $2 != -* ]] ||
      error 'Indique un solo host TCP válido.'
    host=$2
    shift 2 ;;
esac

base=${1-autoaudit}
puerto=${PGPORT:-5432}
[[ $# -le 1 && $base =~ ^[a-z_][a-z0-9_]{0,62}$ ]] ||
  error 'Use un nombre de base en minúsculas (máximo 63 caracteres). Consulte --help.'
case "$base" in
  postgres|template0|template1) error 'Seleccione una base distinta de las bases del sistema.' ;;
esac
[[ $puerto =~ ^[1-9][0-9]{0,4}$ ]] && (( puerto <= 65535 )) ||
  error 'PGPORT debe estar entre 1 y 65535.'

cd -- "$(dirname -- "$0")"
modulos=(03_ajustes_configuracion 04_consultas_diccionario 05_modulo_configuracion
         07_funciones_bitacora 08_generador_triggers 10_consultas_historicas 11_reportes)
for modulo in 01_tablas "${modulos[@]}"; do
  [[ -f sql/$modulo.sql && -r sql/$modulo.sql ]] ||
    error "No se puede leer sql/$modulo.sql."
done

command -v psql >/dev/null || error 'Instale postgresql-client-18.'
[[ $(psql --version) =~ ^psql[[:space:]]\(PostgreSQL\)[[:space:]]18([.]|[[:space:]]|$) ]] ||
  error 'Se requiere el cliente psql 18.'

# Evitar credenciales heredadas y parámetros que redirijan la conexión.
limpiar=(env -u PGPASSWORD -u PGSERVICE -u PGSERVICEFILE -u PGHOSTADDR
         -u PGOPTIONS -u PGREQUIREAUTH PGPASSFILE=/dev/null PGCLIENTENCODING=UTF8)
if [[ -v host ]]; then
  [[ -t 0 ]] || error 'El modo con contraseña requiere una terminal interactiva.'
  sslmode=verify-full
  case "$host" in
    localhost|127.0.0.1|::1) sslmode=prefer ;;
  esac
  conexion=("${limpiar[@]}" PGREQUIREAUTH=scram-sha-256 "PGSSLMODE=$sslmode"
            PGGSSENCMODE=disable psql -W -h "$host")
else
  conexion=(sudo -u postgres "${limpiar[@]}" psql -w -h /var/run/postgresql)
fi

emitir_instalacion() {
  cat <<'PSQL' || return
SET search_path = pg_catalog, pg_temp;
DO $$
BEGIN
  IF current_setting('server_version_num')::integer / 10000 <> 18 THEN
    RAISE EXCEPTION 'Se requiere PostgreSQL 18 en el servidor';
  END IF;
  IF current_user <> 'postgres' OR NOT current_setting('is_superuser')::boolean THEN
    RAISE EXCEPTION 'El esquema base requiere el superusuario postgres';
  END IF;
END $$;

SELECT format('CREATE DATABASE %I TEMPLATE template0', :'base')
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'base')
\gexec
\connect :base

BEGIN;
SET LOCAL search_path = pg_catalog, pg_temp;
SET LOCAL lock_timeout = '15s';
DO $$
BEGIN
  IF current_setting('server_version_num')::integer / 10000 <> 18
     OR current_user <> 'postgres' OR NOT current_setting('is_superuser')::boolean THEN
    RAISE EXCEPTION 'Verifique el servidor y el rol de la conexión a la base de destino';
  END IF;
  IF NOT pg_try_advisory_xact_lock(18401, 8) THEN
    RAISE EXCEPTION 'Otra sesión está instalando AutoAudit o gestionando sus triggers';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_database WHERE datname = current_database()
                  AND datdba = 'postgres'::regrole)
     OR NOT EXISTS (SELECT FROM pg_namespace WHERE nspname = 'public'
                     AND nspowner IN ('postgres'::regrole, 'pg_database_owner'::regrole))
     OR EXISTS (
          SELECT FROM pg_namespace n
          CROSS JOIN LATERAL aclexplode(COALESCE(n.nspacl, acldefault('n', n.nspowner))) a
          WHERE n.nspname IN ('public', 'autoaudit_interno')
            AND a.privilege_type = 'CREATE'
            AND a.grantee NOT IN ('postgres'::regrole, 'pg_database_owner'::regrole)
        )
     OR EXISTS (SELECT FROM pg_namespace WHERE nspname = 'autoaudit_interno'
                 AND nspowner <> 'postgres'::regrole) THEN
    RAISE EXCEPTION 'Verifique los propietarios y permisos CREATE de la base y sus esquemas';
  END IF;
  IF EXISTS (SELECT FROM pg_roles WHERE rolname IN ('autoaudit_admin', 'autoaudit_consulta')
              AND (rolcanlogin OR rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)) THEN
    RAISE EXCEPTION 'Hay un rol AutoAudit con atributos incompatibles';
  END IF;
END $$;

SELECT NOT EXISTS (
  SELECT FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relname IN
     ('bitacora', 'columna_auditada', 'configuracion_auditoria', 'estacion_trabajo',
      'evento_auditoria', 'tabla_auditada', 'usuario_auditado')
) AS base_nueva
\gset
\if :base_nueva
\echo 'Instalando sql/01_tablas.sql'
PSQL
  sed 's/\r$//' sql/01_tablas.sql || return
  cat <<'PSQL' || return

\endif

-- El dump 01 cambia parámetros de sesión. Restablecer el entorno de los módulos.
RESET ALL;
SET LOCAL search_path = pg_catalog, pg_temp;
SET LOCAL lock_timeout = '15s';
SET LOCAL check_function_bodies = on;

DO $$
DECLARE
  modelo record;
  relacion oid;
  columnas text[];
BEGIN
  FOR modelo IN SELECT * FROM (VALUES
    ('bitacora', 'id_bitacora',
     'id_bitacora:integer!,id_configuracion:integer!,id_usuario:integer!,id_estacion:integer!,valor_anterior:text,valor_nuevo:text,fecha_hora:timestamp without time zone!,id_registro:text'),
    ('columna_auditada', 'id_columna', 'id_columna:integer!,nombre_columna:character varying(100)!,id_tabla:integer!'),
    ('configuracion_auditoria', 'id_configuracion', 'id_configuracion:integer!,id_columna:integer!,id_evento:integer!,activo:boolean!'),
    ('estacion_trabajo', 'id_estacion', 'id_estacion:integer!,nombre_estacion:character varying(100)!,direccion_ip:character varying(45)'),
    ('evento_auditoria', 'id_evento', 'id_evento:integer!,tipo_evento:character varying(20)!'),
    ('tabla_auditada', 'id_tabla', 'id_tabla:integer!,nombre_tabla:character varying(100)!,estado:boolean!'),
    ('usuario_auditado', 'id_usuario', 'id_usuario:integer!,nombre_usuario:character varying(100)!')
  ) AS m(tabla, id, columnas) LOOP
    SELECT c.oid INTO relacion FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = modelo.tabla
       AND c.relkind = 'r' AND c.relowner = 'postgres'::regrole;
    IF relacion IS NULL THEN
      RAISE EXCEPTION 'Estructura base incompleta o incompatible: public.%', modelo.tabla;
    END IF;

    SELECT array_agg(attname || ':' || format_type(atttypid, atttypmod) ||
                     CASE WHEN attnotnull THEN '!' ELSE '' END ORDER BY attnum)
      INTO columnas FROM pg_attribute
     WHERE attrelid = relacion AND attnum > 0 AND NOT attisdropped;
    IF columnas IS DISTINCT FROM string_to_array(modelo.columnas, ',')
       OR EXISTS (SELECT FROM pg_attribute WHERE attrelid = relacion AND NOT attisdropped
                   AND attname IN ('fecha_hora', 'activo', 'estado') AND NOT atthasdef)
       OR NOT EXISTS (SELECT FROM pg_attribute WHERE attrelid = relacion
                       AND attname = modelo.id AND attidentity = 'a')
       OR to_regclass(format('public.%I', modelo.tabla || '_' || modelo.id || '_seq')) IS NULL
       OR pg_get_serial_sequence(format('public.%I', modelo.tabla), modelo.id)::regclass
          IS DISTINCT FROM to_regclass(format('public.%I', modelo.tabla || '_' || modelo.id || '_seq'))
       OR NOT EXISTS (SELECT FROM pg_constraint WHERE conrelid = relacion AND contype = 'p'
                       AND convalidated AND conenforced
                       AND pg_get_constraintdef(oid) = format('PRIMARY KEY (%I)', modelo.id))
    THEN
      RAISE EXCEPTION 'Columnas, identidad o clave primaria incompatibles en public.%', modelo.tabla;
    END IF;
  END LOOP;

  FOR modelo IN SELECT * FROM (VALUES
    ('bitacora','id_configuracion','configuracion_auditoria'),
    ('bitacora','id_estacion','estacion_trabajo'),
    ('bitacora','id_usuario','usuario_auditado'),
    ('columna_auditada','id_tabla','tabla_auditada'),
    ('configuracion_auditoria','id_columna','columna_auditada'),
    ('configuracion_auditoria','id_evento','evento_auditoria')
  ) AS m(tabla, columna, destino) LOOP
    IF NOT EXISTS (
      SELECT FROM pg_constraint
       WHERE conrelid = to_regclass(format('public.%I', modelo.tabla))
         AND contype = 'f' AND convalidated AND conenforced
         AND pg_get_constraintdef(oid) =
             format('FOREIGN KEY (%I) REFERENCES public.%I(%I)', modelo.columna, modelo.destino, modelo.columna)
    ) THEN
      RAISE EXCEPTION 'Falta la clave foránea esperada en public.%.%', modelo.tabla, modelo.columna;
    END IF;
  END LOOP;
END $$;
PSQL

  for modulo in "${modulos[@]}"; do
    printf '\\echo Instalando sql/%s.sql\n' "$modulo" || return
    case "$modulo" in
      07_*|08_*|10_*|11_*)
        # Los límites de estos cuatro módulos pasan a la transacción del instalador.
        sed -e 's/\r$//' -e '/^BEGIN;$/d' -e '/^COMMIT;$/d' "sql/$modulo.sql" || return
        ;;
      *) sed 's/\r$//' "sql/$modulo.sql" || return ;;
    esac
    printf '\n' || return
  done

  cat <<'PSQL'
DO $$
BEGIN
  IF (SELECT count(*) FROM public.evento_auditoria
       WHERE tipo_evento IN ('INSERT', 'UPDATE', 'DELETE')) <> 3 THEN
    RAISE EXCEPTION 'El catálogo de operaciones está incompleto';
  END IF;
  IF NOT pg_has_role('autoaudit_admin', 'autoaudit_consulta', 'USAGE') THEN
    RAISE EXCEPTION 'autoaudit_admin debe heredar los permisos de autoaudit_consulta';
  END IF;
  IF NOT has_function_privilege('autoaudit_consulta',
       'public.fn_reporte_estado_triggers()', 'EXECUTE') THEN
    RAISE EXCEPTION 'Falta el permiso de consulta para el estado de triggers';
  END IF;
  IF (
    SELECT count(*) FROM pg_trigger
     WHERE tgrelid IN ('public.bitacora'::regclass, 'public.usuario_auditado'::regclass,
                       'public.estacion_trabajo'::regclass)
       AND tgfoid = 'autoaudit_interno.proteger_historial()'::regprocedure
       AND tgname IN ('aa_proteger_filas', 'aa_proteger_truncate') AND tgenabled IN ('O', 'A')
  ) <> 6 THEN
    RAISE EXCEPTION 'Faltan protecciones de escritura directa en el historial';
  END IF;
  IF (
    SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
     WHERE i.indrelid = 'public.bitacora'::regclass AND i.indisvalid
       AND c.relname IN ('ix_bitacora_usuario_fecha', 'ix_bitacora_configuracion_fecha', 'ix_bitacora_fecha')
  ) <> 3 THEN
    RAISE EXCEPTION 'Faltan índices válidos de consulta de bitácora';
  END IF;
END $$;
COMMIT;
PSQL
}

emitir_instalacion | "${conexion[@]}" -X -q -v ON_ERROR_STOP=1 -v "base=$base" \
  -p "$puerto" -U postgres -d postgres -f -
printf 'AutoAudit instalado en %s.\n' "$base"
