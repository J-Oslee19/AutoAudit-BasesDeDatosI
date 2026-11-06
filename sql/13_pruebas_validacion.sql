-- =====================================================================
-- AutoAudit - 13_pruebas_validacion.sql
-- Parte 4: Pruebas de validación del sistema completo.
--
--   A. INSERT  -> registro correcto en bitácora
--   B. UPDATE  -> captura de valor anterior y nuevo
--   C. DELETE  -> preservación de datos en bitácora
--   D. Consultas por usuario, por columna, por registro y línea de tiempo
--   E. Reportes
--   F. Seguridad de consulta (lectura sí, escritura no)
--   G. Rendimiento con volumen creciente de registros auditados
--
-- SOLO en una BD desechable cuyo nombre empiece por autoaudit_pruebas,
-- con 01, 03, 04, 05, 07, 08, 10 y 11 instalados (sin 06 ni datos previos):
--   psql -X -v ON_ERROR_STOP=1 -d autoaudit_pruebas -f sql/13_pruebas_validacion.sql
-- Todo ocurre en una transacción que termina en ROLLBACK.
-- Cada comprobación imprime OK; si una falla, psql se detiene con error.
-- =====================================================================
\set ON_ERROR_STOP on
\pset footer off
BEGIN;
SET LOCAL search_path = public, pg_catalog;
SET LOCAL client_min_messages = notice;

DO $$
BEGIN
  IF current_setting('server_version_num')::integer / 10000 <> 18 THEN
    RAISE EXCEPTION 'Ejecute estas pruebas en PostgreSQL 18';
  END IF;
  IF current_database() NOT LIKE 'autoaudit_pruebas%' THEN
    RAISE EXCEPTION 'Use exclusivamente una BD desechable autoaudit_pruebas';
  END IF;
  IF NOT (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = session_user) THEN
    RAISE EXCEPTION 'Las pruebas requieren postgres para simular usuarios';
  END IF;
  IF pg_catalog.to_regprocedure('public.fn_reporte_por_usuario(timestamp,timestamp)') IS NULL THEN
    RAISE EXCEPTION 'Instale 10_consultas_historicas.sql y 11_reportes.sql';
  END IF;
  IF EXISTS (SELECT 1 FROM public.bitacora) OR EXISTS (SELECT 1 FROM public.configuracion_auditoria) THEN
    RAISE EXCEPTION 'Use una instalación de prueba sin configuraciones ni historial';
  END IF;
END $$;

CREATE FUNCTION pg_temp.ok(p_condicion boolean, p_caso text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_condicion IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FALLO: %', p_caso;
  END IF;
  RAISE NOTICE 'OK: %', p_caso;
END $$;

-- ---------------------------------------------------------------------
-- Escenario: tabla de negocio, un administrador, dos operadores
-- (usuarios de la aplicación) y un auditor de solo lectura.
-- ---------------------------------------------------------------------
CREATE TABLE public.producto (
  id_producto integer PRIMARY KEY,
  nombre      varchar(80) NOT NULL,
  precio      numeric(10,2),
  existencia  integer,
  descripcion text            -- NO se audita
);
CREATE ROLE aa_val_admin    NOLOGIN;
CREATE ROLE aa_val_ana      NOLOGIN;   -- operador 1
CREATE ROLE aa_val_luis     NOLOGIN;   -- operador 2
CREATE ROLE aa_val_auditor  NOLOGIN;   -- solo consulta
CREATE ROLE aa_val_intruso  NOLOGIN;   -- sin permisos de auditoría
GRANT autoaudit_admin    TO aa_val_admin;
GRANT autoaudit_consulta TO aa_val_auditor;
GRANT USAGE ON SCHEMA public TO aa_val_ana, aa_val_luis, aa_val_auditor, aa_val_intruso;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.producto TO aa_val_ana, aa_val_luis;

\echo '--- Configuración: precio y existencia en INSERT/UPDATE/DELETE; nombre solo en INSERT/DELETE ---'
SET SESSION AUTHORIZATION aa_val_admin;
SELECT public.fn_configurar_auditoria('producto', ARRAY['precio','existencia']);
SELECT public.fn_configurar_auditoria('producto', ARRAY['nombre'], ARRAY['INSERT','DELETE']);
SELECT * FROM public.fn_autoaudit_regenerar('producto');
RESET SESSION AUTHORIZATION;

SELECT pg_temp.ok(
  (SELECT columnas_activas = 3 AND trigger_instalado AND tabla_habilitada
     FROM public.fn_reporte_estado_auditoria() WHERE nombre_tabla = 'producto'),
  'Estado: 3 columnas activas, tabla habilitada y trigger instalado');

-- =====================================================================
-- A. INSERT
-- =====================================================================
\echo '--- A. INSERT ---'
SET SESSION AUTHORIZATION aa_val_ana;
INSERT INTO public.producto VALUES (1, 'Teclado', 150.00, 20, 'texto libre');
INSERT INTO public.producto VALUES (2, 'Mouse',    75.50, 40, NULL);
RESET SESSION AUTHORIZATION;

SELECT pg_temp.ok((SELECT count(*) = 6 FROM public.bitacora),
  'A1. Dos INSERT x 3 columnas configuradas = 6 registros (descripcion no se audita)');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.v_bitacora_detalle WHERE nombre_columna = 'descripcion'),
  'A2. La columna no seleccionada no aparece en bitácora');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.v_bitacora_detalle
   WHERE nombre_columna = 'precio' AND tipo_evento = 'INSERT'
     AND valor_anterior IS NULL AND valor_nuevo = '150.00'
     AND id_registro::jsonb = '{"id_producto": 1}'
     AND nombre_usuario = 'aa_val_ana' AND fecha_hora IS NOT NULL
     AND nombre_estacion IS NOT NULL),
  'A3. INSERT: anterior NULL, nuevo correcto, PK, usuario, fecha y estación');

-- =====================================================================
-- B. UPDATE
-- =====================================================================
\echo '--- B. UPDATE ---'
SET SESSION AUTHORIZATION aa_val_luis;
UPDATE public.producto SET precio = 165.00 WHERE id_producto = 1;
UPDATE public.producto SET existencia = existencia - 5, descripcion = 'cambio' WHERE id_producto = 1;
UPDATE public.producto SET precio = 165.0 WHERE id_producto = 1;      -- mismo valor numérico
UPDATE public.producto SET nombre = 'Teclado mecánico' WHERE id_producto = 1;  -- nombre no audita UPDATE
RESET SESSION AUTHORIZATION;

SELECT pg_temp.ok((SELECT count(*) = 2 FROM public.v_bitacora_detalle WHERE tipo_evento = 'UPDATE'),
  'B1. Solo 2 UPDATE reales registrados (sin cambio y columna sin UPDATE se ignoran)');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.v_bitacora_detalle
   WHERE nombre_columna = 'precio' AND tipo_evento = 'UPDATE'
     AND valor_anterior = '150.00' AND valor_nuevo = '165.00' AND nombre_usuario = 'aa_val_luis'),
  'B2. UPDATE precio: anterior 150.00 y nuevo 165.00 por aa_val_luis');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.v_bitacora_detalle
   WHERE nombre_columna = 'existencia' AND tipo_evento = 'UPDATE'
     AND valor_anterior = '20' AND valor_nuevo = '15'),
  'B3. UPDATE existencia: 20 -> 15');

-- =====================================================================
-- C. DELETE
-- =====================================================================
\echo '--- C. DELETE ---'
SET SESSION AUTHORIZATION aa_val_ana;
DELETE FROM public.producto WHERE id_producto = 2;
RESET SESSION AUTHORIZATION;

SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.producto WHERE id_producto = 2),
  'C1. El registro fuente fue eliminado');
SELECT pg_temp.ok((SELECT count(*) = 3 FROM public.v_bitacora_detalle
   WHERE tipo_evento = 'DELETE' AND id_registro::jsonb = '{"id_producto": 2}'
     AND valor_nuevo IS NULL AND valor_anterior IS NOT NULL),
  'C2. DELETE guarda los 3 valores anteriores y nuevo NULL');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.v_bitacora_detalle
   WHERE tipo_evento = 'DELETE' AND nombre_columna = 'nombre' AND valor_anterior = 'Mouse'),
  'C3. Los datos originales se preservan aunque la fila ya no exista');

-- =====================================================================
-- D. Consultas históricas
-- =====================================================================
\echo '--- D. Consultas ---'
\echo 'Historial del usuario aa_val_luis:'
SELECT id_bitacora, nombre_tabla, nombre_columna, tipo_evento, valor_anterior, valor_nuevo, id_registro
  FROM public.fn_historial_usuario('aa_val_luis');
SELECT pg_temp.ok((SELECT count(*) = 2 FROM public.fn_historial_usuario('aa_val_luis')),
  'D1. Por usuario: aa_val_luis tiene exactamente sus 2 cambios');
SELECT pg_temp.ok((SELECT count(*) = 9 FROM public.fn_historial_usuario('aa_val_ana')),
  'D2. Por usuario: aa_val_ana tiene sus 9 cambios (6 INSERT + 3 DELETE)');
SELECT pg_temp.ok((SELECT bool_and(nombre_usuario = 'aa_val_ana') FROM public.fn_historial_usuario('aa_val_ana')),
  'D3. Por usuario: no mezcla cambios de otros usuarios');
SELECT pg_temp.ok((SELECT count(*) = 0 FROM public.fn_historial_usuario('nadie')),
  'D4. Usuario sin cambios devuelve vacío (con aviso), no error');
SELECT pg_temp.ok((SELECT count(*) = 0 FROM public.fn_historial_usuario('aa_val_ana', p_tabla => 'otra')),
  'D5. Filtro por tabla en historial de usuario');

\echo 'Historial de la columna producto.precio:'
SELECT id_bitacora, tipo_evento, valor_anterior, valor_nuevo, nombre_usuario, id_registro
  FROM public.fn_historial_columna('producto','precio');
SELECT pg_temp.ok((SELECT count(*) = 4 FROM public.fn_historial_columna('producto','precio')),
  'D6. Por columna: precio tiene 2 INSERT + 1 UPDATE + 1 DELETE');
SELECT pg_temp.ok((SELECT count(*) = 1 FROM public.fn_historial_columna('producto','precio',NULL,NULL,'update')),
  'D7. Por columna con filtro de evento (sin importar mayúsculas)');
SELECT pg_temp.ok((SELECT array_agg(id_bitacora ORDER BY id_bitacora) = array_agg(id_bitacora)
                     FROM public.fn_historial_columna('producto','precio')),
  'D8. Resultado en orden cronológico');
SELECT pg_temp.ok((SELECT count(*) = 5 FROM public.fn_historial_registro('producto','{"id_producto": 1}')),
  'D9. Por registro: producto 1 tiene 3 INSERT + 2 UPDATE');
SELECT pg_temp.ok((SELECT count(*) = 3 FROM public.fn_linea_tiempo(p_limite => 3))
              AND (SELECT bool_and(tipo_evento = 'DELETE') FROM public.fn_linea_tiempo(p_limite => 3)),
  'D10. Línea de tiempo: los 3 últimos cambios son el DELETE');
SELECT pg_temp.ok((SELECT count(*) = 2 FROM public.fn_linea_tiempo(p_tabla => 'producto', p_evento => 'update'))
              AND (SELECT count(*) = 2 FROM public.fn_linea_tiempo(p_usuario => 'aa_val_luis'))
              AND (SELECT count(*) = 0 FROM public.fn_linea_tiempo(p_usuario => 'nadie'))
              AND (SELECT count(*) = 11 FROM public.fn_linea_tiempo()),
  'D10b. Línea de tiempo con filtros de tabla, evento y usuario');
SELECT pg_temp.ok((SELECT count(*) = 0 FROM public.fn_linea_tiempo(now()::timestamp + interval '1 day', NULL)),
  'D11. Rango de fechas futuro devuelve vacío');

-- Errores controlados de parámetros
DO $$
BEGIN
  BEGIN PERFORM * FROM public.fn_historial_columna('producto','no_existe');
        RAISE EXCEPTION 'FALLO: columna no configurada aceptada';
  EXCEPTION WHEN no_data_found THEN RAISE NOTICE 'OK: D12. Columna nunca configurada -> error claro'; END;
  BEGIN PERFORM * FROM public.fn_linea_tiempo('2026-12-01','2026-11-01');
        RAISE EXCEPTION 'FALLO: rango invertido aceptado';
  EXCEPTION WHEN invalid_parameter_value THEN RAISE NOTICE 'OK: D13. Rango invertido -> error'; END;
  BEGIN PERFORM * FROM public.fn_historial_columna('producto','precio',NULL,NULL,'TRUNCATE');
        RAISE EXCEPTION 'FALLO: evento inválido aceptado';
  EXCEPTION WHEN invalid_parameter_value THEN RAISE NOTICE 'OK: D14. Evento inválido -> error'; END;
  BEGIN PERFORM * FROM public.fn_historial_usuario(NULL);
        RAISE EXCEPTION 'FALLO: usuario NULL aceptado';
  EXCEPTION WHEN null_value_not_allowed THEN RAISE NOTICE 'OK: D15. Usuario vacío -> error'; END;
END $$;

-- Historial se conserva tras desactivar la auditoría de la tabla
SET SESSION AUTHORIZATION aa_val_admin;
SELECT public.fn_deshabilitar_tabla('producto');
SELECT * FROM public.fn_autoaudit_regenerar('producto');
RESET SESSION AUTHORIZATION;
SELECT pg_temp.ok((SELECT count(*) = 4 FROM public.fn_historial_columna('producto','precio'))
              AND (SELECT NOT bool_or(configuracion_activa) FROM public.fn_historial_columna('producto','precio')),
  'D16. Tabla deshabilitada: el historial sigue consultable');
SET SESSION AUTHORIZATION aa_val_admin;
SELECT public.fn_configurar_auditoria('producto', ARRAY['precio','existencia']);
SELECT public.fn_configurar_auditoria('producto', ARRAY['nombre'], ARRAY['INSERT','DELETE']);
SELECT * FROM public.fn_autoaudit_regenerar('producto');
RESET SESSION AUTHORIZATION;

-- =====================================================================
-- E. Reportes
-- =====================================================================
\echo '--- E. Reportes ---'
SELECT * FROM public.fn_reporte_por_usuario();
SELECT * FROM public.fn_reporte_por_columna();
SELECT * FROM public.fn_reporte_estado_auditoria();
SELECT pg_temp.ok((SELECT total_cambios = 9 AND inserciones = 6 AND eliminaciones = 3
                     FROM public.fn_reporte_por_usuario() WHERE nombre_usuario = 'aa_val_ana'),
  'E1. Resumen por usuario cuadra con el historial');
SELECT pg_temp.ok((SELECT sum(total_cambios) = (SELECT count(*) FROM public.bitacora)
                     FROM public.fn_reporte_por_columna()),
  'E2. Resumen por columna suma el total de la bitácora');
SELECT pg_temp.ok((SELECT ultimo_usuario = 'aa_val_ana' FROM public.fn_reporte_por_columna()
                    WHERE nombre_columna = 'precio'),
  'E3. Último usuario que cambió precio (el DELETE de ana)');
SELECT pg_temp.ok((SELECT sum(total_cambios) = 11 FROM public.fn_reporte_actividad_diaria()),
  'E4. Actividad diaria suma los 11 cambios');

-- =====================================================================
-- F. Seguridad de consulta
-- =====================================================================
\echo '--- F. Seguridad ---'
SET SESSION AUTHORIZATION aa_val_auditor;
SELECT pg_temp.ok((SELECT count(*) = 2 FROM public.fn_historial_usuario('aa_val_luis')),
  'F1. El auditor (autoaudit_consulta) puede consultar el historial');
DO $$
BEGIN
  BEGIN INSERT INTO public.bitacora(id_configuracion,id_usuario,id_estacion) VALUES (1,1,1);
        RAISE EXCEPTION 'FALLO: el auditor pudo escribir';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK: F2. El auditor no puede escribir en bitácora'; END;
  BEGIN PERFORM public.fn_configurar_auditoria('producto');
        RAISE EXCEPTION 'FALLO: el auditor pudo configurar';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK: F3. El auditor no puede configurar auditoría'; END;
END $$;
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION aa_val_intruso;
DO $$
BEGIN
  BEGIN PERFORM * FROM public.fn_historial_usuario('aa_val_ana');
        RAISE EXCEPTION 'FALLO: usuario sin rol consultó el historial';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK: F4. Usuario sin rol no puede consultar'; END;
  BEGIN PERFORM * FROM public.v_bitacora_detalle;
        RAISE EXCEPTION 'FALLO: usuario sin rol leyó la vista';
  EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK: F5. Usuario sin rol no puede leer la vista'; END;
END $$;
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION aa_val_admin;
SELECT pg_temp.ok((SELECT count(*) >= 1 FROM public.fn_reporte_por_usuario()),
  'F6. El administrador también puede consultar (hereda autoaudit_consulta)');
RESET SESSION AUTHORIZATION;

-- =====================================================================
-- G. Rendimiento con volumen creciente
--    G1: costo de INSERT, UPDATE y DELETE con y sin auditoría.
--    G2: tiempo de las consultas a medida que crece la bitácora.
--    Una sola pasada por tamaño: son valores de referencia del equipo
--    donde se ejecuta, no un umbral universal.
-- =====================================================================
\echo '--- G. Rendimiento (puede tardar unos segundos) ---'
CREATE TABLE public.aa_val_carga (id integer PRIMARY KEY, monto numeric(12,2), estado text);
SET SESSION AUTHORIZATION aa_val_admin;
SELECT public.fn_configurar_auditoria('aa_val_carga', ARRAY['monto']);
RESET SESSION AUTHORIZATION;
CREATE TEMP TABLE aa_val_dml (
  filas integer, operacion text, sin_auditoria_ms numeric, con_auditoria_ms numeric,
  registros_bitacora bigint);
CREATE TEMP TABLE aa_val_consulta (
  filas_bitacora bigint, consulta text, filas_devueltas bigint, tiempo_ms numeric);

DO $$
DECLARE
  n integer; t0 timestamptz; base numeric; aud numeric; antes bigint; despues bigint;
  op text; tamano bigint; dev bigint;
BEGIN
  FOREACH n IN ARRAY ARRAY[1000, 10000, 50000] LOOP
    FOREACH op IN ARRAY ARRAY['INSERT','UPDATE','DELETE'] LOOP
      -- Sin auditoría
      PERFORM public.fn_autoaudit_retirar('aa_val_carga');
      TRUNCATE public.aa_val_carga;
      IF op <> 'INSERT' THEN
        INSERT INTO public.aa_val_carga SELECT x, x, 'a' FROM generate_series(1,n) x;
      END IF;
      t0 := clock_timestamp();
      IF op = 'INSERT' THEN INSERT INTO public.aa_val_carga SELECT x, x, 'a' FROM generate_series(1,n) x;
      ELSIF op = 'UPDATE' THEN UPDATE public.aa_val_carga SET monto = monto + 1;
      ELSE DELETE FROM public.aa_val_carga; END IF;
      base := extract(epoch FROM clock_timestamp() - t0) * 1000;

      -- Con auditoría
      TRUNCATE public.aa_val_carga;
      IF op <> 'INSERT' THEN
        INSERT INTO public.aa_val_carga SELECT x, x, 'a' FROM generate_series(1,n) x;
      END IF;
      PERFORM public.fn_autoaudit_regenerar('aa_val_carga');
      SELECT count(*) INTO antes FROM public.bitacora;
      t0 := clock_timestamp();
      IF op = 'INSERT' THEN INSERT INTO public.aa_val_carga SELECT x, x, 'a' FROM generate_series(1,n) x;
      ELSIF op = 'UPDATE' THEN UPDATE public.aa_val_carga SET monto = monto + 1;
      ELSE DELETE FROM public.aa_val_carga; END IF;
      aud := extract(epoch FROM clock_timestamp() - t0) * 1000;
      SELECT count(*) INTO despues FROM public.bitacora;
      PERFORM pg_temp.ok(despues - antes = n,
        format('G1. %s de %s filas genera exactamente %s registros', op, n, n));
      INSERT INTO aa_val_dml VALUES (n, op, round(base,1), round(aud,1), despues);
    END LOOP;

    -- Consultas con la bitácora ya crecida
    ANALYZE public.bitacora;
    SELECT count(*) INTO tamano FROM public.bitacora;
    t0 := clock_timestamp();
    SELECT count(*) INTO dev FROM public.fn_historial_usuario('aa_val_luis');
    INSERT INTO aa_val_consulta VALUES (tamano, 'fn_historial_usuario (usuario con pocos cambios)', dev,
      round(extract(epoch FROM clock_timestamp() - t0) * 1000, 2));
    t0 := clock_timestamp();
    SELECT count(*) INTO dev FROM public.fn_historial_columna('producto','precio');
    INSERT INTO aa_val_consulta VALUES (tamano, 'fn_historial_columna (producto.precio)', dev,
      round(extract(epoch FROM clock_timestamp() - t0) * 1000, 2));
    t0 := clock_timestamp();
    SELECT count(*) INTO dev FROM public.fn_linea_tiempo(p_limite => 100);
    INSERT INTO aa_val_consulta VALUES (tamano, 'fn_linea_tiempo (últimos 100)', dev,
      round(extract(epoch FROM clock_timestamp() - t0) * 1000, 2));
    t0 := clock_timestamp();
    SELECT count(*) INTO dev FROM public.fn_reporte_por_usuario();
    INSERT INTO aa_val_consulta VALUES (tamano, 'fn_reporte_por_usuario (resumen completo)', dev,
      round(extract(epoch FROM clock_timestamp() - t0) * 1000, 2));
    PERFORM pg_temp.ok(
      (SELECT count(*) = 2 FROM public.fn_historial_usuario('aa_val_luis')),
      format('G2. Con %s registros en bitácora la consulta por usuario sigue exacta', tamano));
  END LOOP;
END $$;

\echo 'G1. Tiempo de operaciones (ms): sin auditoría vs. con auditoría de 1 columna'
SELECT filas, operacion, sin_auditoria_ms, con_auditoria_ms,
       round(con_auditoria_ms / NULLIF(sin_auditoria_ms,0), 1) AS veces,
       round((con_auditoria_ms - sin_auditoria_ms) / filas, 4) AS ms_extra_por_fila,
       registros_bitacora
  FROM aa_val_dml ORDER BY filas, array_position(ARRAY['INSERT','UPDATE','DELETE'], operacion);
\echo 'G2. Tiempo de consultas (ms) según el tamaño de la bitácora'
SELECT * FROM aa_val_consulta ORDER BY filas_bitacora, consulta;
\echo 'Plan de la consulta por usuario con la bitácora más grande (debe usar índice):'
SELECT id_usuario AS luis_id FROM public.usuario_auditado
 WHERE nombre_usuario = 'aa_val_luis' ORDER BY id_usuario LIMIT 1 \gset
EXPLAIN (COSTS OFF)
SELECT * FROM public.v_bitacora_detalle WHERE id_usuario = :luis_id
 ORDER BY fecha_hora, id_bitacora;

SELECT 'TODAS LAS PRUEBAS DE VALIDACIÓN TERMINARON; se revierten los datos de prueba' AS resultado;
ROLLBACK;
