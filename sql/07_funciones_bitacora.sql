-- AutoAudit / Parte 3. Instalar con psql, como postgres, despues de 01,03,04,05.
-- Este archivo agrega objetos; no cambia columnas, PK, FK ni datos anteriores.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL check_function_bodies = on;
SET LOCAL search_path = pg_catalog, pg_temp;

DO $$
BEGIN
  IF current_setting('server_version_num')::integer / 10000 <> 18 THEN
    RAISE EXCEPTION 'Este modulo requiere PostgreSQL 18';
  END IF;
  IF NOT (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = current_user) THEN
    RAISE EXCEPTION 'Instale como superusuario (postgres)';
  END IF;
  IF pg_catalog.to_regclass('public.v_configuracion_actual') IS NULL
     OR pg_catalog.to_regprocedure('public.fn_validar_configuracion()') IS NULL THEN
    RAISE EXCEPTION 'Faltan los modulos 01, 03, 04 y 05';
  END IF;
END $$;

-- Solo el instalador accede a las funciones internas. No se agrega otra tabla.
CREATE SCHEMA IF NOT EXISTS autoaudit_interno;
REVOKE ALL ON SCHEMA autoaudit_interno FROM PUBLIC, autoaudit_admin;

CREATE OR REPLACE FUNCTION autoaudit_interno.exigir_admin()
RETURNS void LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  -- session_user conserva la identidad del cliente dentro de SECURITY DEFINER.
  IF NOT (SELECT r.rolsuper FROM pg_catalog.pg_roles r WHERE r.rolname = session_user)
     AND NOT pg_catalog.pg_has_role(session_user, 'autoaudit_admin', 'MEMBER') THEN
    RAISE EXCEPTION 'AutoAudit: se requiere el rol autoaudit_admin'
      USING ERRCODE = '42501';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION autoaudit_interno.registrar_cambio()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_cfg record;
  v_anterior text;
  v_nuevo text;
  v_cambio boolean;
  v_usuario integer;
  v_estacion integer;
  v_ip text := pg_catalog.host(pg_catalog.inet_client_addr());
  v_nombre_estacion text;
  v_id text;
  v_pk_anterior jsonb;
  v_pk_nueva jsonb;
  v_pk_columnas jsonb;
  v_origen oid;
BEGIN
  IF TG_WHEN <> 'AFTER' OR TG_LEVEL <> 'ROW' OR TG_NARGS <> 3 THEN
    RAISE EXCEPTION 'AutoAudit: contexto de trigger no valido';
  END IF;
  v_origen := TG_ARGV[1]::oid;
  v_pk_columnas := TG_ARGV[2]::jsonb;
  IF pg_catalog.to_regclass(pg_catalog.format('public.%I', TG_ARGV[0]))::oid
       IS DISTINCT FROM v_origen
     OR NOT (TG_RELID = v_origen OR EXISTS (
       -- SETOF regclass: se nombra explicitamente la unica columna devuelta.
       -- PostgreSQL 18 tambien la denomina relid mediante su parametro OUT.
       SELECT 1 FROM pg_catalog.pg_partition_ancestors(TG_RELID::regclass)
         AS a(ancestro)
        WHERE a.ancestro::oid = v_origen)) THEN
    RAISE EXCEPTION 'AutoAudit: cambio de identidad de la tabla; regenere los triggers';
  END IF;
  IF public.fn_es_tabla_sistema(TG_ARGV[0]) THEN
    RAISE EXCEPTION 'AutoAudit: no se auditan tablas internas';
  END IF;

  -- La PK se guarda como JSON en el campo TEXT que ya existe.
  -- No hay FK al registro de negocio: DELETE nunca elimina el historial.
  IF pg_catalog.jsonb_array_length(v_pk_columnas) > 0 THEN
    IF TG_OP <> 'INSERT' THEN
      SELECT pg_catalog.jsonb_object_agg(k, pg_catalog.to_jsonb(OLD) -> k)
        INTO v_pk_anterior FROM pg_catalog.jsonb_array_elements_text(v_pk_columnas) k;
    END IF;
    IF TG_OP <> 'DELETE' THEN
      SELECT pg_catalog.jsonb_object_agg(k, pg_catalog.to_jsonb(NEW) -> k)
        INTO v_pk_nueva FROM pg_catalog.jsonb_array_elements_text(v_pk_columnas) k;
    END IF;
    v_id := CASE
      WHEN TG_OP = 'DELETE' THEN v_pk_anterior::text
      WHEN TG_OP = 'UPDATE' AND v_pk_anterior IS DISTINCT FROM v_pk_nueva
        THEN pg_catalog.jsonb_build_object('anterior', v_pk_anterior, 'nuevo', v_pk_nueva)::text
      ELSE v_pk_nueva::text END;
  END IF;

  FOR v_cfg IN
    SELECT c.id_configuracion, c.nombre_columna
      FROM public.v_configuracion_actual c
     WHERE c.nombre_tabla = TG_ARGV[0] AND c.tabla_habilitada AND c.activo
       AND c.tipo_evento = TG_OP
     ORDER BY c.id_configuracion
  LOOP
    v_anterior := NULL;
    v_nuevo := NULL;
    IF TG_OP = 'INSERT' THEN
      EXECUTE pg_catalog.format('SELECT ($1).%I::text', v_cfg.nombre_columna)
        INTO v_nuevo USING NEW;
    ELSIF TG_OP = 'DELETE' THEN
      EXECUTE pg_catalog.format('SELECT ($1).%I::text', v_cfg.nombre_columna)
        INTO v_anterior USING OLD;
    ELSE
      -- Comparacion NATIVA, no igualdad de texto: 1.0 y 1.00 son iguales
      -- para numeric. IS DISTINCT FROM tambien compara NULL correctamente.
      BEGIN
        EXECUTE pg_catalog.format(
          'SELECT ($1).%1$I::text, ($2).%1$I::text, ($1).%1$I IS DISTINCT FROM ($2).%1$I',
          v_cfg.nombre_columna)
          INTO v_anterior, v_nuevo, v_cambio USING OLD, NEW;
      EXCEPTION WHEN undefined_function THEN
        -- Tipos sin operador de igualdad, p.ej. json: comparar representacion.
        EXECUTE pg_catalog.format('SELECT ($1).%1$I::text, ($2).%1$I::text',
                                  v_cfg.nombre_columna)
          INTO v_anterior, v_nuevo USING OLD, NEW;
        v_cambio := v_anterior IS DISTINCT FROM v_nuevo;
      END;
      IF NOT v_cambio THEN CONTINUE; END IF;
    END IF;

    -- Se resuelve el contexto una sola vez por fila, y solo si hay que auditar.
    IF v_usuario IS NULL THEN
      SELECT u.id_usuario INTO v_usuario FROM public.usuario_auditado u
       WHERE u.nombre_usuario = session_user ORDER BY u.id_usuario LIMIT 1;
      IF v_usuario IS NULL THEN
        -- Doble comprobacion con bloqueo: dos conexiones no crean duplicados.
        -- No se imponen UNIQUE nuevos a datos de los companeros.
        PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
          'AutoAudit/usuario/' || session_user, 0));
        SELECT u.id_usuario INTO v_usuario FROM public.usuario_auditado u
         WHERE u.nombre_usuario = session_user ORDER BY u.id_usuario LIMIT 1;
        IF v_usuario IS NULL THEN
          INSERT INTO public.usuario_auditado(nombre_usuario) VALUES (session_user)
            RETURNING id_usuario INTO v_usuario;
        END IF;
      END IF;
      v_nombre_estacion := CASE WHEN v_ip IS NULL THEN 'SIN_IP_DISPONIBLE'
                                ELSE 'IP:' || v_ip END;
      SELECT e.id_estacion INTO v_estacion FROM public.estacion_trabajo e
       WHERE e.nombre_estacion = v_nombre_estacion
         AND e.direccion_ip IS NOT DISTINCT FROM v_ip
       ORDER BY e.id_estacion LIMIT 1;
      IF v_estacion IS NULL THEN
        PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
          'AutoAudit/estacion/' || v_nombre_estacion, 0));
        SELECT e.id_estacion INTO v_estacion FROM public.estacion_trabajo e
         WHERE e.nombre_estacion = v_nombre_estacion
           AND e.direccion_ip IS NOT DISTINCT FROM v_ip
         ORDER BY e.id_estacion LIMIT 1;
        IF v_estacion IS NULL THEN
          INSERT INTO public.estacion_trabajo(nombre_estacion, direccion_ip)
            VALUES (v_nombre_estacion, v_ip) RETURNING id_estacion INTO v_estacion;
        END IF;
      END IF;
    END IF;

    INSERT INTO public.bitacora(id_configuracion, id_usuario, id_estacion,
                               valor_anterior, valor_nuevo, fecha_hora, id_registro)
      VALUES (v_cfg.id_configuracion, v_usuario, v_estacion, v_anterior, v_nuevo,
              pg_catalog.clock_timestamp() AT TIME ZONE 'America/Guatemala', v_id);
  END LOOP;
  -- Los valores de retorno de un trigger AFTER no modifican la fila origen.
  -- NO se ocultan errores: si falla la auditoria se revierte la operacion origen.
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION autoaudit_interno.proteger_historial()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  -- Profundidad sola no basta: se exige tambien el propietario del registrador.
  -- Un trigger creado por un usuario normal no puede fingir este contexto.
  IF TG_OP = 'INSERT' AND pg_catalog.pg_trigger_depth() > 1
     AND current_user = pg_catalog.pg_get_userbyid((
       SELECT p.proowner FROM pg_catalog.pg_proc p
        WHERE p.oid = 'autoaudit_interno.registrar_cambio()'::regprocedure)) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'AutoAudit: escritura directa o borrado de historial no permitido en %', TG_TABLE_NAME
    USING ERRCODE = '42501';
END $$;

-- Ademas del REVOKE, el guardia impide DML directo aunque existiera un GRANT
-- particular anterior. No se borran esos permisos ni registros historicos.
DO $$
DECLARE v_tabla text; v_trigger text;
BEGIN
  FOREACH v_tabla IN ARRAY ARRAY['bitacora','usuario_auditado','estacion_trabajo'] LOOP
    FOREACH v_trigger IN ARRAY ARRAY['aa_proteger_filas','aa_proteger_truncate'] LOOP
      IF EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t
        WHERE t.tgrelid = pg_catalog.to_regclass(pg_catalog.format('public.%I',v_tabla))
          AND t.tgname = v_trigger
          AND t.tgfoid <> 'autoaudit_interno.proteger_historial()'::regprocedure) THEN
        RAISE EXCEPTION 'Colision con trigger ajeno %.%',v_tabla,v_trigger;
      END IF;
    END LOOP;
    EXECUTE pg_catalog.format('CREATE OR REPLACE TRIGGER aa_proteger_filas
      BEFORE INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW
      EXECUTE FUNCTION autoaudit_interno.proteger_historial()', v_tabla);
    EXECUTE pg_catalog.format('CREATE OR REPLACE TRIGGER aa_proteger_truncate
      BEFORE TRUNCATE ON public.%I FOR EACH STATEMENT
      EXECUTE FUNCTION autoaudit_interno.proteger_historial()', v_tabla);
  END LOOP;
END $$;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.bitacora,
  public.usuario_auditado, public.estacion_trabajo FROM PUBLIC, autoaudit_admin;
REVOKE ALL ON SEQUENCE public.bitacora_id_bitacora_seq,
  public.usuario_auditado_id_usuario_seq, public.estacion_trabajo_id_estacion_seq
  FROM PUBLIC, autoaudit_admin;
GRANT SELECT ON public.bitacora, public.usuario_auditado, public.estacion_trabajo
  TO autoaudit_admin;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA autoaudit_interno FROM PUBLIC, autoaudit_admin;
COMMIT;
