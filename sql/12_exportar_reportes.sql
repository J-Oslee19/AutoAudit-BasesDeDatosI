-- =====================================================================
-- AutoAudit - 12_exportar_reportes.sql
-- Parte 4: Exportación de reportes a formatos estándar (CSV y JSON).
--
-- Script de psql (no se instala; se ejecuta cada vez que se quiere
-- exportar). En Ubuntu, psql crea la carpeta indicada en "dir" con
-- permisos privados. El padre debe existir y estar bajo tu control.
-- Ejecutar con psql -X -f, sin --single-transaction ni BEGIN previo.
--
-- Parámetros (todos opcionales, con -v):
--   dir      carpeta destino            (por defecto: reportes)
--   desde    fecha inicial, inclusiva   (por defecto: sin límite)
--   hasta    fecha final, exclusiva     (por defecto: sin límite)
--   usuario  exporta además el historial de ese usuario
--   tabla + columna  exporta además el historial de esa columna
--
-- Ejemplos:
--   psql -X -d autoaudit -f sql/12_exportar_reportes.sql
--   psql -X -d autoaudit -v dir=reportes-noviembre -v desde=2026-11-01 -v hasta=2026-12-01 \
--        -v usuario=app_ventas -v tabla=empleado -v columna=salario \
--        -f sql/12_exportar_reportes.sql
--
-- Requiere ser miembro de autoaudit_consulta (o autoaudit_admin).
-- Archivos generados:
--   linea_tiempo.csv / linea_tiempo.json   (todos los cambios del período)
--   resumen_usuarios.csv, resumen_columnas.csv, actividad_diaria.csv,
--   estado_auditoria.csv
--   historial_usuario.csv   (solo si se indicó usuario)
--   historial_columna.csv   (solo si se indicaron tabla y columna)
-- =====================================================================
\set ON_ERROR_STOP on
\set QUIET on
\pset footer off
\pset pager off
\encoding UTF8

\if :{?dir}
\else
  \set dir reportes
\endif
-- Fechas vacías = NULL (sin límite)
\if :{?desde}
\else
  \set desde ''
\endif
\if :{?hasta}
\else
  \set hasta ''
\endif

\set por_usuario :{?usuario}
\set por_tabla :{?tabla}
\set por_columna :{?columna}
\if :por_usuario
\else
  \set usuario ''
\endif
\if :por_tabla
\else
  \set tabla ''
\endif
\if :por_columna
\else
  \set columna ''
\endif

BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL search_path = pg_catalog, pg_temp;
SET LOCAL DateStyle = 'ISO, YMD';

-- Validar antes de crear el directorio o abrir salidas locales.
SELECT CASE
  WHEN NOT pg_has_role('autoaudit_consulta', 'USAGE') THEN
    'Se requiere el rol autoaudit_consulta o autoaudit_admin'
  WHEN :'dir' COLLATE "C" !~ '^([.]/|/)?[A-Za-z0-9_][A-Za-z0-9_. -]*(/[A-Za-z0-9_][A-Za-z0-9_. -]*)*$' THEN
    'Ruta inválida: use componentes simples, sin segmentos . o ..'
  WHEN :'por_tabla'::boolean <> :'por_columna'::boolean THEN
    'Indique tabla y columna juntas'
  WHEN (:'por_usuario'::boolean AND btrim(:'usuario') = '')
    OR (:'por_tabla'::boolean AND (btrim(:'tabla') = '' OR btrim(:'columna') = '')) THEN
    'Los filtros indicados no pueden estar vacíos'
  WHEN NOT COALESCE(isfinite(NULLIF(:'desde','')::timestamp), true)
    OR NOT COALESCE(isfinite(NULLIF(:'hasta','')::timestamp), true) THEN
    'Use fechas finitas para desde y hasta'
  ELSE ''
END AS problema
\gset
SELECT :'problema' = '' AS parametros_validos
\gset
\if :parametros_validos
\else
  \warn :problema
  DO $$ BEGIN RAISE EXCEPTION 'Parámetros de exportación inválidos'; END $$;
\endif

SELECT public.fn_validar_rango(NULLIF(:'desde','')::timestamp,
                              NULLIF(:'hasta','')::timestamp) IS NULL AS rango_validado
\gset

-- mkdir sin -p reserva el destino de forma exclusiva. La ruta pasa al
-- shell como un solo argumento y el padre debe existir sin symlinks.
\set destino_creado `destino=:'dir'; padre=$(dirname -- "$destino") && fisico=$(realpath -e -- "$padre") && normal=$(realpath -es -- "$padre") && test "$fisico" = "$normal" && (umask 077; mkdir -- "$destino") && printf true || printf false`
\if :destino_creado
\else
  DO $$ BEGIN RAISE EXCEPTION 'Use un directorio nuevo con un padre existente, escribible y sin enlaces simbólicos'; END $$;
\endif

\echo 'Exportando reportes a la carpeta' :'dir'

\o :dir/linea_tiempo.csv
COPY (SELECT * FROM public.fn_linea_tiempo(NULLIF(:'desde','')::timestamp,
                                           NULLIF(:'hasta','')::timestamp))
  TO STDOUT WITH (FORMAT csv, HEADER true);
\o

\o :dir/linea_tiempo.json
\t on
\pset format unaligned
SELECT COALESCE(json_agg(x ORDER BY x.fecha_hora, x.id_bitacora), '[]'::json)
  FROM public.fn_linea_tiempo(NULLIF(:'desde','')::timestamp,
                              NULLIF(:'hasta','')::timestamp) x;
\t off
\pset format aligned
\o

\o :dir/resumen_usuarios.csv
COPY (SELECT * FROM public.fn_reporte_por_usuario(NULLIF(:'desde','')::timestamp,
                                                  NULLIF(:'hasta','')::timestamp))
  TO STDOUT WITH (FORMAT csv, HEADER true);
\o

\o :dir/resumen_columnas.csv
COPY (SELECT * FROM public.fn_reporte_por_columna(NULLIF(:'desde','')::timestamp,
                                                  NULLIF(:'hasta','')::timestamp))
  TO STDOUT WITH (FORMAT csv, HEADER true);
\o

\o :dir/actividad_diaria.csv
COPY (SELECT * FROM public.fn_reporte_actividad_diaria(NULLIF(:'desde','')::timestamp,
                                                       NULLIF(:'hasta','')::timestamp))
  TO STDOUT WITH (FORMAT csv, HEADER true);
\o

\o :dir/estado_auditoria.csv
COPY (SELECT * FROM public.fn_reporte_estado_auditoria())
  TO STDOUT WITH (FORMAT csv, HEADER true);
\o

\if :por_usuario
  \o :dir/historial_usuario.csv
  COPY (SELECT * FROM public.fn_historial_usuario(:'usuario',
                                                  NULLIF(:'desde','')::timestamp,
                                                  NULLIF(:'hasta','')::timestamp))
    TO STDOUT WITH (FORMAT csv, HEADER true);
  \o
  \echo '  historial_usuario.csv generado para' :'usuario'
\endif

\if :por_tabla
  \o :dir/historial_columna.csv
  COPY (SELECT * FROM public.fn_historial_columna(:'tabla', :'columna',
                                                  NULLIF(:'desde','')::timestamp,
                                                  NULLIF(:'hasta','')::timestamp))
    TO STDOUT WITH (FORMAT csv, HEADER true);
  \o
  \echo '  historial_columna.csv generado para' :'tabla' '.' :'columna'
\endif

COMMIT;
\echo 'Exportación terminada.'
