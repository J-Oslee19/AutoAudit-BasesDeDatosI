# AutoAudit

Sistema de auditoría automatizada para PostgreSQL 18. Proyecto del curso Bases de Datos I, Universidad Mariano Gálvez de Guatemala.

El administrador elige qué tablas, columnas y operaciones (INSERT, UPDATE, DELETE) se auditan. A partir de esa configuración se generan los triggers, y cada cambio queda en una bitácora con el valor anterior, el nuevo, el usuario, la estación y la fecha. Después el historial se puede consultar por usuario, por columna, por registro o en línea de tiempo, y exportar a CSV y JSON.

Diagramas en Canva: https://www.canva.com/design/DAHZt1u_StU/view

El [PDF técnico](docs/Documentacion_Final_AutoAudit.pdf) contiene el diagrama ER, el diccionario, el procedimiento de instalación y las pruebas históricas. La [revisión técnica](docs/REVISION_FINAL.md) incluye los comandos para repetir la validación en Ubuntu.

## Instalación rápida (Ubuntu 26.04 + PostgreSQL 18)

```bash
sudo apt install postgresql-18 postgresql-client-18
bash instalar.sh autoaudit
```

La conexión predeterminada usa el socket Unix de Ubuntu y el usuario de sistema `postgres` vía `sudo`. Para instalar por TCP con contraseña, ejecuta desde una terminal:

```bash
bash instalar.sh --password 127.0.0.1 autoaudit
```

`psql` solicita la contraseña de `postgres` sin eco. El instalador exige SCRAM, ignora `PGPASSWORD` y el archivo de contraseñas, y exige TLS con verificación de certificado y nombre fuera de `localhost`, `127.0.0.1` y `::1`. Configura antes las reglas de autenticación del servidor para las bases `postgres` y de destino. Para conexiones remotas, configura una CA de confianza para `psql`, por ejemplo con `PGSSLROOTCERT`. Para otro puerto, antepón `PGPORT=5433` al comando.

Usa una base de confianza cuyo propietario sea `postgres`. Si falta, se crea desde `template0`. Si existe parte del modelo base o su estructura es incompatible, el instalador se detiene para revisión. Los módulos se aplican dentro de una transacción en la base de destino. Si esa fase falla, puede quedar creada la base vacía. La instalación deja al administrador la activación de auditoría en las tablas de negocio.

Concede los roles a cuentas de base de datos ya existentes según su función.

```sql
GRANT autoaudit_admin TO mi_usuario_administrador;
GRANT autoaudit_consulta TO mi_usuario_auditor;
```

## Interfaz de configuración en psql

Conéctate como miembro de `autoaudit_admin`. Los ejemplos suponen que `public.cliente` y sus columnas ya existen. Para probarlos desde cero, usa la base de demostración de la guía de validación.

```sql
SELECT * FROM public.v_dic_tablas;
SELECT * FROM public.fn_dic_columnas('cliente');

BEGIN;
SELECT public.fn_configurar_auditoria(
  'cliente', ARRAY['limite_credito','categoria'], ARRAY['INSERT','UPDATE','DELETE']
);
SELECT * FROM public.fn_validar_configuracion();
SELECT * FROM public.fn_autoaudit_regenerar('cliente');
COMMIT;

SELECT * FROM public.v_configuracion_actual WHERE nombre_tabla = 'cliente';
```

## Consultas y exportación

Conéctate con un rol de consulta o administración.

```sql
SELECT * FROM public.fn_historial_usuario('demo_cajero');
SELECT * FROM public.fn_historial_columna('cliente','limite_credito');
SELECT * FROM public.fn_historial_registro('cliente','{"id_cliente": 3}');
SELECT * FROM public.fn_linea_tiempo(p_limite => 100);
SELECT * FROM public.fn_reporte_por_usuario('2026-11-01','2026-12-01');
SELECT * FROM public.fn_reporte_estado_triggers();
```

Para exportar los reportes:

```bash
padre=$(mktemp -d reportes-XXXXXX)
destino="$padre/noviembre"
psql -X -d autoaudit -v dir="$destino" -v desde=2026-11-01 -v hasta=2026-12-01 \
  -f sql/12_exportar_reportes.sql
```

`psql` crea el destino con permisos privados. La carpeta padre debe existir, estar bajo tu control y carecer de enlaces simbólicos en su ruta. El destino debe ser nuevo. Usa `psql -X -f` en Ubuntu sin una transacción externa. Las fechas se aplican al historial y a los resúmenes con inicio inclusivo y fin exclusivo. Los reportes comparten una instantánea de solo lectura. `estado_auditoria.csv` conserva su encabezado y refleja la configuración actual de esa instantánea. Para distinguir presencia, habilitación y modo del trigger, consulta `fn_reporte_estado_triggers()`. Si falla la exportación, descarta el lote parcial y reintenta con otro destino. Si abres CSV en una hoja de cálculo, importa los campos como texto para evitar que se interpreten valores de origen como fórmulas.

## Scripts

| Archivo | Contenido |
|---|---|
| `sql/01` y `sql/03` | Modelo de datos y restricciones |
| `sql/04` y `sql/05` | Diccionario de datos y módulo de configuración |
| `sql/07` y `sql/08` | Registro en bitácora, protección y generador de triggers |
| `sql/10` y `sql/11` | Consultas históricas, reportes, índices y rol `autoaudit_consulta` |
| `sql/12` | Exportación a CSV/JSON (se ejecuta, no se instala) |
| `sql/06`, `sql/09` y `sql/13` | Pruebas (ejecutar solo en una BD `autoaudit_pruebas*`) |
| `sql/14` | Ejemplo completo con datos de demostración |

## Pruebas

La [guía de validación](docs/REVISION_FINAL.md#pruebas-para-la-entrega) separa las bases desechables de configuración, validación y demostración e incluye cómo guardar evidencia nueva.

Las salidas históricas de PostgreSQL 18.6 contienen 40 comprobaciones `OK` en `09` y 49 en `13`. La validación del instalador actualizado y la repetición sobre Ubuntu 26.04 LTS están pendientes. A 50 000 filas, la evidencia de `13` registra 7.54 s para `INSERT`, 8.57 s para `UPDATE` y 6.90 s para `DELETE` con una columna auditada.

Retirar o desactivar un trigger deja cambios del período sin registrar. Reactivarlo solo registra operaciones posteriores. Consulta la [guía operativa](README_modulo_triggers.md#desactivacion-y-mantenimiento) antes de una ventana de mantenimiento.
