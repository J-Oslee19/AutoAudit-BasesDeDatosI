-- =====================================================================
-- AutoAudit - 03_ajustes_configuracion.sql
-- Ajustes al esquema de la Parte 1 necesarios para el módulo de
-- configuración: restricciones de unicidad, catálogo de eventos y rol.
-- Ejecutar DESPUÉS de 01_tablas.sql. Es idempotente.
-- =====================================================================

-- 1. Restricciones de integridad (evitan configuraciones duplicadas)
DO $$
DECLARE
  esperada record;
  actual pg_catalog.pg_constraint%ROWTYPE;
  definicion text;
BEGIN
  FOR esperada IN SELECT * FROM (VALUES
    ('tabla_auditada', 'uq_tabla_auditada_nombre', 'UNIQUE (nombre_tabla)'),
    ('columna_auditada', 'uq_columna_auditada_tabla_nombre', 'UNIQUE (id_tabla, nombre_columna)'),
    ('evento_auditoria', 'uq_evento_tipo', 'UNIQUE (tipo_evento)'),
    ('evento_auditoria', 'ck_evento_tipo', $check$CHECK (tipo_evento IN ('INSERT','UPDATE','DELETE'))$check$),
    ('configuracion_auditoria', 'uq_configuracion_columna_evento', 'UNIQUE (id_columna, id_evento)')
  ) AS m(tabla, nombre, ddl) LOOP
    SELECT * INTO actual
      FROM pg_catalog.pg_constraint
     WHERE conrelid = pg_catalog.to_regclass(pg_catalog.format('public.%I', esperada.tabla))
       AND conname = esperada.nombre;

    IF NOT FOUND THEN
      EXECUTE pg_catalog.format('ALTER TABLE public.%I ADD CONSTRAINT %I %s',
                                esperada.tabla, esperada.nombre, esperada.ddl);
      CONTINUE;
    END IF;

    definicion := esperada.ddl;
    IF esperada.nombre = 'ck_evento_tipo' THEN
      -- Comparar la forma canónica de PostgreSQL, incluidas las conversiones.
      EXECUTE pg_catalog.format(
        'CREATE TEMP TABLE aa_verificar_evento (tipo_evento varchar(20), CONSTRAINT aa_regla %s) ON COMMIT DROP',
        esperada.ddl);
      SELECT pg_catalog.pg_get_constraintdef(oid) INTO STRICT definicion
        FROM pg_catalog.pg_constraint
       WHERE conrelid = 'pg_temp.aa_verificar_evento'::pg_catalog.regclass AND conname = 'aa_regla';
      DROP TABLE pg_temp.aa_verificar_evento;
    END IF;
    IF NOT actual.convalidated OR NOT actual.conenforced
       OR pg_catalog.pg_get_constraintdef(actual.oid) IS DISTINCT FROM definicion THEN
      RAISE EXCEPTION 'Restricción incompatible en public.%.%', esperada.tabla, esperada.nombre;
    END IF;
  END LOOP;
END $$;

-- 2. Catálogo de eventos auditables
INSERT INTO public.evento_auditoria (tipo_evento)
SELECT v FROM (VALUES ('INSERT'), ('UPDATE'), ('DELETE')) AS t(v)
ON CONFLICT (tipo_evento) DO NOTHING;

-- 3. Rol administrador de auditoría (requisito de seguridad:
--    solo usuarios con privilegios administrativos configuran auditoría)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'autoaudit_admin') THEN
    CREATE ROLE autoaudit_admin NOLOGIN;
  END IF;
END $$;

-- 4. Las tablas de configuración no se modifican directamente:
--    solo mediante las funciones del módulo (SECURITY DEFINER).
REVOKE ALL ON public.tabla_auditada, public.columna_auditada,
              public.configuracion_auditoria, public.evento_auditoria
  FROM PUBLIC;
GRANT SELECT ON public.tabla_auditada, public.columna_auditada,
                public.configuracion_auditoria, public.evento_auditoria
  TO autoaudit_admin;
