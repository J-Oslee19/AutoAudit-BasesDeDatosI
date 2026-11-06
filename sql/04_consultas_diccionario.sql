-- =====================================================================
-- AutoAudit - 04_consultas_diccionario.sql
-- Consultas al diccionario de datos de PostgreSQL (pg_catalog) para
-- listar las tablas y columnas que se pueden seleccionar para auditoría.
-- =====================================================================

-- Tablas internas del sistema: nunca se pueden auditar (evita recursión)
CREATE OR REPLACE FUNCTION public.fn_es_tabla_sistema(p_tabla text)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$
  SELECT lower(p_tabla) IN ('tabla_auditada','columna_auditada','evento_auditoria',
                            'configuracion_auditoria','usuario_auditado',
                            'estacion_trabajo','bitacora');
$$;

-- ---------------------------------------------------------------------
-- Vista: tablas de usuario existentes en el esquema public que se pueden
-- seleccionar, indicando si ya están configuradas.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_dic_tablas AS
SELECT c.relname::text                                   AS nombre_tabla,
       (SELECT count(*) FROM pg_attribute a
         WHERE a.attrelid = c.oid AND a.attnum > 0
           AND NOT a.attisdropped)                       AS num_columnas,
       COALESCE(t.estado, false)                         AS auditada,
       (t.id_tabla IS NOT NULL)                          AS registrada
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN public.tabla_auditada t ON t.nombre_tabla = c.relname
WHERE n.nspname = 'public'
  AND c.relkind IN ('r','p')                 -- tablas ordinarias y particionadas
  AND NOT public.fn_es_tabla_sistema(c.relname)
ORDER BY c.relname;

-- ---------------------------------------------------------------------
-- Función: columnas de una tabla, con tipo, nulabilidad, PK y estado de
-- auditoría por evento.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_dic_columnas(p_tabla text)
RETURNS TABLE (
  orden           smallint,
  nombre_columna  text,
  tipo_dato       text,
  permite_nulos   boolean,
  es_pk           boolean,
  audita_insert   boolean,
  audita_update   boolean,
  audita_delete   boolean
)
LANGUAGE sql STABLE
AS $$
  SELECT a.attnum,
         a.attname::text,
         format_type(a.atttypid, a.atttypmod),
         NOT a.attnotnull,
         COALESCE(a.attnum = ANY (i.indkey::smallint[]), false),
         COALESCE(bool_or(ev.tipo_evento = 'INSERT' AND cfg.activo), false),
         COALESCE(bool_or(ev.tipo_evento = 'UPDATE' AND cfg.activo), false),
         COALESCE(bool_or(ev.tipo_evento = 'DELETE' AND cfg.activo), false)
  FROM pg_class c
  JOIN pg_namespace n  ON n.oid = c.relnamespace AND n.nspname = 'public'
  JOIN pg_attribute a  ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
  LEFT JOIN pg_index i ON i.indrelid = c.oid AND i.indisprimary
  LEFT JOIN public.tabla_auditada ta     ON ta.nombre_tabla = c.relname
  LEFT JOIN public.columna_auditada ca   ON ca.id_tabla = ta.id_tabla
                                        AND ca.nombre_columna = a.attname
  LEFT JOIN public.configuracion_auditoria cfg ON cfg.id_columna = ca.id_columna
  LEFT JOIN public.evento_auditoria ev   ON ev.id_evento = cfg.id_evento
  WHERE c.relname = p_tabla
    AND c.relkind IN ('r','p')
  GROUP BY a.attnum, a.attname, a.atttypid, a.atttypmod, a.attnotnull, i.indkey
  ORDER BY a.attnum;
$$;

-- ---------------------------------------------------------------------
-- Vista: configuración vigente (qué se audita hoy). Es la "tabla de
-- configuración que refleja el estado actual" del criterio técnico.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_configuracion_actual AS
SELECT t.nombre_tabla,
       t.estado            AS tabla_habilitada,
       ca.nombre_columna,
       ev.tipo_evento,
       cfg.activo,
       cfg.id_configuracion
FROM public.configuracion_auditoria cfg
JOIN public.columna_auditada ca ON ca.id_columna = cfg.id_columna
JOIN public.tabla_auditada   t  ON t.id_tabla    = ca.id_tabla
JOIN public.evento_auditoria ev ON ev.id_evento  = cfg.id_evento
ORDER BY t.nombre_tabla, ca.nombre_columna, ev.tipo_evento;

GRANT SELECT ON public.v_dic_tablas, public.v_configuracion_actual TO autoaudit_admin;
GRANT EXECUTE ON FUNCTION public.fn_dic_columnas(text), public.fn_es_tabla_sistema(text)
  TO autoaudit_admin;
