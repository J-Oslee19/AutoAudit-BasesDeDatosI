-- =====================================================================
-- AutoAudit - 14_ejemplo_uso.sql
-- Ejemplo completo de uso, de principio a fin, que DEJA datos para
-- poder probar las consultas y la exportación de reportes.
--
-- Ejecutar como postgres en una BD de demostración (NO en producción):
--   createdb autoaudit_demo
--   (instalar 01,03,04,05,07,08,10,11 en autoaudit_demo)
--   psql -X -v ON_ERROR_STOP=1 -d autoaudit_demo -f sql/14_ejemplo_uso.sql
--
-- Crea: tabla de negocio "cliente", rol administrador demo_admin,
-- dos usuarios de aplicación (demo_cajero, demo_supervisor) y un
-- auditor de solo lectura (demo_auditor). Los roles son NOLOGIN.
-- =====================================================================
\set ON_ERROR_STOP on
\pset footer off

-- 0. Tabla de negocio y usuarios
CREATE TABLE IF NOT EXISTS public.cliente (
  id_cliente     integer PRIMARY KEY,
  nombre         varchar(100) NOT NULL,
  limite_credito numeric(10,2),
  telefono       varchar(15),
  categoria      varchar(10)
);
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['demo_admin','demo_cajero','demo_supervisor','demo_auditor'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN', r);
    END IF;
  END LOOP;
END $$;
GRANT autoaudit_admin    TO demo_admin;
GRANT autoaudit_consulta TO demo_auditor;
GRANT USAGE ON SCHEMA public TO demo_cajero, demo_supervisor, demo_auditor;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.cliente TO demo_cajero, demo_supervisor;

-- 1. El administrador revisa el diccionario y configura la auditoría
SET SESSION AUTHORIZATION demo_admin;
\echo '1. Tablas disponibles en el diccionario de datos:'
SELECT * FROM public.v_dic_tablas;
\echo '   Columnas de cliente:'
SELECT orden, nombre_columna, tipo_dato, es_pk FROM public.fn_dic_columnas('cliente');

\echo '2. Configurar: limite_credito y categoria en todo; nombre solo al insertar y borrar'
BEGIN;
SELECT public.fn_configurar_auditoria('cliente', ARRAY['limite_credito','categoria']);
SELECT public.fn_configurar_auditoria('cliente', ARRAY['nombre'], ARRAY['INSERT','DELETE']);
SELECT * FROM public.fn_autoaudit_regenerar('cliente');
COMMIT;
RESET SESSION AUTHORIZATION;

-- 3. Operaciones normales de la aplicación (los triggers registran solos)
\echo '3. Operaciones de negocio'
SET SESSION AUTHORIZATION demo_cajero;
INSERT INTO public.cliente VALUES (1,'Ferretería López',  5000,'55551234','B');
INSERT INTO public.cliente VALUES (2,'Abarrotes Marta',   2000,'55559876','C');
INSERT INTO public.cliente VALUES (3,'Distribuidora Sur',10000,'55554321','A');
UPDATE public.cliente SET telefono = '55550000' WHERE id_cliente = 2;   -- no auditada
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION demo_supervisor;
UPDATE public.cliente SET limite_credito = 7500, categoria = 'A' WHERE id_cliente = 1;
UPDATE public.cliente SET limite_credito = 1500 WHERE id_cliente = 2;
DELETE FROM public.cliente WHERE id_cliente = 3;
RESET SESSION AUTHORIZATION;

-- 4. El auditor consulta el historial
SET SESSION AUTHORIZATION demo_auditor;
\echo '4a. ¿Qué cambió el supervisor?'
SELECT fecha_hora, nombre_tabla, nombre_columna, tipo_evento, id_registro, valor_anterior, valor_nuevo
  FROM public.fn_historial_usuario('demo_supervisor');
\echo '4b. ¿Cómo cambió el límite de crédito?'
SELECT fecha_hora, tipo_evento, id_registro, valor_anterior, valor_nuevo, nombre_usuario
  FROM public.fn_historial_columna('cliente','limite_credito');
\echo '4c. Historia completa del cliente 3 (ya eliminado)'
SELECT fecha_hora, nombre_columna, tipo_evento, valor_anterior, valor_nuevo, nombre_usuario
  FROM public.fn_historial_registro('cliente','{"id_cliente": 3}');
\echo '4d. Últimos 5 cambios'
SELECT fecha_hora, nombre_columna, tipo_evento, valor_anterior, valor_nuevo, nombre_usuario
  FROM public.fn_linea_tiempo(p_limite => 5);
\echo '5. Reportes'
SELECT * FROM public.fn_reporte_por_usuario();
SELECT * FROM public.fn_reporte_por_columna();
SELECT * FROM public.fn_reporte_actividad_diaria();
SELECT * FROM public.fn_reporte_estado_auditoria();
RESET SESSION AUTHORIZATION;
