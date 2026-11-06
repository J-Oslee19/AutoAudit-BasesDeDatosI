-- SOLO en una BD desechable llamada autoaudit_pruebas (o con ese prefijo).
-- psql -X -v ON_ERROR_STOP=1 -d autoaudit_pruebas -f sql/09_pruebas_triggers.sql
-- Todo se revierte al final; las secuencias existentes pueden dejar huecos.
\set ON_ERROR_STOP on
\timing on
BEGIN;
SET LOCAL check_function_bodies = on;
SET LOCAL search_path = public, pg_catalog;
SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
  IF current_setting('server_version_num')::integer / 10000 <> 18 THEN
    RAISE EXCEPTION 'Ejecute estas pruebas exclusivamente en PostgreSQL 18';
  END IF;
  IF current_database() NOT LIKE 'autoaudit_pruebas%' THEN
    RAISE EXCEPTION 'Use exclusivamente una BD desechable autoaudit_pruebas';
  END IF;
  IF NOT (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = session_user) THEN
    RAISE EXCEPTION 'Las pruebas requieren postgres para simular usuarios';
  END IF;
  IF EXISTS (SELECT 1 FROM public.configuracion_auditoria)
     OR EXISTS (SELECT 1 FROM public.bitacora) THEN
    RAISE EXCEPTION 'Use una instalacion de prueba sin configuraciones ni historial';
  END IF;
END $$;

CREATE FUNCTION pg_temp.aa_comprobar(p_condicion boolean, p_caso text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_condicion IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FALLO: %',p_caso;
  END IF;
  RAISE NOTICE 'OK: %',p_caso;
END $$;

CREATE TABLE public.aa_prueba_datos (
  id integer PRIMARY KEY, valor numeric(12,2), nota text, no_auditada text);
CREATE ROLE aa_pruebas_operador NOLOGIN;
CREATE ROLE aa_pruebas_configurador NOLOGIN;
GRANT autoaudit_admin TO aa_pruebas_configurador;
GRANT USAGE ON SCHEMA public TO aa_pruebas_operador;
GRANT INSERT,UPDATE,DELETE,SELECT ON public.aa_prueba_datos TO aa_pruebas_operador;

-- El recorrido positivo debe funcionar SIN permisos directos sobre el historial.
SELECT pg_temp.aa_comprobar(
 NOT pg_catalog.has_table_privilege('aa_pruebas_operador','public.bitacora','INSERT')
 AND NOT pg_catalog.has_table_privilege('aa_pruebas_operador','public.usuario_auditado','INSERT')
 AND NOT pg_catalog.has_table_privilege('aa_pruebas_operador','public.estacion_trabajo','INSERT'),
 'Operador sin INSERT directo en bitacora, usuarios y estaciones');
SELECT pg_temp.aa_comprobar(
 (SELECT p.prosecdef FROM pg_catalog.pg_proc p
   WHERE p.oid='autoaudit_interno.registrar_cambio()'::regprocedure)
 AND NOT (SELECT p.prosecdef FROM pg_catalog.pg_proc p
   WHERE p.oid='autoaudit_interno.proteger_historial()'::regprocedure),
 'Registrador SECURITY DEFINER y guardia SECURITY INVOKER');

SET SESSION AUTHORIZATION aa_pruebas_configurador;
SELECT public.fn_configurar_auditoria('aa_prueba_datos', ARRAY['valor','nota']);
SELECT * FROM public.fn_autoaudit_regenerar('aa_prueba_datos');
SELECT * FROM public.fn_autoaudit_regenerar('aa_prueba_datos');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.aa_comprobar((SELECT count(*) = 1 FROM pg_catalog.pg_trigger
 WHERE tgrelid = 'public.aa_prueba_datos'::regclass AND NOT tgisinternal),
 'Generacion repetida: exactamente un trigger');

SET SESSION AUTHORIZATION aa_pruebas_operador;
INSERT INTO public.aa_prueba_datos VALUES (1,100,'original','privado');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.aa_comprobar((SELECT count(*) = 2 FROM public.bitacora),
 'INSERT: solo las dos columnas seleccionadas');
SELECT pg_temp.aa_comprobar(
 EXISTS (SELECT 1 FROM public.usuario_auditado WHERE nombre_usuario='aa_pruebas_operador')
 AND EXISTS (SELECT 1 FROM public.estacion_trabajo e
   WHERE e.nombre_estacion=CASE WHEN inet_client_addr() IS NULL
     THEN 'SIN_IP_DISPONIBLE' ELSE 'IP:' || host(inet_client_addr()) END
   AND e.direccion_ip IS NOT DISTINCT FROM host(inet_client_addr())),
 'Los guardias permiten el alta automatica de usuario y estacion');
SELECT pg_temp.aa_comprobar(EXISTS (SELECT 1 FROM public.bitacora b
 JOIN public.v_configuracion_actual c USING(id_configuracion)
 JOIN public.usuario_auditado u USING(id_usuario)
 JOIN public.estacion_trabajo e USING(id_estacion)
 WHERE c.nombre_columna = 'valor' AND c.tipo_evento = 'INSERT'
 AND b.valor_anterior IS NULL AND b.valor_nuevo = '100.00'
 AND u.nombre_usuario = 'aa_pruebas_operador'
 AND b.fecha_hora IS NOT NULL AND b.id_registro::jsonb = '{"id":1}'::jsonb
 AND e.direccion_ip IS NOT DISTINCT FROM host(inet_client_addr())),
 'Contexto real: usuario cliente, fecha, IP disponible o NULL y PK');

UPDATE public.aa_prueba_datos SET no_auditada = 'otro', valor = 100.0 WHERE id=1;
SELECT pg_temp.aa_comprobar((SELECT count(*) = 2 FROM public.bitacora),
 'Columna no seleccionada y numeric sin cambio no producen historial');
UPDATE public.aa_prueba_datos SET valor=125 WHERE id=1;
SELECT pg_temp.aa_comprobar(EXISTS (SELECT 1 FROM public.bitacora b
 JOIN public.v_configuracion_actual c USING(id_configuracion)
 WHERE c.tipo_evento='UPDATE' AND c.nombre_columna='valor'
 AND b.valor_anterior='100.00' AND b.valor_nuevo='125.00'), 'UPDATE: anterior y nuevo');

UPDATE public.aa_prueba_datos SET nota=NULL WHERE id=1;
UPDATE public.aa_prueba_datos SET nota=NULL WHERE id=1;
UPDATE public.aa_prueba_datos SET nota='null' WHERE id=1;
SELECT pg_temp.aa_comprobar((SELECT count(*)=2 FROM public.bitacora b
 JOIN public.v_configuracion_actual c USING(id_configuracion)
 WHERE c.tipo_evento='UPDATE' AND c.nombre_columna='nota'), 'NULL: solo cambios reales');
SELECT pg_temp.aa_comprobar(EXISTS (SELECT 1 FROM public.bitacora b
 JOIN public.v_configuracion_actual c USING(id_configuracion)
 WHERE c.tipo_evento='UPDATE' AND c.nombre_columna='nota'
 AND b.valor_anterior IS NULL AND b.valor_nuevo='null'), 'NULL SQL distinto del texto null');

SELECT public.fn_cambiar_estado_evento('aa_prueba_datos','valor','UPDATE',false);
UPDATE public.aa_prueba_datos SET valor=130 WHERE id=1;
SELECT pg_temp.aa_comprobar((SELECT count(*)=5 FROM public.bitacora),
 'Desactivar columna/evento tiene efecto inmediato');
SELECT public.fn_cambiar_estado_evento('aa_prueba_datos','nota','UPDATE',false);
SELECT * FROM public.fn_autoaudit_regenerar('aa_prueba_datos');
SELECT pg_temp.aa_comprobar((SELECT (tgtype::integer & 16)=0 FROM pg_catalog.pg_trigger
 WHERE tgrelid='public.aa_prueba_datos'::regclass AND tgname='aa_auditar_fila'),
 'Regeneracion retira UPDATE del trigger si no quedan columnas activas');
UPDATE public.aa_prueba_datos SET nota='sin auditoria' WHERE id=1;
SELECT pg_temp.aa_comprobar((SELECT count(*)=5 FROM public.bitacora), 'Operacion UPDATE desactivada');
SELECT public.fn_cambiar_estado_evento('aa_prueba_datos','valor','UPDATE',true);
SELECT * FROM public.fn_autoaudit_regenerar('aa_prueba_datos');
UPDATE public.aa_prueba_datos SET valor=140 WHERE id=1;
DELETE FROM public.aa_prueba_datos WHERE id=1;
SELECT pg_temp.aa_comprobar((SELECT count(*)=8 FROM public.bitacora), 'Reactivacion y DELETE');
SELECT pg_temp.aa_comprobar((SELECT count(*)=2 FROM public.bitacora b
 JOIN public.v_configuracion_actual c USING(id_configuracion)
 WHERE c.tipo_evento='DELETE' AND b.valor_nuevo IS NULL
 AND b.valor_anterior IS NOT NULL), 'DELETE conserva valores anteriores');
SELECT public.fn_deshabilitar_tabla('aa_prueba_datos');
SELECT * FROM public.fn_autoaudit_regenerar('aa_prueba_datos');
INSERT INTO public.aa_prueba_datos VALUES (2,200,'inactivo','x');
SELECT pg_temp.aa_comprobar((SELECT count(*)=8 FROM public.bitacora)
 AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger
 WHERE tgrelid='public.aa_prueba_datos'::regclass AND tgname='aa_auditar_fila'),
 'Deshabilitar tabla retira trigger y conserva todo el historial');

-- Se otorgan permisos directos intencionadamente: el guardia debe impedir
-- escribir aun con un GRANT anterior. Todo el GRANT se revierte al terminar.
GRANT INSERT,UPDATE,DELETE,TRUNCATE,SELECT ON public.bitacora TO aa_pruebas_operador;
SET SESSION AUTHORIZATION aa_pruebas_operador;
DO $$
BEGIN
  BEGIN
    INSERT INTO public.bitacora(id_configuracion,id_usuario,id_estacion) VALUES(1,1,1);
    RAISE EXCEPTION 'FALLO: INSERT directo permitido';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK: INSERT directo bloqueado'; END;
  BEGIN
    UPDATE public.bitacora SET valor_nuevo='falso';
    RAISE EXCEPTION 'FALLO: UPDATE directo permitido';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK: UPDATE directo bloqueado'; END;
  BEGIN
    DELETE FROM public.bitacora;
    RAISE EXCEPTION 'FALLO: DELETE directo permitido';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK: DELETE directo bloqueado'; END;
  BEGIN
    TRUNCATE public.bitacora;
    RAISE EXCEPTION 'FALLO: TRUNCATE permitido';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK: TRUNCATE bloqueado'; END;
  BEGIN
    PERFORM public.fn_autoaudit_regenerar();
    RAISE EXCEPTION 'FALLO: generador accesible sin autorizacion';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK: generador restringido'; END;
  BEGIN
    PERFORM public.fn_configurar_auditoria('aa_prueba_datos');
    RAISE EXCEPTION 'FALLO: configuracion accesible sin autorizacion';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK: configuracion anterior sigue restringida'; END;
END $$;
RESET SESSION AUTHORIZATION;

-- Nombre de tabla y columna con comillas y punto y coma: son identificadores.
CREATE TABLE public."aa prueba; tabla" (id integer PRIMARY KEY, "valor raro" text);
SELECT public.fn_configurar_auditoria('aa prueba; tabla',ARRAY['valor raro']);
SELECT * FROM public.fn_autoaudit_regenerar('aa prueba; tabla');
INSERT INTO public."aa prueba; tabla" VALUES(1,'seguro');
SELECT pg_temp.aa_comprobar(EXISTS (SELECT 1 FROM public.bitacora b
 JOIN public.v_configuracion_actual c USING(id_configuracion)
 WHERE c.nombre_tabla='aa prueba; tabla' AND b.valor_nuevo='seguro'), 'SQL dinamico con identificadores especiales');

CREATE TABLE public.aa_prueba_compuesta(a integer,b text,valor text,PRIMARY KEY(a,b));
SELECT public.fn_configurar_auditoria('aa_prueba_compuesta',ARRAY['valor']);
SELECT * FROM public.fn_autoaudit_regenerar('aa_prueba_compuesta');
INSERT INTO public.aa_prueba_compuesta VALUES(1,'A','v1');
UPDATE public.aa_prueba_compuesta SET a=2,valor='v2';
SELECT pg_temp.aa_comprobar(EXISTS (SELECT 1 FROM public.bitacora b
 JOIN public.v_configuracion_actual c USING(id_configuracion)
 WHERE c.nombre_tabla='aa_prueba_compuesta' AND c.tipo_evento='UPDATE'
 AND b.id_registro::jsonb='{"anterior":{"a":1,"b":"A"},"nuevo":{"a":2,"b":"A"}}'::jsonb),
 'PK compuesta y cambio de PK');

CREATE TABLE public.aa_prueba_json(id integer PRIMARY KEY, valor json);
SELECT public.fn_configurar_auditoria('aa_prueba_json',ARRAY['valor']);
SELECT * FROM public.fn_autoaudit_regenerar('aa_prueba_json');
INSERT INTO public.aa_prueba_json VALUES(1,NULL);
UPDATE public.aa_prueba_json SET valor='null'::json;
SELECT pg_temp.aa_comprobar(EXISTS (SELECT 1 FROM public.bitacora b
 JOIN public.v_configuracion_actual c USING(id_configuracion)
 WHERE c.nombre_tabla='aa_prueba_json' AND c.tipo_evento='UPDATE'
 AND b.valor_anterior IS NULL AND b.valor_nuevo='null'), 'Tipo json: SQL NULL distinto de JSON null');

CREATE TABLE public.aa_prueba_sin_pk(valor text);
SELECT public.fn_configurar_auditoria('aa_prueba_sin_pk');
SELECT * FROM public.fn_autoaudit_regenerar('aa_prueba_sin_pk');
INSERT INTO public.aa_prueba_sin_pk VALUES('sin clave');
SELECT pg_temp.aa_comprobar(EXISTS (SELECT 1 FROM public.bitacora b
 JOIN public.v_configuracion_actual c USING(id_configuracion)
 WHERE c.nombre_tabla='aa_prueba_sin_pk' AND b.id_registro IS NULL), 'Sin PK: no se inventa identificador');

-- Clones nativos de particiones: exactamente un registro por columna/fila.
CREATE TABLE public.aa_prueba_particion(id integer PRIMARY KEY,valor text) PARTITION BY RANGE(id);
CREATE TABLE public.aa_prueba_parte PARTITION OF public.aa_prueba_particion FOR VALUES FROM(0) TO(100);
SELECT pg_temp.aa_comprobar(EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
 WHERE p.oid='pg_catalog.pg_partition_ancestors(regclass)'::regprocedure
 AND p.proretset AND p.prorettype='regclass'::regtype),
 'pg_partition_ancestors devuelve SETOF regclass en el servidor');
SELECT pg_temp.aa_comprobar(EXISTS (
 SELECT 1 FROM pg_catalog.pg_partition_ancestors('public.aa_prueba_parte'::regclass)
   AS a(ancestro)
 WHERE a.ancestro::oid='public.aa_prueba_particion'::regclass::oid),
 'Regresion: ancestro de particion con alias de columna explicito');
SELECT public.fn_configurar_auditoria('aa_prueba_particion',ARRAY['valor']);
SELECT * FROM public.fn_autoaudit_regenerar('aa_prueba_particion');
GRANT INSERT,UPDATE,DELETE,SELECT ON public.aa_prueba_particion,public.aa_prueba_parte
 TO aa_pruebas_operador;
SET SESSION AUTHORIZATION aa_pruebas_operador;
INSERT INTO public.aa_prueba_particion VALUES(1,'particion');
INSERT INTO public.aa_prueba_parte VALUES(2,'insercion directa en hoja');
UPDATE public.aa_prueba_particion SET valor='particion actualizada' WHERE id=1;
DELETE FROM public.aa_prueba_parte WHERE id=2;
RESET SESSION AUTHORIZATION;
SELECT pg_temp.aa_comprobar((SELECT count(*)=4 FROM public.bitacora b
 JOIN public.v_configuracion_actual c USING(id_configuracion)
 JOIN public.usuario_auditado u USING(id_usuario)
 WHERE c.nombre_tabla='aa_prueba_particion' AND u.nombre_usuario='aa_pruebas_operador'),
 'Particiones: cuatro cambios automaticos, sin duplicados, con operador normal');
SELECT pg_temp.aa_comprobar((SELECT count(*)=1 FROM public.bitacora b
 JOIN public.v_configuracion_actual c USING(id_configuracion)
 WHERE c.nombre_tabla='aa_prueba_particion' AND c.tipo_evento='UPDATE'
 AND b.valor_anterior='particion' AND b.valor_nuevo='particion actualizada')
 AND (SELECT count(*)=1 FROM public.bitacora b
 JOIN public.v_configuracion_actual c USING(id_configuracion)
 WHERE c.nombre_tabla='aa_prueba_particion' AND c.tipo_evento='DELETE'
 AND b.valor_anterior='insercion directa en hoja' AND b.valor_nuevo IS NULL),
 'Particiones: UPDATE y DELETE conservan los valores correctos');

-- Trigger ajeno: conservarlo al regenerar y retirar los nuestros.
CREATE FUNCTION public.aa_prueba_trigger_ajeno() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RETURN NEW; END $$;
CREATE TRIGGER aa_ajeno AFTER INSERT ON public.aa_prueba_datos
 FOR EACH ROW EXECUTE FUNCTION public.aa_prueba_trigger_ajeno();
SELECT public.fn_configurar_auditoria('aa_prueba_datos',ARRAY['valor']);
SELECT * FROM public.fn_autoaudit_regenerar('aa_prueba_datos');
SELECT public.fn_autoaudit_retirar('aa_prueba_datos');
SELECT public.fn_autoaudit_retirar('aa_prueba_datos');
SELECT pg_temp.aa_comprobar(EXISTS (SELECT 1 FROM pg_catalog.pg_trigger
 WHERE tgrelid='public.aa_prueba_datos'::regclass AND tgname='aa_ajeno'),
 'Retiro idempotente conserva triggers ajenos');

CREATE TABLE public.aa_prueba_colision(id integer PRIMARY KEY,valor text);
CREATE TRIGGER aa_auditar_fila AFTER INSERT ON public.aa_prueba_colision
 FOR EACH ROW EXECUTE FUNCTION public.aa_prueba_trigger_ajeno();
SELECT public.fn_configurar_auditoria('aa_prueba_colision',ARRAY['valor']);
DO $$
BEGIN
  BEGIN
    PERFORM public.fn_autoaudit_regenerar('aa_prueba_colision');
    RAISE EXCEPTION 'FALLO: se sobrescribio un trigger ajeno';
  EXCEPTION WHEN duplicate_object THEN RAISE NOTICE 'OK: colision ajena detectada'; END;
END $$;
SELECT public.fn_deshabilitar_tabla('aa_prueba_colision');

CREATE TABLE public.aa_prueba_obsoleta(id integer PRIMARY KEY,valor text);
SELECT public.fn_configurar_auditoria('aa_prueba_obsoleta',ARRAY['valor']);
SELECT * FROM public.fn_autoaudit_regenerar('aa_prueba_obsoleta');
ALTER TABLE public.aa_prueba_obsoleta DROP COLUMN valor;
DO $$
BEGIN
  BEGIN
    PERFORM public.fn_autoaudit_regenerar();
    RAISE EXCEPTION 'FALLO: columna eliminada no detectada';
  EXCEPTION WHEN invalid_parameter_value THEN RAISE NOTICE 'OK: configuracion obsoleta rechazada'; END;
END $$;
SELECT pg_temp.aa_comprobar(EXISTS (SELECT 1 FROM pg_catalog.pg_trigger
 WHERE tgrelid='public.aa_prueba_obsoleta'::regclass AND tgname='aa_auditar_fila'),
 'Generacion fallida conserva triggers anteriores');
SELECT public.fn_deshabilitar_tabla('aa_prueba_obsoleta');
SELECT * FROM public.fn_autoaudit_regenerar('aa_prueba_obsoleta');
DROP TABLE public.aa_prueba_obsoleta;
SELECT * FROM public.fn_autoaudit_regenerar('aa_prueba_obsoleta');

-- Error de auditoria: la operacion de negocio no puede quedar sin historial.
CREATE TABLE public.aa_prueba_error(id integer PRIMARY KEY,valor text);
SELECT public.fn_configurar_auditoria('aa_prueba_error',ARRAY['valor']);
SELECT * FROM public.fn_autoaudit_regenerar('aa_prueba_error');
CREATE FUNCTION public.aa_prueba_fallar() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'fallo controlado' USING ERRCODE='23514'; END $$;
CREATE TRIGGER aa_fallo_controlado BEFORE INSERT ON public.bitacora
 FOR EACH ROW EXECUTE FUNCTION public.aa_prueba_fallar();
DO $$
BEGIN
  BEGIN
    INSERT INTO public.aa_prueba_error VALUES(1,'debe revertirse');
    RAISE EXCEPTION 'FALLO: se ignoro el error de auditoria';
  EXCEPTION WHEN check_violation THEN RAISE NOTICE 'OK: error propagado'; END;
END $$;
DROP TRIGGER aa_fallo_controlado ON public.bitacora;
SELECT pg_temp.aa_comprobar(NOT EXISTS (SELECT 1 FROM public.aa_prueba_error),
 'Error de bitacora revierte INSERT origen');

-- Mide lotes crecientes; no afirma un umbral universal ni sustituye medir en Ubuntu.
CREATE TABLE public.aa_prueba_rendimiento(id integer PRIMARY KEY,valor integer);
CREATE TEMP TABLE aa_mediciones(filas integer,sin_auditoria_ms numeric,con_auditoria_ms numeric);
SELECT public.fn_configurar_auditoria('aa_prueba_rendimiento',ARRAY['valor'],ARRAY['UPDATE']);
DO $$
DECLARE n integer; inicio timestamptz; base numeric; auditado numeric; antes bigint;
BEGIN
  FOREACH n IN ARRAY ARRAY[100,1000,5000] LOOP
    PERFORM public.fn_autoaudit_retirar('aa_prueba_rendimiento');
    TRUNCATE public.aa_prueba_rendimiento;
    INSERT INTO public.aa_prueba_rendimiento SELECT x,0 FROM generate_series(1,n) x;
    inicio := clock_timestamp();
    UPDATE public.aa_prueba_rendimiento SET valor=1;
    base := extract(epoch FROM clock_timestamp()-inicio)*1000;
    PERFORM public.fn_autoaudit_regenerar('aa_prueba_rendimiento');
    SELECT count(*) INTO antes FROM public.bitacora;
    inicio := clock_timestamp();
    UPDATE public.aa_prueba_rendimiento SET valor=2;
    auditado := extract(epoch FROM clock_timestamp()-inicio)*1000;
    PERFORM pg_temp.aa_comprobar((SELECT count(*)=antes+n FROM public.bitacora),
      'Rendimiento: cantidad correcta para ' || n || ' filas');
    INSERT INTO aa_mediciones VALUES(n,base,auditado);
  END LOOP;
END $$;
TABLE aa_mediciones;

-- Ensayo de ROLLBACK de una operacion valida.
SAVEPOINT aa_operacion;
INSERT INTO public.aa_prueba_error VALUES(2,'transaccion cancelada');
ROLLBACK TO SAVEPOINT aa_operacion;
SELECT pg_temp.aa_comprobar(NOT EXISTS (SELECT 1 FROM public.bitacora b
 JOIN public.v_configuracion_actual c USING(id_configuracion)
 WHERE c.nombre_tabla='aa_prueba_error'), 'ROLLBACK revierte tambien la bitacora');

SELECT 'TODAS LAS COMPROBACIONES TERMINARON; se revierten los datos de prueba' AS resultado;
ROLLBACK;
\timing off
