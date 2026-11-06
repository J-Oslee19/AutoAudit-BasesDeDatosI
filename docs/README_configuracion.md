# AutoAudit – Parte 2: Configuración de auditoría y selección de tablas/columnas

Instala el proyecto con `bash instalar.sh autoaudit` desde la raíz. El instalador ejecuta `03`, `04` y `05` en ese orden después de validar el modelo base. Para usar TCP con contraseña consulta el [README principal](../README.md). Ejecuta `06` como superusuario en una base desechable aparte, pues elimina y recrea `public.empleado`, simula errores y deja una configuración obsoleta.

Concede `autoaudit_admin` a la cuenta que configurará la auditoría y conecta con esa cuenta. Los superusuarios también pueden configurar.

Las siete funciones `SECURITY DEFINER` de `05` usan `pg_catalog, pg_temp` como ruta de búsqueda. Las referencias a los catálogos y a los objetos de AutoAudit están calificadas. Los roles y permisos de configuración conservan su contrato. La [guía de regresión](REVISION_FINAL.md#regresión-de-la-ruta-de-búsqueda-en-05) incluye el caso de una tabla temporal `pg_roles`.

## Flujo de uso
| Paso | Instrucción |
|---|---|
| 1. Ver tablas disponibles (diccionario) | `SELECT * FROM v_dic_tablas;` |
| 2. Ver columnas de una tabla | `SELECT * FROM fn_dic_columnas('empleado');` |
| 3. Configurar (tabla + columnas + eventos) | `SELECT fn_configurar_auditoria('empleado', ARRAY['salario','puesto'], ARRAY['UPDATE','DELETE']);` |
| 3b. Todo (NULL = todas las columnas / eventos) | `SELECT fn_configurar_auditoria('empleado');` |
| 4. Activar/desactivar un evento puntual | `SELECT fn_cambiar_estado_evento('empleado','salario','UPDATE', false);` |
| 5. Deshabilitar toda una tabla | `SELECT fn_deshabilitar_tabla('empleado');` |
| 6. Ver estado actual | `SELECT * FROM v_configuracion_actual;` |
| 7. Detectar config. obsoleta | `SELECT * FROM fn_validar_configuracion();` |

## Reglas implementadas (según la especificación)
- Valida que la tabla y las columnas **existan** antes de registrar (errores 42P01 / 42703); es todo-o-nada.
- Solo **administradores** (rol `autoaudit_admin` o superusuario) ejecutan el módulo (error 42501).
- Las tablas de configuración **no admiten escritura directa**; solo mediante las funciones.
- Las tablas del sistema (`bitacora`, etc.) no se pueden auditar.
- Desactivar nunca borra filas (`activo = false`), así la bitácora conserva su referencia a la configuración.
- Repetir una configuración no duplica filas (restricción UNIQUE).

## Cambios al esquema de la Parte 1 (en `03_`)
UNIQUE en `tabla_auditada(nombre_tabla)`, `columna_auditada(id_tabla, nombre_columna)`,
`evento_auditoria(tipo_evento)`, `configuracion_auditoria(id_columna, id_evento)`;
CHECK de `tipo_evento` e inserción de INSERT/UPDATE/DELETE.

Al reinstalar, `03` busca cada restricción en su tabla y verifica su definición. Si una restricción homónima de la misma tabla es incompatible, la instalación integrada se detiene antes de aplicar los módulos siguientes.

## Aplicar la configuración

Ejecuta `SELECT * FROM public.fn_autoaudit_regenerar('empleado');` en la misma transacción que el cambio de configuración, especialmente al agregar operaciones nuevas. El generador consulta `v_configuracion_actual` y rechaza configuraciones activas obsoletas. `fn_validar_configuracion()` permite revisarlas antes de regenerar.
