-- =====================================================================
-- AutoAudit - 11_reportes.sql
-- Parte 4: Reportes de auditoría (resúmenes listos para exportar).
--
--   fn_reporte_por_usuario      -> cuántos cambios hizo cada usuario
--   fn_reporte_por_columna      -> cuántos cambios tuvo cada columna
--   fn_reporte_actividad_diaria -> cambios por día y tipo de evento
--   fn_reporte_estado_auditoria -> qué se audita hoy y si el trigger existe
--
-- Instalar como postgres DESPUÉS de 10_consultas_historicas.sql.
-- Para exportar a CSV/JSON usar 12_exportar_reportes.sql.
-- =====================================================================
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL check_function_bodies = on;
SET LOCAL search_path = pg_catalog, pg_temp;

DO $$
BEGIN
  IF pg_catalog.to_regclass('public.v_bitacora_detalle') IS NULL THEN
    RAISE EXCEPTION 'Instale primero 10_consultas_historicas.sql';
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- 1. Resumen por usuario
--    Ej.: SELECT * FROM fn_reporte_por_usuario();
--         SELECT * FROM fn_reporte_por_usuario('2026-11-01','2026-12-01');
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_reporte_por_usuario(
  p_desde timestamp DEFAULT NULL,
  p_hasta timestamp DEFAULT NULL
)
RETURNS TABLE (
  nombre_usuario    text,
  total_cambios     bigint,
  inserciones       bigint,
  actualizaciones   bigint,
  eliminaciones     bigint,
  tablas_afectadas  bigint,
  primer_cambio     timestamp,
  ultimo_cambio     timestamp
)
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  PERFORM public.fn_validar_rango(p_desde, p_hasta);
  RETURN QUERY
  SELECT d.nombre_usuario,
         count(*),
         count(*) FILTER (WHERE d.tipo_evento = 'INSERT'),
         count(*) FILTER (WHERE d.tipo_evento = 'UPDATE'),
         count(*) FILTER (WHERE d.tipo_evento = 'DELETE'),
         count(DISTINCT d.nombre_tabla),
         min(d.fecha_hora),
         max(d.fecha_hora)
    FROM public.v_bitacora_detalle d
   WHERE (p_desde IS NULL OR d.fecha_hora >= p_desde)
     AND (p_hasta IS NULL OR d.fecha_hora <  p_hasta)
   GROUP BY d.nombre_usuario
   ORDER BY count(*) DESC, d.nombre_usuario;
END $$;

-- ---------------------------------------------------------------------
-- 2. Resumen por tabla y columna
--    Incluye quién hizo el último cambio de cada columna.
--    Ej.: SELECT * FROM fn_reporte_por_columna();
--         SELECT * FROM fn_reporte_por_columna(p_tabla => 'empleado');
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_reporte_por_columna(
  p_desde timestamp DEFAULT NULL,
  p_hasta timestamp DEFAULT NULL,
  p_tabla text      DEFAULT NULL
)
RETURNS TABLE (
  nombre_tabla     text,
  nombre_columna   text,
  total_cambios    bigint,
  inserciones      bigint,
  actualizaciones  bigint,
  eliminaciones    bigint,
  usuarios_distintos bigint,
  ultimo_cambio    timestamp,
  ultimo_usuario   text
)
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  PERFORM public.fn_validar_rango(p_desde, p_hasta);
  RETURN QUERY
  WITH f AS (
    SELECT d.* FROM public.v_bitacora_detalle d
     WHERE (p_desde IS NULL OR d.fecha_hora >= p_desde)
       AND (p_hasta IS NULL OR d.fecha_hora <  p_hasta)
       AND (p_tabla IS NULL OR d.nombre_tabla = p_tabla)
  ), ultimo AS (
    SELECT DISTINCT ON (f.nombre_tabla, f.nombre_columna)
           f.nombre_tabla, f.nombre_columna, f.nombre_usuario
      FROM f
     ORDER BY f.nombre_tabla, f.nombre_columna, f.fecha_hora DESC, f.id_bitacora DESC
  )
  SELECT f.nombre_tabla, f.nombre_columna,
         count(*),
         count(*) FILTER (WHERE f.tipo_evento = 'INSERT'),
         count(*) FILTER (WHERE f.tipo_evento = 'UPDATE'),
         count(*) FILTER (WHERE f.tipo_evento = 'DELETE'),
         count(DISTINCT f.nombre_usuario),
         max(f.fecha_hora),
         min(u.nombre_usuario)
    FROM f
    JOIN ultimo u ON u.nombre_tabla = f.nombre_tabla AND u.nombre_columna = f.nombre_columna
   GROUP BY f.nombre_tabla, f.nombre_columna
   ORDER BY f.nombre_tabla, f.nombre_columna;
END $$;

-- ---------------------------------------------------------------------
-- 3. Actividad diaria (visualización temporal)
--    Ej.: SELECT * FROM fn_reporte_actividad_diaria('2026-11-01','2026-12-01');
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_reporte_actividad_diaria(
  p_desde timestamp DEFAULT NULL,
  p_hasta timestamp DEFAULT NULL,
  p_tabla text      DEFAULT NULL
)
RETURNS TABLE (
  fecha            date,
  inserciones      bigint,
  actualizaciones  bigint,
  eliminaciones    bigint,
  total_cambios    bigint,
  usuarios_distintos bigint,
  tablas_distintas bigint
)
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  PERFORM public.fn_validar_rango(p_desde, p_hasta);
  RETURN QUERY
  SELECT d.fecha_hora::date,
         count(*) FILTER (WHERE d.tipo_evento = 'INSERT'),
         count(*) FILTER (WHERE d.tipo_evento = 'UPDATE'),
         count(*) FILTER (WHERE d.tipo_evento = 'DELETE'),
         count(*),
         count(DISTINCT d.nombre_usuario),
         count(DISTINCT d.nombre_tabla)
    FROM public.v_bitacora_detalle d
   WHERE (p_desde IS NULL OR d.fecha_hora >= p_desde)
     AND (p_hasta IS NULL OR d.fecha_hora <  p_hasta)
     AND (p_tabla IS NULL OR d.nombre_tabla = p_tabla)
   GROUP BY d.fecha_hora::date
   ORDER BY 1;
END $$;

-- ---------------------------------------------------------------------
-- 4. Estado actual de la auditoría por tabla
--    Muestra si la tabla está habilitada, cuántas columnas/eventos
--    están activos, si el trigger generado existe y cuántos registros
--    tiene en bitácora. Sirve para comprobar que "la tabla de
--    configuración refleja el estado actual".
--    Ej.: SELECT * FROM fn_reporte_estado_auditoria();
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_reporte_estado_auditoria()
RETURNS TABLE (
  nombre_tabla       text,
  tabla_habilitada   boolean,
  tabla_existe       boolean,
  columnas_activas   bigint,
  eventos_activos    text,
  trigger_instalado  boolean,
  registros_bitacora bigint
)
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT t.nombre_tabla::text,
         t.estado,
         pg_catalog.to_regclass(pg_catalog.format('public.%I', t.nombre_tabla)) IS NOT NULL,
         (SELECT count(DISTINCT ca.id_columna)
            FROM public.columna_auditada ca
            JOIN public.configuracion_auditoria c ON c.id_columna = ca.id_columna
           WHERE ca.id_tabla = t.id_tabla AND c.activo AND t.estado),
         (SELECT pg_catalog.string_agg(DISTINCT ev.tipo_evento::text, ', ')
            FROM public.columna_auditada ca
            JOIN public.configuracion_auditoria c ON c.id_columna = ca.id_columna
            JOIN public.evento_auditoria ev ON ev.id_evento = c.id_evento
           WHERE ca.id_tabla = t.id_tabla AND c.activo AND t.estado),
         EXISTS (SELECT 1 FROM pg_catalog.pg_trigger tr
                   JOIN pg_catalog.pg_proc p ON p.oid = tr.tgfoid
                   JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
                  WHERE tr.tgrelid = pg_catalog.to_regclass(pg_catalog.format('public.%I', t.nombre_tabla))
                    AND tr.tgname = 'aa_auditar_fila'
                    AND n.nspname = 'autoaudit_interno' AND p.proname = 'registrar_cambio'),
         (SELECT count(*) FROM public.bitacora b
            JOIN public.configuracion_auditoria c ON c.id_configuracion = b.id_configuracion
            JOIN public.columna_auditada ca ON ca.id_columna = c.id_columna
           WHERE ca.id_tabla = t.id_tabla)
    FROM public.tabla_auditada t
   ORDER BY t.nombre_tabla;
$$;

-- Estado del trigger para una sesión normal (origin/local). Se conserva
-- el contrato del reporte anterior, incluido el encabezado de su CSV.
CREATE OR REPLACE FUNCTION public.fn_reporte_estado_triggers()
RETURNS TABLE (
  nombre_tabla       text,
  trigger_instalado  boolean,
  trigger_habilitado boolean,
  modo_trigger       text
)
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT t.nombre_tabla::text,
         tr.oid IS NOT NULL,
         COALESCE(tr.tgenabled IN ('O', 'A'), false),
         tr.tgenabled::text
    FROM public.tabla_auditada t
    LEFT JOIN pg_catalog.pg_trigger tr
      ON tr.tgrelid = pg_catalog.to_regclass(pg_catalog.format('public.%I', t.nombre_tabla))
     AND tr.tgname = 'aa_auditar_fila'
     AND tr.tgfoid = 'autoaudit_interno.registrar_cambio()'::pg_catalog.regprocedure
   ORDER BY t.nombre_tabla;
$$;

REVOKE ALL ON FUNCTION
  public.fn_reporte_por_usuario(timestamp,timestamp),
  public.fn_reporte_por_columna(timestamp,timestamp,text),
  public.fn_reporte_actividad_diaria(timestamp,timestamp,text),
  public.fn_reporte_estado_auditoria(),
  public.fn_reporte_estado_triggers()
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  public.fn_reporte_por_usuario(timestamp,timestamp),
  public.fn_reporte_por_columna(timestamp,timestamp,text),
  public.fn_reporte_actividad_diaria(timestamp,timestamp,text),
  public.fn_reporte_estado_auditoria(),
  public.fn_reporte_estado_triggers()
TO autoaudit_consulta;

COMMIT;
