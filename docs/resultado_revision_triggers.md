# Evidencia de revision de la Parte 3

Fecha de la entrega: 2026-10-29 (Guatemala).

## Comprobaciones realmente ejecutadas

| Comprobacion | Resultado observado |
|---|---|
| Inventario de la carpeta recibida | 2 subcarpetas, 10 archivos originales, 5 SQL |
| Lectura del PDF | 6 paginas extraidas con pypdf y renderizadas con pypdfium2; inspeccion visual del conjunto |
| Lectura de SQL y documentos originales | Completada antes de desarrollar |
| Comparacion SHA-256 original/copia | 10 de 10 identicos; evidencia en originales_sha256.csv |
| Sintaxis de 07 | 15 sentencias SQL aceptadas; 5 bloques PL/pgSQL aceptados |
| Sintaxis de 08 | 8 sentencias SQL aceptadas; 2 bloques PL/pgSQL aceptados |
| Sintaxis de 09 actualizado | 135 sentencias SQL aceptadas; 9 bloques PL/pgSQL aceptados |
| Herramienta de analisis | pglast 8.7; version del analizador PostgreSQL reportada: (18, 6) |
| Servidor de pruebas | No disponible en esta sesion; no hubo conexion ni instalacion en una BD |

Para el analizador se retiraron solo las lineas de metacomandos psql que empiezan
por barra invertida. Se analizaron tanto las sentencias SQL como los cuerpos
PL/pgSQL con `parse_sql` y `parse_plpgsql_json`. Esto **no ejecuta SQL**: no comprueba
resolucion de tipos/objetos, permisos efectivos, SQL dinamico ni funcionamiento
de los triggers en un servidor. Es evidencia de sintaxis, no de pruebas funcionales.

El ejecutable python predeterminado no estaba utilizable; se uso el runtime
Python incluido con la aplicacion. `psql`, `postgres` y `docker` no estaban en
PATH ni se identifico una instalacion PostgreSQL en Program Files. La consulta
de WSL fuera del sandbox termino con `REGDB_E_CLASSNOTREG`; no se obtuvo un entorno
Ubuntu utilizable. No se recibieron datos de conexion a un servidor remoto.

## Revision puntual posterior: funciones de catalogo y guardias

El supuesto fallo en `a.relid` se contrasto tanto con la documentacion como con
el codigo fuente oficial de PostgreSQL 18. El retorno es SETOF regclass, pero
el catalogo declara OUT relid. Por ello no se confirma que la consulta anterior
fuera invalida: se cambio a un alias explicito `AS a(ancestro)` con
`TG_RELID::regclass` para expresar el contrato escalar directamente.
No se afirma que se reprodujo un error de ejecucion.

Archivos modificados en esta revision: 07, 09, README_modulo_triggers.md y este
informe. 08 permanece identico, con SHA-256
`af5eb0c34a224f6cb77f0f9e7136c4eb9027b00c852ea3044824af0d6e2c46f1`.
Los diez archivos originales se verificaron otra vez contra el manifiesto;
ningun archivo de los companeros se modifico. El ZIP se reconstruye con la copia
actualizada y se comprueba su contenido contra los archivos de esa copia.

Revision de las llamadas de pg_catalog usadas en 07/08/09:

| Grupo | Conclusion de la revision de lectura |
|---|---|
| pg_partition_ancestors | Conjunto escalar regclass, alias explicito agregado; no requiere usar las columnas de pg_partition_tree. |
| jsonb_array_elements_text, unnest | Retornos escalares; los alias existentes son validos. WITH ORDINALITY de 08 tiene sus dos nombres explicitos. |
| jsonb_array_length, to_jsonb, jsonb_build_object | Resultados escalares, sin accesos a campos ficticios. |
| jsonb_agg, jsonb_object_agg, string_agg | Agregados con resultado unico; no se interpretan como filas de catalogo. |
| to_regclass, to_regprocedure | Se usan identificadores de objetos, convertibles a OID para consultas y comparaciones. |
| pg_get_userbyid, pg_has_role, pg_trigger_depth | Compatibles con las comparaciones de propietario, pertenencia y profundidad usadas por los guardias. |
| hashtextextended, pg_advisory_xact_lock | El hash se usa como clave bigint; la administracion usa la sobrecarga de dos integer. |
| format, clock_timestamp, host, inet_client_addr | Operaciones escalares; valores y nombres tratados segun sus tipos. |
| has_table_privilege (nuevo en 09) | Comprueba falta de INSERT directo antes del recorrido positivo del registrador. |

Tambien se revisaron las consultas a pg_proc, pg_roles, pg_trigger, pg_class,
pg_namespace, pg_attribute, pg_index y pg_inherits. Son tablas/vistas de catalogo;
sus columnas consultadas no se confundieron con retornos escalares de funciones.
Los demas generadores de filas de 09, como generate_series, usan alias escalares.

Sobre las inserciones internas: registrar_cambio usa SECURITY DEFINER;
proteger_historial usa SECURITY INVOKER y conserva ese usuario de ejecucion en
la llamada anidada. Se satisfacen por diseno propietario y profundidad > 1,
permitiendo los INSERT internos. No se cambia el guardia ni se debilita REVOKE.
Su comprobacion efectiva queda pendiente en servidor.

09 agrega aserciones para comprobar permisos, modos de seguridad, altas de usuario
y estacion, retorno regclass, alias de ancestros y cuatro cambios particionados
por operador normal (INSERT por raiz y hoja, UPDATE y DELETE) sin duplicados.
Exige server_version_num de la rama 18. Estas aserciones NO se ejecutaron aqui.

La revision de sintaxis se repitio tras los ajustes: 07 = 15/5, 08 = 8/2,
09 = 135/9 (sentencias SQL / bloques PL/pgSQL). El analizador no sustituye la
resolucion de tipos, planes, ACL ni ejecucion dinamica del servidor real.

Fuentes primarias consultadas:

- [Informacion de particiones PostgreSQL 18](https://www.postgresql.org/docs/18/functions-admin.html#FUNCTIONS-PARTITION).
- [Catalogo de funciones REL_18_STABLE](https://github.com/postgres/postgres/blob/REL_18_STABLE/src/include/catalog/pg_proc.dat).
- [Semantica de seguridad de los triggers](https://www.postgresql.org/docs/18/trigger-definition.html).
- [Funciones de arrays](https://www.postgresql.org/docs/18/functions-array.html) y
  [funciones JSON](https://www.postgresql.org/docs/18/functions-json.html).

## Revision de codigo realizada

- Campos y contratos confrontados con 01, 03, 04, 05 y diccionario recibido.
- No se alteran funciones/vistas originales ni se agregan columnas o claves.
- Eventos derivados de configuracion; tabla/columnas verificadas en pg_catalog.
- Identificadores dinamicos con %I, argumentos con %L y valores con USING.
- Funciones privilegiadas con ruta segura y funciones internas sin acceso publico.
- UPDATE usa IS DISTINCT FROM y fallback textual solo para tipos sin igualdad.
- INSERT/UPDATE/DELETE usan la configuracion real y conservan referencias de bitacora.
- Errores de ejecucion se propagan; la transaccion evita datos sin auditoria.
- Reconocimiento de triggers propios por OID de funcion; no por prefijo de nombre.
- Orden de instalacion documentado; 06 excluido de la nueva base de pruebas.

Estas son comprobaciones de lectura y analisis, no resultados de ejecucion.

## Pruebas preparadas pero NO ejecutadas en servidor

El archivo 09 incluye aserciones para:

1. Generacion repetida, un trigger y administracion por miembro no superusuario.
2. INSERT de columnas seleccionadas y contexto usuario/fecha/IP/PK.
3. UPDATE con anterior/nuevo y omision de valores iguales y columnas no elegidas.
4. Transiciones SQL NULL/no NULL y distincion del texto `null`.
5. Desactivacion inmediata por columna/evento, retiro de UPDATE y reactivacion.
6. DELETE con valores antiguos y conservacion de historial.
7. Deshabilitacion de tabla y retiro de su trigger sin perder historial.
8. Rechazo de INSERT/UPDATE/DELETE/TRUNCATE directos en bitacora, aun con GRANT.
9. Rechazo de configuracion y generacion por usuario sin autorizacion.
10. Identificadores con espacios, punto y coma y columnas con nombres especiales.
11. PK compuesta, cambio de PK y ausencia de PK sin inventar identificadores.
12. Tipo json, incluido SQL NULL frente a JSON null.
13. Raiz particionada y ausencia de doble registro por los clones nativos.
14. Conservacion de triggers ajenos, colision de nombre y retiro repetido.
15. Columna eliminada, generacion fallida atomica y tabla inactiva eliminada.
16. Error de bitacora que revierte tambien INSERT de negocio.
17. ROLLBACK de negocio que revierte tambien historial.
18. Cantidades correctas y tiempos comparativos de UPDATE de 100/1000/5000 filas,
    con y sin auditoria. La salida se crea solo al ejecutar en el entorno destino.

No se completan aqui resultados ficticios, duraciones estimadas ni una columna
de "aprobado" para estas pruebas. Pendiente adicional para despliegue real:
concurrencia entre sesiones, carga representativa, politicas de privilegios de la
aplicacion, permisos DDL y conexiones reales tanto TCP/IP como socket Unix.

## Como obtener evidencia reproducible

Seguir README_modulo_triggers.md en una BD nueva PostgreSQL 18 / Ubuntu 26.04,
sin ejecutar 06. Guardar SHOW server_version y la salida completa de 09. Si psql
termina con error, conservar la salida, corregir la causa y repetir en una nueva
base desechable. No convertir esta validacion estatica en una afirmacion de
compatibilidad funcional comprobada.
