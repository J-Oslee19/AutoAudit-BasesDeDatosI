-- =====================================================================
-- AutoAudit - 06_pruebas_configuracion.sql
-- Ejemplos de uso y casos de prueba del módulo de configuración.
-- Ejecutar como superusuario (postgres) o miembro de autoaudit_admin.
-- =====================================================================
\set ON_ERROR_STOP off

-- Tabla de ejemplo (de negocio) para auditar
DROP TABLE IF EXISTS public.empleado CASCADE;
CREATE TABLE public.empleado (
  id_empleado serial PRIMARY KEY,
  nombre      varchar(100) NOT NULL,
  salario     numeric(10,2),
  puesto      varchar(50)
);

\echo '--- P1: tablas disponibles (no aparecen las del sistema) ---'
SELECT * FROM public.v_dic_tablas;

\echo '--- P2: columnas de empleado (diccionario de datos) ---'
SELECT * FROM public.fn_dic_columnas('empleado');

\echo '--- P3: configurar salario y puesto, solo UPDATE y DELETE (esperado: 4) ---'
SELECT public.fn_configurar_auditoria('empleado', ARRAY['salario','puesto'], ARRAY['UPDATE','DELETE']);
SELECT * FROM public.v_configuracion_actual;

\echo '--- P4: repetir la misma configuración no duplica filas (esperado: 4 filas) ---'
SELECT public.fn_configurar_auditoria('empleado', ARRAY['salario','puesto'], ARRAY['UPDATE','DELETE']);
SELECT count(*) AS filas_config FROM public.configuracion_auditoria;

\echo '--- P5: desactivar UPDATE de salario ---'
SELECT public.fn_cambiar_estado_evento('empleado','salario','UPDATE', false);
SELECT * FROM public.fn_dic_columnas('empleado') WHERE nombre_columna IN ('salario','puesto');

\echo '--- P6: reactivar INSERT de nombre (crea la config si no existía) ---'
SELECT public.fn_cambiar_estado_evento('empleado','nombre','INSERT', true);

\echo '--- N1: tabla inexistente (esperado: ERROR 42P01) ---'
SELECT public.fn_configurar_auditoria('no_existe');

\echo '--- N2: columna inexistente (esperado: ERROR 42703 y NO se guarda nada) ---'
SELECT public.fn_configurar_auditoria('empleado', ARRAY['puesto','fantasma'], ARRAY['INSERT']);
SELECT count(*) AS config_insert_puesto
  FROM public.v_configuracion_actual WHERE nombre_columna='puesto' AND tipo_evento='INSERT';

\echo '--- N3: evento inválido (esperado: ERROR 22023) ---'
SELECT public.fn_configurar_auditoria('empleado', ARRAY['puesto'], ARRAY['TRUNCATE']);

\echo '--- N4: tabla del sistema (esperado: ERROR 42809) ---'
SELECT public.fn_seleccionar_tabla('bitacora');

\echo '--- N5: usuario sin privilegios (esperado: ERROR 42501) ---'
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='usuario_normal') THEN
    CREATE ROLE usuario_normal LOGIN;
  END IF;
END $$;
GRANT EXECUTE ON FUNCTION public.fn_configurar_auditoria(text,text[],text[]) TO usuario_normal;
SET SESSION AUTHORIZATION usuario_normal;
SELECT public.fn_configurar_auditoria('empleado');
RESET SESSION AUTHORIZATION;
REVOKE EXECUTE ON FUNCTION public.fn_configurar_auditoria(text,text[],text[]) FROM usuario_normal;

\echo '--- N6: escritura directa en tablas de configuración (esperado: permission denied) ---'
SET SESSION AUTHORIZATION usuario_normal;
INSERT INTO public.tabla_auditada(nombre_tabla) VALUES ('empleado');
RESET SESSION AUTHORIZATION;

\echo '--- P7: deshabilitar tabla completa y verificar ---'
SELECT public.fn_deshabilitar_tabla('empleado');
SELECT * FROM public.v_dic_tablas;
SELECT count(*) AS activas FROM public.v_configuracion_actual WHERE activo;

\echo '--- P8: detectar columna eliminada tras reconfigurar ---'
SELECT public.fn_configurar_auditoria('empleado', ARRAY['puesto'], ARRAY['UPDATE']);
ALTER TABLE public.empleado DROP COLUMN puesto;
SELECT * FROM public.fn_validar_configuracion();
