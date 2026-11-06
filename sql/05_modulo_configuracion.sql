-- =====================================================================
-- AutoAudit - 05_modulo_configuracion.sql
-- Módulo de configuración de auditoría: selección de tablas, selección
-- granular de columnas y activación por tipo de operación.
--
-- Todas las funciones:
--   * son SECURITY DEFINER (las tablas de configuración no se tocan
--     directamente) y validan que quien llama sea administrador;
--   * validan que la tabla y las columnas EXISTAN antes de registrarlas.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Seguridad: ¿el usuario de la sesión es administrador de auditoría?
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_es_admin_auditoria()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT COALESCE((SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = session_user), false)
      OR pg_catalog.pg_has_role(session_user, 'autoaudit_admin', 'member');
$$;

CREATE OR REPLACE FUNCTION public.fn_exigir_admin()
RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF NOT public.fn_es_admin_auditoria() THEN
    RAISE EXCEPTION 'Acceso denegado: el usuario "%" no tiene privilegios para configurar la auditoría.', session_user
      USING ERRCODE = '42501';
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- Validaciones de existencia (diccionario de datos)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_existe_tabla(p_tabla text)
RETURNS boolean
LANGUAGE sql STABLE
AS $$
  SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_class c
                 JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                 WHERE n.nspname = 'public' AND c.relname = p_tabla
                   AND c.relkind IN ('r','p'));
$$;

CREATE OR REPLACE FUNCTION public.fn_existe_columna(p_tabla text, p_columna text)
RETURNS boolean
LANGUAGE sql STABLE
AS $$
  SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
                 JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
                 JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                 WHERE n.nspname = 'public' AND c.relname = p_tabla
                   AND a.attname = p_columna
                   AND a.attnum > 0 AND NOT a.attisdropped);
$$;

-- ---------------------------------------------------------------------
-- 1. Seleccionar (registrar / habilitar) una tabla para auditoría
--    Devuelve id_tabla.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_seleccionar_tabla(p_tabla text)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_id integer;
BEGIN
  PERFORM public.fn_exigir_admin();

  IF p_tabla IS NULL OR btrim(p_tabla) = '' THEN
    RAISE EXCEPTION 'Debe indicar el nombre de la tabla.' USING ERRCODE = '22004';
  END IF;
  IF public.fn_es_tabla_sistema(p_tabla) THEN
    RAISE EXCEPTION 'La tabla "%" pertenece al sistema AutoAudit y no puede auditarse.', p_tabla
      USING ERRCODE = '42809';
  END IF;
  IF NOT public.fn_existe_tabla(p_tabla) THEN
    RAISE EXCEPTION 'La tabla "%" no existe en el esquema public.', p_tabla
      USING ERRCODE = '42P01';
  END IF;

  INSERT INTO public.tabla_auditada (nombre_tabla, estado)
  VALUES (p_tabla, true)
  ON CONFLICT (nombre_tabla) DO UPDATE SET estado = true
  RETURNING id_tabla INTO v_id;

  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- 2. Seleccionar una columna de una tabla (registro granular).
--    La tabla se registra automáticamente si aún no lo estaba.
--    Devuelve id_columna.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_seleccionar_columna(p_tabla text, p_columna text)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_id_tabla integer;
  v_id       integer;
BEGIN
  PERFORM public.fn_exigir_admin();

  v_id_tabla := public.fn_seleccionar_tabla(p_tabla);

  IF NOT public.fn_existe_columna(p_tabla, p_columna) THEN
    RAISE EXCEPTION 'La columna "%" no existe en la tabla "%".', p_columna, p_tabla
      USING ERRCODE = '42703';
  END IF;

  INSERT INTO public.columna_auditada (id_tabla, nombre_columna)
  VALUES (v_id_tabla, p_columna)
  ON CONFLICT (id_tabla, nombre_columna) DO UPDATE
    SET nombre_columna = EXCLUDED.nombre_columna      -- no-op para poder usar RETURNING
  RETURNING id_columna INTO v_id;

  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- 3. Configurar auditoría completa de una tabla en una sola llamada.
--      p_columnas : columnas a auditar (NULL = todas las de la tabla)
--      p_eventos  : eventos a activar  (NULL = INSERT, UPDATE y DELETE)
--    Es todo-o-nada: si algo falla, no se guarda nada (una sola
--    transacción por ser una función). Devuelve el número de
--    configuraciones activadas.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_configurar_auditoria(
  p_tabla    text,
  p_columnas text[] DEFAULT NULL,
  p_eventos  text[] DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_cols   text[];
  v_evs    text[];
  v_col    text;
  v_ev     text;
  v_id_col integer;
  v_id_ev  integer;
  v_total  integer := 0;
BEGIN
  PERFORM public.fn_exigir_admin();
  PERFORM public.fn_seleccionar_tabla(p_tabla);          -- valida y registra

  -- Columnas: todas si no se indican
  IF p_columnas IS NULL OR cardinality(p_columnas) = 0 THEN
    SELECT array_agg(a.attname::text ORDER BY a.attnum) INTO v_cols
    FROM pg_catalog.pg_attribute a
    JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = p_tabla
      AND a.attnum > 0 AND NOT a.attisdropped;
  ELSE
    SELECT array_agg(DISTINCT x) INTO v_cols FROM unnest(p_columnas) AS x;
  END IF;

  -- Eventos: todos si no se indican
  IF p_eventos IS NULL OR cardinality(p_eventos) = 0 THEN
    v_evs := ARRAY['INSERT','UPDATE','DELETE'];
  ELSE
    SELECT array_agg(DISTINCT upper(btrim(x))) INTO v_evs FROM unnest(p_eventos) AS x;
  END IF;

  -- Validar eventos
  FOREACH v_ev IN ARRAY v_evs LOOP
    IF NOT EXISTS (SELECT 1 FROM public.evento_auditoria WHERE tipo_evento = v_ev) THEN
      RAISE EXCEPTION 'Evento "%" no válido. Use INSERT, UPDATE o DELETE.', v_ev
        USING ERRCODE = '22023';
    END IF;
  END LOOP;

  -- Validar TODAS las columnas antes de escribir nada
  FOREACH v_col IN ARRAY v_cols LOOP
    IF NOT public.fn_existe_columna(p_tabla, v_col) THEN
      RAISE EXCEPTION 'La columna "%" no existe en la tabla "%".', v_col, p_tabla
        USING ERRCODE = '42703';
    END IF;
  END LOOP;

  -- Persistir configuración
  FOREACH v_col IN ARRAY v_cols LOOP
    v_id_col := public.fn_seleccionar_columna(p_tabla, v_col);
    FOREACH v_ev IN ARRAY v_evs LOOP
      SELECT id_evento INTO v_id_ev FROM public.evento_auditoria WHERE tipo_evento = v_ev;

      INSERT INTO public.configuracion_auditoria (id_columna, id_evento, activo)
      VALUES (v_id_col, v_id_ev, true)
      ON CONFLICT (id_columna, id_evento) DO UPDATE SET activo = true;

      v_total := v_total + 1;
    END LOOP;
  END LOOP;

  RETURN v_total;
END $$;

-- ---------------------------------------------------------------------
-- 4. Activar / desactivar un evento puntual de una columna
--    (nunca se borra la fila: la bitácora conserva su referencia)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_cambiar_estado_evento(
  p_tabla   text,
  p_columna text,
  p_evento  text,
  p_activo  boolean
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_n integer;
BEGIN
  PERFORM public.fn_exigir_admin();
  p_evento := upper(btrim(p_evento));

  IF p_activo THEN
    -- Activar exige que tabla y columna existan hoy; crea la config si falta
    IF NOT EXISTS (SELECT 1 FROM public.evento_auditoria WHERE tipo_evento = p_evento) THEN
      RAISE EXCEPTION 'Evento "%" no válido. Use INSERT, UPDATE o DELETE.', p_evento
        USING ERRCODE = '22023';
    END IF;
    PERFORM public.fn_configurar_auditoria(p_tabla, ARRAY[p_columna], ARRAY[p_evento]);
    RETURN;
  END IF;

  UPDATE public.configuracion_auditoria cfg
     SET activo = false
    FROM public.columna_auditada ca
    JOIN public.tabla_auditada t   ON t.id_tabla = ca.id_tabla
    JOIN public.evento_auditoria e ON e.tipo_evento = p_evento
   WHERE cfg.id_columna = ca.id_columna
     AND cfg.id_evento  = e.id_evento
     AND t.nombre_tabla = p_tabla
     AND ca.nombre_columna = p_columna;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  IF v_n = 0 THEN
    RAISE EXCEPTION 'No existe configuración de % para %.%.', p_evento, p_tabla, p_columna
      USING ERRCODE = 'P0002';
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- 5. Deshabilitar / rehabilitar toda la auditoría de una tabla
--    Deshabilitar conserva la configuración (se puede reactivar) y
--    desactiva todos sus eventos.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_deshabilitar_tabla(p_tabla text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_id integer;
BEGIN
  PERFORM public.fn_exigir_admin();
  SELECT id_tabla INTO v_id FROM public.tabla_auditada WHERE nombre_tabla = p_tabla;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'La tabla "%" no está configurada para auditoría.', p_tabla
      USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.tabla_auditada SET estado = false WHERE id_tabla = v_id;
  UPDATE public.configuracion_auditoria SET activo = false
   WHERE id_columna IN (SELECT id_columna FROM public.columna_auditada WHERE id_tabla = v_id);
END $$;

-- ---------------------------------------------------------------------
-- 6. Verificación de consistencia: configuraciones que apuntan a tablas
--    o columnas que ya no existen en la base (p. ej. tras un DROP).
--    Útil antes de regenerar triggers.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_validar_configuracion()
RETURNS TABLE (nombre_tabla text, nombre_columna text, problema text)
LANGUAGE sql STABLE
AS $$
  SELECT t.nombre_tabla::text, NULL::text, 'La tabla ya no existe'
    FROM public.tabla_auditada t
   WHERE t.estado AND NOT public.fn_existe_tabla(t.nombre_tabla)
  UNION ALL
  SELECT t.nombre_tabla::text, ca.nombre_columna::text, 'La columna ya no existe'
    FROM public.columna_auditada ca
    JOIN public.tabla_auditada t ON t.id_tabla = ca.id_tabla
   WHERE t.estado AND public.fn_existe_tabla(t.nombre_tabla)
     AND NOT public.fn_existe_columna(t.nombre_tabla, ca.nombre_columna)
     AND EXISTS (SELECT 1 FROM public.configuracion_auditoria c
                  WHERE c.id_columna = ca.id_columna AND c.activo);
$$;

-- ---------------------------------------------------------------------
-- Permisos: solo administradores pueden ejecutar el módulo
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION
  public.fn_es_admin_auditoria(), public.fn_exigir_admin(),
  public.fn_seleccionar_tabla(text), public.fn_seleccionar_columna(text,text),
  public.fn_configurar_auditoria(text,text[],text[]),
  public.fn_cambiar_estado_evento(text,text,text,boolean),
  public.fn_deshabilitar_tabla(text), public.fn_validar_configuracion()
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
  public.fn_es_admin_auditoria(), public.fn_exigir_admin(),
  public.fn_seleccionar_tabla(text), public.fn_seleccionar_columna(text,text),
  public.fn_configurar_auditoria(text,text[],text[]),
  public.fn_cambiar_estado_evento(text,text,text,boolean),
  public.fn_deshabilitar_tabla(text), public.fn_validar_configuracion()
TO autoaudit_admin;
