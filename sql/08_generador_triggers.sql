-- AutoAudit / Parte 3. Ejecutar despues de 07, con el mismo superusuario.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL check_function_bodies = on;
SET LOCAL search_path = pg_catalog, pg_temp;

CREATE OR REPLACE FUNCTION public.fn_autoaudit_regenerar(p_tabla text DEFAULT NULL)
RETURNS TABLE(tabla text, accion text, detalle text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_tabla text;
  v_oid oid;
  v_eventos text;
  v_pk jsonb;
  v_problema record;
  v_trigger record;
BEGIN
  PERFORM autoaudit_interno.exigir_admin();
  -- Serializa administraciones del modulo. Bloquea cambios concurrentes a la
  -- configuracion mientras se lee y aplica; no bloquea lectura de configuracion.
  PERFORM pg_catalog.pg_advisory_xact_lock(18401, 8);
  LOCK TABLE public.tabla_auditada, public.columna_auditada,
             public.configuracion_auditoria, public.evento_auditoria IN SHARE MODE;
  IF p_tabla IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.tabla_auditada t WHERE t.nombre_tabla = p_tabla) THEN
    RAISE EXCEPTION 'AutoAudit: tabla % no registrada en la configuracion',p_tabla
      USING ERRCODE = 'P0002';
  END IF;
  FOR v_problema IN SELECT * FROM public.fn_validar_configuracion() LOOP
    IF p_tabla IS NULL OR v_problema.nombre_tabla = p_tabla THEN
      RAISE EXCEPTION 'AutoAudit: configuracion invalida para %.%: %',
        v_problema.nombre_tabla, v_problema.nombre_columna, v_problema.problema
        USING ERRCODE = '22023', HINT = 'Corrija o desactive la configuracion obsoleta antes de regenerar.';
    END IF;
  END LOOP;

  -- Incluye triggers propios huerfanos de configuracion o con tabla renombrada.
  -- Se reconocen por la funcion ejecutada, nunca solo por un prefijo del nombre.
  FOR v_tabla IN
    SELECT t.nombre_tabla::text FROM public.tabla_auditada t
     WHERE p_tabla IS NULL OR t.nombre_tabla = p_tabla
    UNION
    SELECT c.relname::text FROM pg_catalog.pg_trigger tr
      JOIN pg_catalog.pg_class c ON c.oid = tr.tgrelid
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE tr.tgfoid = 'autoaudit_interno.registrar_cambio()'::regprocedure
       AND tr.tgparentid = 0 AND n.nspname = 'public'
       AND (p_tabla IS NULL OR c.relname = p_tabla)
    ORDER BY 1
  LOOP
    v_oid := pg_catalog.to_regclass(pg_catalog.format('public.%I', v_tabla));
    IF v_oid IS NULL THEN
      tabla := v_tabla; accion := 'SIN_TABLA'; detalle := 'Configuracion inactiva conservada';
      RETURN NEXT; CONTINUE;
    END IF;
    -- Evita que DDL concurrente cambie la tabla entre validar y crear el trigger.
    EXECUTE pg_catalog.format('LOCK TABLE public.%I IN SHARE ROW EXCLUSIVE MODE',v_tabla);
    SELECT pg_catalog.string_agg(x.tipo_evento, ' OR ' ORDER BY x.tipo_evento)
      INTO v_eventos FROM (
        SELECT DISTINCT c.tipo_evento FROM public.v_configuracion_actual c
         WHERE c.nombre_tabla = v_tabla AND c.activo AND c.tabla_habilitada
           AND c.tipo_evento IN ('INSERT','UPDATE','DELETE')) x;

    IF v_eventos IS NOT NULL THEN
      IF public.fn_es_tabla_sistema(v_tabla) THEN
        RAISE EXCEPTION 'AutoAudit: no se permiten triggers en tablas internas';
      END IF;
      -- Raices particionadas se soportan con clones nativos de PostgreSQL.
      -- Auditar ademas una particion o herencia clasica podria duplicar bitacora.
      IF EXISTS (SELECT 1 FROM pg_catalog.pg_class c
                  WHERE c.oid = v_oid AND (c.relispartition OR c.relkind NOT IN ('r','p')))
         OR EXISTS (SELECT 1 FROM pg_catalog.pg_inherits i
           JOIN pg_catalog.pg_class padre ON padre.oid = i.inhparent
           WHERE (i.inhrelid = v_oid OR i.inhparent = v_oid) AND padre.relkind <> 'p') THEN
        RAISE EXCEPTION 'AutoAudit: configure la raiz particionada, no particiones ni herencia clasica: %',v_tabla
          USING ERRCODE = '0A000';
      END IF;
      IF EXISTS (SELECT 1 FROM public.v_configuracion_actual cfg
         WHERE cfg.nombre_tabla = v_tabla AND cfg.activo AND cfg.tabla_habilitada
           AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
              WHERE a.attrelid = v_oid AND a.attname = cfg.nombre_columna
                AND a.attnum > 0 AND NOT a.attisdropped)) THEN
        RAISE EXCEPTION 'AutoAudit: columna eliminada de %', v_tabla USING ERRCODE = '22023';
      END IF;
      IF EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t WHERE t.tgrelid = v_oid
          AND t.tgname = 'aa_auditar_fila'
          AND t.tgfoid <> 'autoaudit_interno.registrar_cambio()'::regprocedure) THEN
        RAISE EXCEPTION 'AutoAudit: aa_auditar_fila ya pertenece a un trigger ajeno en %',v_tabla
          USING ERRCODE = '42710';
      END IF;
      SELECT COALESCE(pg_catalog.jsonb_agg(a.attname::text ORDER BY k.orden),'[]'::jsonb)
        INTO v_pk FROM pg_catalog.pg_index i
        CROSS JOIN LATERAL pg_catalog.unnest(i.indkey) WITH ORDINALITY k(numero,orden)
        JOIN pg_catalog.pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.numero
        WHERE i.indrelid = v_oid AND i.indisprimary AND k.orden <= i.indnkeyatts;
    END IF;

    FOR v_trigger IN SELECT t.tgname FROM pg_catalog.pg_trigger t
      WHERE t.tgrelid = v_oid AND t.tgparentid = 0
        AND t.tgfoid = 'autoaudit_interno.registrar_cambio()'::regprocedure
    LOOP
      EXECUTE pg_catalog.format('DROP TRIGGER %I ON public.%I',v_trigger.tgname,v_tabla);
    END LOOP;
    IF v_eventos IS NULL THEN
      tabla := v_tabla; accion := 'RETIRADO'; detalle := 'Sin eventos activos; historial conservado';
    ELSE
      -- Eventos provienen de una lista cerrada. Identificadores %I, argumentos %L.
      EXECUTE pg_catalog.format('CREATE TRIGGER aa_auditar_fila AFTER %s ON public.%I
        FOR EACH ROW EXECUTE FUNCTION autoaudit_interno.registrar_cambio(%L,%L,%L)',
        v_eventos, v_tabla, v_tabla, v_oid::text, v_pk::text);
      tabla := v_tabla; accion := 'GENERADO';
      detalle := v_eventos || CASE WHEN v_pk = '[]'::jsonb
        THEN '; sin PK: id_registro sera NULL' ELSE '; PK: ' || v_pk::text END;
    END IF;
    RETURN NEXT;
  END LOOP;
  -- Cualquier error revierte TODA la llamada, incluidos los DROP TRIGGER.
  -- No se deja una tabla sin auditoria tras una regeneracion fallida.
END $$;

CREATE OR REPLACE FUNCTION public.fn_autoaudit_retirar(p_tabla text DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE v_tr record; v_total integer := 0;
BEGIN
  PERFORM autoaudit_interno.exigir_admin();
  PERFORM pg_catalog.pg_advisory_xact_lock(18401,8);
  FOR v_tr IN
    SELECT t.tgname, n.nspname, c.relname FROM pg_catalog.pg_trigger t
      JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE t.tgfoid = 'autoaudit_interno.registrar_cambio()'::regprocedure
       AND t.tgparentid = 0 AND n.nspname = 'public'
       AND (p_tabla IS NULL OR c.relname = p_tabla)
     ORDER BY c.relname,t.tgname
  LOOP
    EXECUTE pg_catalog.format('DROP TRIGGER %I ON %I.%I',v_tr.tgname,v_tr.nspname,v_tr.relname);
    v_total := v_total + 1;
  END LOOP;
  RETURN v_total;
END $$;

REVOKE ALL ON FUNCTION public.fn_autoaudit_regenerar(text),
  public.fn_autoaudit_retirar(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_autoaudit_regenerar(text),
  public.fn_autoaudit_retirar(text) TO autoaudit_admin;
COMMIT;
