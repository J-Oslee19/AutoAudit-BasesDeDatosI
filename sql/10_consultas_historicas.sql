-- =====================================================================
-- AutoAudit - 10_consultas_historicas.sql
-- Parte 4: Módulo de consulta histórica de cambios.
--
-- Consultas parametrizadas sobre la bitácora:
--   * por usuario                (fn_historial_usuario)
--   * por columna específica     (fn_historial_columna)
--   * por registro afectado      (fn_historial_registro)
--   * línea de tiempo cronológica (fn_linea_tiempo)
--
-- Instalar como postgres DESPUÉS de 01, 03, 04, 05, 07 y 08:
--   psql -X -v ON_ERROR_STOP=1 -d autoaudit -f sql/10_consultas_historicas.sql
--
-- No modifica columnas, PK, FK ni datos de los módulos anteriores.
-- Solo agrega: una vista, cinco funciones de lectura, tres índices de
-- consulta y el rol de solo lectura autoaudit_consulta.
-- =====================================================================
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL check_function_bodies = on;
SET LOCAL search_path = pg_catalog, pg_temp;

DO $$
BEGIN
  IF pg_catalog.to_regclass('public.bitacora') IS NULL
     OR pg_catalog.to_regprocedure('public.fn_autoaudit_regenerar(text)') IS NULL THEN
    RAISE EXCEPTION 'Instale primero los módulos 01, 03, 04, 05, 07 y 08';
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- Rol de solo lectura para consultar el historial.
-- Puede leer la bitácora pero NO configurar ni escribir (la escritura
-- directa sigue bloqueada por los REVOKE y guardias del módulo 07).
-- ---------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'autoaudit_consulta') THEN
    CREATE ROLE autoaudit_consulta NOLOGIN;
  END IF;
END $$;
-- Los administradores también pueden consultar.
DO $$
BEGIN
  IF NOT pg_catalog.pg_has_role('autoaudit_admin', 'autoaudit_consulta', 'MEMBER') THEN
    GRANT autoaudit_consulta TO autoaudit_admin;
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- Índices para las consultas históricas (no cambian datos ni columnas).
-- Las búsquedas siempre filtran por usuario o por configuración
-- (tabla+columna+evento) y ordenan por fecha.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS ix_bitacora_usuario_fecha
  ON public.bitacora (id_usuario, fecha_hora, id_bitacora);
CREATE INDEX IF NOT EXISTS ix_bitacora_configuracion_fecha
  ON public.bitacora (id_configuracion, fecha_hora, id_bitacora);
CREATE INDEX IF NOT EXISTS ix_bitacora_fecha
  ON public.bitacora (fecha_hora, id_bitacora);

-- ---------------------------------------------------------------------
-- Vista base: cada fila de bitácora con todo su contexto legible.
-- Se une con las tablas base (no con v_configuracion_actual) y NO se
-- filtra por "activo": el historial de una configuración desactivada
-- sigue siendo válido.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_bitacora_detalle AS
SELECT b.id_bitacora,
       b.fecha_hora,
       t.nombre_tabla::text      AS nombre_tabla,
       ca.nombre_columna::text   AS nombre_columna,
       ev.tipo_evento::text      AS tipo_evento,
       b.id_registro,
       b.valor_anterior,
       b.valor_nuevo,
       u.nombre_usuario::text    AS nombre_usuario,
       e.nombre_estacion::text   AS nombre_estacion,
       e.direccion_ip::text      AS direccion_ip,
       b.id_configuracion,
       cfg.activo                AS configuracion_activa,
       b.id_usuario,
       b.id_estacion
FROM public.bitacora b
JOIN public.configuracion_auditoria cfg ON cfg.id_configuracion = b.id_configuracion
JOIN public.columna_auditada ca         ON ca.id_columna = cfg.id_columna
JOIN public.tabla_auditada t            ON t.id_tabla = ca.id_tabla
JOIN public.evento_auditoria ev         ON ev.id_evento = cfg.id_evento
JOIN public.usuario_auditado u          ON u.id_usuario = b.id_usuario
JOIN public.estacion_trabajo e          ON e.id_estacion = b.id_estacion;

COMMENT ON VIEW public.v_bitacora_detalle IS
  'AutoAudit: bitácora con tabla, columna, evento, usuario y estación legibles';

-- ---------------------------------------------------------------------
-- Validación común de rango de fechas.
-- p_desde inclusivo, p_hasta EXCLUSIVO: ('2026-11-01','2026-11-02')
-- devuelve todo el 1 de noviembre. NULL = sin límite.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_validar_rango(p_desde timestamp, p_hasta timestamp)
RETURNS void
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF p_desde IS NOT NULL AND p_hasta IS NOT NULL AND p_hasta <= p_desde THEN
    RAISE EXCEPTION 'Rango de fechas inválido: "hasta" (%) debe ser mayor que "desde" (%).',
      p_hasta, p_desde USING ERRCODE = '22023';
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- 1. Historial por USUARIO
--    Devuelve todas las modificaciones hechas por un usuario de BD,
--    en orden cronológico. Filtros opcionales: rango de fechas y tabla.
--    Ej.: SELECT * FROM fn_historial_usuario('app_ventas');
--         SELECT * FROM fn_historial_usuario('app_ventas','2026-11-01','2026-11-02');
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_historial_usuario(
  p_usuario text,
  p_desde   timestamp DEFAULT NULL,
  p_hasta   timestamp DEFAULT NULL,
  p_tabla   text      DEFAULT NULL
)
RETURNS SETOF public.v_bitacora_detalle
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_ids integer[];
BEGIN
  IF p_usuario IS NULL OR pg_catalog.btrim(p_usuario) = '' THEN
    RAISE EXCEPTION 'Debe indicar el nombre del usuario.' USING ERRCODE = '22004';
  END IF;
  PERFORM public.fn_validar_rango(p_desde, p_hasta);
  -- Se resuelven primero los id_usuario (puede haber duplicados antiguos)
  -- para que la búsqueda use el índice ix_bitacora_usuario_fecha.
  SELECT pg_catalog.array_agg(u.id_usuario) INTO v_ids
    FROM public.usuario_auditado u WHERE u.nombre_usuario = p_usuario;
  IF v_ids IS NULL THEN
    RAISE NOTICE 'El usuario "%" no tiene cambios registrados en la bitácora.', p_usuario;
    RETURN;
  END IF;

  RETURN QUERY
  SELECT d.* FROM public.v_bitacora_detalle d
   WHERE d.id_usuario = ANY (v_ids)
     AND (p_desde IS NULL OR d.fecha_hora >= p_desde)
     AND (p_hasta IS NULL OR d.fecha_hora <  p_hasta)
     AND (p_tabla IS NULL OR d.nombre_tabla = p_tabla)
   ORDER BY d.fecha_hora, d.id_bitacora;
END $$;

-- ---------------------------------------------------------------------
-- 2. Historial por COLUMNA específica
--    Todos los cambios de una columna de una tabla, en orden cronológico.
--    Filtros opcionales: rango de fechas y tipo de evento.
--    Funciona aunque la tabla o la columna ya se hayan eliminado o su
--    configuración esté desactivada (el historial se conserva).
--    Ej.: SELECT * FROM fn_historial_columna('empleado','salario');
--         SELECT * FROM fn_historial_columna('empleado','salario',NULL,NULL,'UPDATE');
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_historial_columna(
  p_tabla   text,
  p_columna text,
  p_desde   timestamp DEFAULT NULL,
  p_hasta   timestamp DEFAULT NULL,
  p_evento  text      DEFAULT NULL
)
RETURNS SETOF public.v_bitacora_detalle
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_evento text := pg_catalog.upper(pg_catalog.btrim(p_evento));
  v_cfg    integer[];
BEGIN
  IF p_tabla IS NULL OR p_columna IS NULL THEN
    RAISE EXCEPTION 'Debe indicar la tabla y la columna.' USING ERRCODE = '22004';
  END IF;
  PERFORM public.fn_validar_rango(p_desde, p_hasta);
  IF v_evento IS NOT NULL AND v_evento NOT IN ('INSERT','UPDATE','DELETE') THEN
    RAISE EXCEPTION 'Evento "%" no válido. Use INSERT, UPDATE o DELETE.', p_evento
      USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.columna_auditada ca
                   JOIN public.tabla_auditada t ON t.id_tabla = ca.id_tabla
                  WHERE t.nombre_tabla = p_tabla AND ca.nombre_columna = p_columna) THEN
    RAISE EXCEPTION 'La columna "%.%" nunca fue configurada para auditoría.', p_tabla, p_columna
      USING ERRCODE = 'P0002';
  END IF;

  -- Configuraciones de esa columna (todas, activas o no) -> índice
  -- ix_bitacora_configuracion_fecha.
  SELECT pg_catalog.array_agg(c.id_configuracion) INTO v_cfg
    FROM public.configuracion_auditoria c
    JOIN public.columna_auditada ca ON ca.id_columna = c.id_columna
    JOIN public.tabla_auditada t ON t.id_tabla = ca.id_tabla
    JOIN public.evento_auditoria ev ON ev.id_evento = c.id_evento
   WHERE t.nombre_tabla = p_tabla AND ca.nombre_columna = p_columna
     AND (v_evento IS NULL OR ev.tipo_evento = v_evento);
  IF v_cfg IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT d.* FROM public.v_bitacora_detalle d
   WHERE d.id_configuracion = ANY (v_cfg)
     AND (p_desde IS NULL OR d.fecha_hora >= p_desde)
     AND (p_hasta IS NULL OR d.fecha_hora <  p_hasta)
   ORDER BY d.fecha_hora, d.id_bitacora;
END $$;

-- ---------------------------------------------------------------------
-- 3. Historial de un REGISTRO (fila) concreto
--    Busca por la clave primaria guardada en id_registro (JSON).
--    Encuentra también los UPDATE que cambiaron la PK, porque compara
--    contra la forma simple y contra {"anterior":..} / {"nuevo":..}.
--    Ej.: SELECT * FROM fn_historial_registro('empleado','{"id_empleado": 5}');
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_historial_registro(
  p_tabla text,
  p_pk    jsonb
)
RETURNS SETOF public.v_bitacora_detalle
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF p_tabla IS NULL OR p_pk IS NULL OR pg_catalog.jsonb_typeof(p_pk) <> 'object' THEN
    RAISE EXCEPTION 'Indique la tabla y la PK como objeto JSON, p. ej. {"id": 1}.'
      USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  SELECT d.* FROM public.v_bitacora_detalle d
   WHERE d.nombre_tabla = p_tabla
     AND d.id_registro IS NOT NULL
     AND (d.id_registro::jsonb = p_pk
          OR d.id_registro::jsonb -> 'anterior' = p_pk
          OR d.id_registro::jsonb -> 'nuevo' = p_pk)
   ORDER BY d.fecha_hora, d.id_bitacora;
END $$;

-- ---------------------------------------------------------------------
-- 4. LÍNEA DE TIEMPO cronológica general
--    Todos los cambios en un período, opcionalmente filtrados por tabla,
--    usuario o evento. p_limite = últimos N cambios (NULL = todos).
--    Ej.: SELECT * FROM fn_linea_tiempo('2026-11-01','2026-11-02');
--         SELECT * FROM fn_linea_tiempo(p_limite => 20);   -- últimos 20
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_linea_tiempo(
  p_desde   timestamp DEFAULT NULL,
  p_hasta   timestamp DEFAULT NULL,
  p_tabla   text      DEFAULT NULL,
  p_usuario text      DEFAULT NULL,
  p_evento  text      DEFAULT NULL,
  p_limite  integer   DEFAULT NULL
)
RETURNS SETOF public.v_bitacora_detalle
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_evento   text := pg_catalog.upper(pg_catalog.btrim(p_evento));
  v_usuarios integer[];
  v_cfg      integer[];
BEGIN
  PERFORM public.fn_validar_rango(p_desde, p_hasta);
  IF p_limite IS NOT NULL AND p_limite <= 0 THEN
    RAISE EXCEPTION 'El límite debe ser mayor que cero.' USING ERRCODE = '22023';
  END IF;
  IF v_evento IS NOT NULL AND v_evento NOT IN ('INSERT','UPDATE','DELETE') THEN
    RAISE EXCEPTION 'Evento "%" no válido. Use INSERT, UPDATE o DELETE.', p_evento
      USING ERRCODE = '22023';
  END IF;

  -- Los filtros por nombre se convierten antes en listas de id para que
  -- la búsqueda use los índices de bitácora.
  IF p_usuario IS NOT NULL THEN
    SELECT COALESCE(pg_catalog.array_agg(u.id_usuario), '{}') INTO v_usuarios
      FROM public.usuario_auditado u WHERE u.nombre_usuario = p_usuario;
  END IF;
  IF p_tabla IS NOT NULL OR v_evento IS NOT NULL THEN
    SELECT COALESCE(pg_catalog.array_agg(c.id_configuracion), '{}') INTO v_cfg
      FROM public.configuracion_auditoria c
      JOIN public.columna_auditada ca ON ca.id_columna = c.id_columna
      JOIN public.tabla_auditada t ON t.id_tabla = ca.id_tabla
      JOIN public.evento_auditoria ev ON ev.id_evento = c.id_evento
     WHERE (p_tabla IS NULL OR t.nombre_tabla = p_tabla)
       AND (v_evento IS NULL OR ev.tipo_evento = v_evento);
  END IF;

  -- SQL dinámico (solo valores con USING, sin concatenar datos): así
  -- PostgreSQL planifica con los valores reales y aprovecha el LIMIT con
  -- el índice ix_bitacora_fecha. Primero se eligen los id de bitácora y
  -- después se completa el detalle; el resultado sale en orden cronológico.
  RETURN QUERY EXECUTE
   'SELECT d.* FROM public.v_bitacora_detalle d
     WHERE d.id_bitacora IN (
       SELECT b.id_bitacora FROM public.bitacora b
        WHERE ($1 IS NULL OR b.fecha_hora >= $1)
          AND ($2 IS NULL OR b.fecha_hora <  $2)
          AND ($3 IS NULL OR b.id_usuario = ANY ($3))
          AND ($4 IS NULL OR b.id_configuracion = ANY ($4))
        ORDER BY b.fecha_hora DESC, b.id_bitacora DESC
        LIMIT $5)
     ORDER BY d.fecha_hora, d.id_bitacora'
  USING p_desde, p_hasta, v_usuarios, v_cfg, p_limite;
END $$;

-- ---------------------------------------------------------------------
-- Permisos: solo lectura para autoaudit_consulta (y por herencia, admin)
-- ---------------------------------------------------------------------
REVOKE ALL ON public.v_bitacora_detalle FROM PUBLIC;
REVOKE ALL ON FUNCTION
  public.fn_validar_rango(timestamp,timestamp),
  public.fn_historial_usuario(text,timestamp,timestamp,text),
  public.fn_historial_columna(text,text,timestamp,timestamp,text),
  public.fn_historial_registro(text,jsonb),
  public.fn_linea_tiempo(timestamp,timestamp,text,text,text,integer)
FROM PUBLIC;

GRANT SELECT ON public.bitacora, public.usuario_auditado, public.estacion_trabajo,
                public.tabla_auditada, public.columna_auditada,
                public.evento_auditoria, public.configuracion_auditoria,
                public.v_bitacora_detalle
  TO autoaudit_consulta;
GRANT EXECUTE ON FUNCTION
  public.fn_validar_rango(timestamp,timestamp),
  public.fn_historial_usuario(text,timestamp,timestamp,text),
  public.fn_historial_columna(text,text,timestamp,timestamp,text),
  public.fn_historial_registro(text,jsonb),
  public.fn_linea_tiempo(timestamp,timestamp,text,text,text,integer)
TO autoaudit_consulta;

COMMIT;
