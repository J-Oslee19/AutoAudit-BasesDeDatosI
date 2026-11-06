# AutoAudit: triggers automaticos y bitacora (Parte 3)

## Estado de esta entrega

Esta sección registra la revisión histórica del módulo. La [guía de validación](docs/REVISION_FINAL.md) distingue esa revisión, las ejecuciones posteriores en PostgreSQL 18.6 y las pruebas pendientes en Ubuntu 26.04 LTS.

Implementacion integrada en una **copia** del proyecto recibido. Los diez archivos
originales se conservan byte por byte, incluido el PDF de seis paginas leido antes
de programar. No se reescribieron los modulos de configuracion ni de diccionario.

**Validado aqui:** analisis de integracion, sintaxis SQL y cuerpos PL/pgSQL con
pglast 8.7 / analizador PostgreSQL 18.6, y hashes SHA-256 de los originales.
**Pendiente:** ejecutar instalacion, pruebas funcionales, permisos y mediciones
en un servidor PostgreSQL 18 sobre Ubuntu 26.04 LTS. No se obtuvieron tiempos
reales ni se afirma que las pruebas de servidor hayan pasado.
Consultar `docs/resultado_revision_triggers.md` para la evidencia concreta.

## Revision puntual de pg_partition_ancestors y proteccion

Se hizo explicita la columna de salida en 07:

```sql
SELECT 1
FROM pg_catalog.pg_partition_ancestors(TG_RELID::regclass) AS a(ancestro)
WHERE a.ancestro::oid = v_origen;
```

La [documentacion de PostgreSQL 18](https://www.postgresql.org/docs/18/functions-admin.html#FUNCTIONS-PARTITION)
describe un conjunto de valores regclass. Hay una precision importante: el
[catalogo oficial de PostgreSQL 18](https://github.com/postgres/postgres/blob/REL_18_STABLE/src/include/catalog/pg_proc.dat)
declara tambien un parametro OUT llamado `relid`. Por eso la expresion anterior
`a.relid` no era un error demostrado. El ajuste utiliza un alias propio y una
conversion de entrada explicita, sin depender del nombre de salida implicito.
No se sustituyo la funcion por pg_partition_tree ni se cambio el criterio de
pertenencia a la tabla origen.

Se revisaron las demas funciones de catalogo usadas en 07/08/09. No se encontraron
otros accesos a columnas de salida inexistentes. `jsonb_array_elements_text`
devuelve texto escalar y su alias simple es valido; `unnest(...)
WITH ORDINALITY k(numero,orden)` en 08 ya nombra sus dos columnas correctamente.
08 se conserva sin modificaciones.

Se mantuvieron los guardias de seguridad: el registrador es SECURITY DEFINER y
el guardia SECURITY INVOKER, por lo que las inserciones internas anidadas se
ejecutan con el propietario esperado. No se otorgo escritura directa adicional
ni se desactivaron triggers. En 09 se agregaron comprobaciones de permisos y de
altas automaticas, verificacion explicita del servidor 18 y pruebas de ancestros,
INSERT por raiz/hoja, UPDATE y DELETE particionados con usuario normal.
**Son pruebas preparadas, no ejecutadas en servidor.**

Para actualizar una instalacion existente, ejecutar 07 como el mismo postgres que
instalo el modulo. CREATE OR REPLACE mantiene la identidad de las funciones y los
triggers existentes usan la definicion actualizada; no hace falta reinstalar 01
ni modificar configuracion. Ejecutar el 09 actualizado solo en otra base de prueba
vacia, siguiendo los pasos de abajo. 08 no requiere reinstalacion por este ajuste.

## Archivos agregados y su funcion

| Archivo | Funcion |
|---|---|
| `sql/07_funciones_bitacora.sql` | Registra cambios, resuelve usuario/estacion y protege el historial. Incluye su propia instalacion transaccional de permisos y guardias. |
| `sql/08_generador_triggers.sql` | Genera, regenera y retira exclusivamente los triggers administrados por este modulo. |
| `sql/09_pruebas_triggers.sql` | Pruebas con aserciones, errores esperados y mediciones de 100, 1000 y 5000 filas; finaliza con ROLLBACK. |
| `README_modulo_triggers.md` | Instalacion, uso, seguridad, limites y diagnostico. |
| `docs/analisis_integracion_triggers.md` | Inventario tecnico y decisiones derivadas de la revision previa. |
| `docs/resultado_revision_triggers.md` | Comprobaciones efectivamente realizadas y pendientes. |
| `docs/originales_sha256.csv` | Huellas de los diez archivos originales para comprobar su conservacion. |

No fue necesario un script de migracion de columnas: el esquema existente basta.
El archivo 07 contiene los cambios de permisos y los nuevos triggers de proteccion,
separados del generador 08. No hay tablas adicionales, cambios de nombres, PK o FK,
ni UPDATE/DELETE de datos anteriores durante la instalacion.

## Instalacion en Ubuntu 26.04 LTS

El [README principal](README.md) contiene el procedimiento vigente para instalar todos los módulos por socket Unix o por TCP con contraseña. Los pasos manuales de esta sección corresponden a la entrega histórica de la Parte 3.

### 1. Instalar y comprobar PostgreSQL 18

```bash
sudo apt update
sudo apt install postgresql-18 postgresql-client-18
sudo systemctl start postgresql
sudo -u postgres psql -X -d postgres -c 'SHOW server_version;'
```

Si los paquetes 18 no estan disponibles en los repositorios configurados, usar
las [instrucciones oficiales de PostgreSQL para Ubuntu](https://www.postgresql.org/download/linux/ubuntu/).
No sustituir automaticamente por otra version. Si existen varios clusters, indicar
el puerto del cluster 18 mediante `-p PUERTO` en createdb y en todos los psql.
El script 07 comprueba la version del servidor, no solo la del cliente.

Descomprimir el ZIP de esta entrega en una carpeta propia y entrar en
`AutoAudit_integrado`. Ejecutar como el mismo superusuario `postgres` en ambos
scripts de instalacion nuevos; las funciones SECURITY DEFINER quedan a su nombre.
Los usuarios de negocio deben conectarse con roles normales, no como postgres.

### 2. Crear una base de prueba nueva

```bash
sudo -u postgres createdb autoaudit_pruebas
```

Si ya existe, elegir un nombre nuevo que empiece por `autoaudit_pruebas`, por
ejemplo `autoaudit_pruebas_2`, y sustituirlo en los comandos siguientes.
No ejecutar DROP DATABASE ni reutilizar una base con informacion importante.

### 3. Instalar el proyecto y este modulo en el orden correcto

Ejecutar los comandos por separado y detenerse si alguno informa un error:

```bash
sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d autoaudit_pruebas -f sql/01_tablas.sql
sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d autoaudit_pruebas -f sql/03_ajustes_configuracion.sql
sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d autoaudit_pruebas -f sql/04_consultas_diccionario.sql
sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d autoaudit_pruebas -f sql/05_modulo_configuracion.sql
sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d autoaudit_pruebas -f sql/07_funciones_bitacora.sql
sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d autoaudit_pruebas -f sql/08_generador_triggers.sql
```

**No incluir 06 en esta instalacion de pruebas:** el script original elimina y
recrea `empleado`, genera errores deliberados y termina dejando una columna
eliminada con configuracion activa. Se conserva sin modificar, pero pertenece
a otra demostracion. Tampoco ejecutar todos los archivos `*.sql` indiscriminadamente.

En una base existente con 01/03/04/05 instalados, no reinstalar 01: revisar
`SELECT * FROM public.fn_validar_configuracion();` y ejecutar solo 07 y 08.
Los scripts 07 y 08 pueden repetirse con el mismo propietario. La reinstalacion
no borra bitacora ni configuraciones y no genera triggers de negocio hasta
que se llame al generador.

### 4. Ejecutar pruebas y guardar la salida real

```bash
sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d autoaudit_pruebas \
  -f sql/09_pruebas_triggers.sql > docs/resultado_pruebas_triggers_local.txt 2>&1
echo $?
```

Un codigo 0 y el mensaje final `TODAS LAS COMPROBACIONES TERMINARON`, seguido de
`ROLLBACK`, indican que el recorrido termino sin fallos. Cada comprobacion imprime
`OK`; un fallo levanta una excepcion y psql sale con error. Los errores negativos
esperados se capturan dentro del script: no se desactiva ON_ERROR_STOP.

La prueba exige base desechable sin filas en configuracion ni bitacora. Crea
roles, tablas y funciones de prueba dentro de una transaccion y los revierte.
No ejecuta DROP/UPDATE sobre datos de negocio anteriores. Puede dejar huecos en
secuencias existentes: PostgreSQL no revierte nextval; por eso se exige una base
desechable. Una salida con fallo no debe presentarse como prueba aprobada.

## Uso normal e integracion con la Parte 2

Otorgar el rol existente a un usuario administrativo real, como postgres:

```sql
GRANT autoaudit_admin TO mi_usuario;
```

`mi_usuario` debe existir; no se incluye una contrasena predeterminada. La
aplicacion conserva sus permisos normales sobre las tablas de negocio y no
necesita escribir ni tener SELECT en bitacora para que la auditoria funcione.

Ejemplo para una tabla `empleado` ya existente (estos nombres son solo ejemplo;
el generador no tiene nombres de tablas de negocio codificados):

```sql
SELECT * FROM public.v_dic_tablas;
SELECT * FROM public.fn_dic_columnas('empleado');

BEGIN;
SELECT public.fn_configurar_auditoria(
  'empleado', ARRAY['salario','puesto'], ARRAY['INSERT','UPDATE','DELETE']);
SELECT * FROM public.fn_autoaudit_regenerar('empleado');
COMMIT;

-- Procesar automaticamente TODAS las configuraciones registradas:
SELECT * FROM public.fn_autoaudit_regenerar();
```

La generacion es automatica respecto a nombres, columnas y operaciones: todos
se obtienen del catalogo y de `v_configuracion_actual`. **Se invoca explicitamente
el generador al guardar la configuracion.** No se agregan hooks ni se cambia el
cuerpo de las funciones de la companera. Para una interfaz, ambas llamadas deben
ejecutarse en la misma transaccion. Si el generador falla, hacer ROLLBACK.

Desactivar un evento o columna tiene efecto inmediato porque el registrador lee
`activo AND tabla_habilitada` en cada operacion. Activar columnas de un evento que
ya esta en el trigger tambien tiene efecto inmediato. Crear una nueva tabla,
habilitar una operacion que no estaba en el trigger, cambiar la PK o volver a
habilitar una tabla cuyo trigger se retiro requiere regenerar. Usar siempre:

```sql
BEGIN;
SELECT public.fn_cambiar_estado_evento('empleado','salario','UPDATE',false);
SELECT * FROM public.fn_autoaudit_regenerar('empleado');
COMMIT;

BEGIN;
SELECT public.fn_deshabilitar_tabla('empleado');
SELECT * FROM public.fn_autoaudit_regenerar('empleado');
COMMIT;
```

Retiro administrativo explicito (sin borrar configuracion ni historial):

```sql
SELECT public.fn_autoaudit_retirar('empleado'); -- solo esa tabla
SELECT public.fn_autoaudit_retirar();           -- todas las del modulo
```

Retirar deja de auditar, aunque la configuracion siga activa. Una regeneracion
posterior reinstala los triggers correspondientes. Para una desactivacion
persistente, usar primero `fn_deshabilitar_tabla`. El retiro no retira los guardias
de bitacora/usuarios/estaciones, ni toca triggers de otras funciones.

### Desactivación y mantenimiento

Retirar `aa_auditar_fila`, deshabilitarlo por DDL o desactivar la configuración deja sin registrar las operaciones correspondientes durante la ventana. La bitácora existente se conserva. Reactivar o regenerar vuelve a capturar cambios a partir de ese momento. Si se exige trazabilidad continua, mantén el trigger activo y mide las operaciones con el volumen de la carga prevista.

Si se autoriza una pausa, documenta el alcance, responsable, motivo y horas de inicio y fin. Verifica el estado efectivo y realiza una operación controlada al reactivar. `trigger_instalado` en el reporte histórico indica presencia del objeto. El reporte de triggers distingue habilitación en sesiones normales y modo de disparo. Los estados `O` y `A` capturan en sesiones normales, `D` está deshabilitado y `R` actúa solo en modo réplica. Mantén activos los guardias de historial.

```sql
SELECT * FROM public.fn_reporte_estado_triggers()
WHERE nombre_tabla = 'cliente';
```

## Que se guarda y por que es compatible

Se inserta **una fila por columna configurada y evento**, no una por registro
completo. `id_configuracion` ya enlaza tabla, columna y tipo de evento; duplicar
esos campos en bitacora seria innecesario. La cadena de relaciones se conserva:

```text
bitacora -> configuracion_auditoria -> columna_auditada -> tabla_auditada
                                  -> evento_auditoria
        -> usuario_auditado
        -> estacion_trabajo
```

| Operacion | valor_anterior | valor_nuevo |
|---|---|---|
| INSERT | NULL | Valor insertado, incluso si es NULL |
| UPDATE | Valor anterior | Valor nuevo, solo si realmente cambio |
| DELETE | Valor eliminado | NULL |

Los valores se convierten a TEXT sin truncarlos, como dispone el esquema.
UPDATE usa comparacion nativa `IS DISTINCT FROM`, que detecta transiciones NULL
y evita diferencias falsas como numeric 1.0 frente a 1.00. Para tipos sin operador
de igualdad (por ejemplo json), se compara su representacion textual: cambios de
formato tambien cuentan. SQL NULL y el texto o JSON `null` permanecen distintos.

`id_registro` usa la PK real consultada en `pg_index`/`pg_attribute`:

- PK simple: `{"id_empleado": 5}`.
- PK compuesta: `{"empresa": 1, "codigo": "A"}`.
- Cambio de PK en UPDATE auditado: `{"anterior": {...}, "nuevo": {...}}`.
- Sin PK: NULL; se informa en la salida de generacion, no se inventa una clave
  inestable como ctid ni se altera el modelo de negocio.

Si solo cambia una PK que no fue seleccionada para auditoria, no se genera una
fila artificial. Seleccionar tambien las columnas de PK si se requiere rastrear
ese cambio por si mismo. Tras cambios DDL de tablas o PK, regenerar antes del DML.

El usuario se obtiene de `session_user`, conservando el login responsable dentro
de SECURITY DEFINER. Con SET ROLE se conserva el login; no se atribuye el cambio
al propietario postgres. Una aplicacion con login compartido identifica ese login
de BD, no al usuario humano de la interfaz. No se acepta un nombre enviado por
el cliente para suplantar la identidad.

La IP procede de `inet_client_addr()`: socket Unix produce NULL; un proxy puede
mostrar la IP del proxy. No se inventa IP ni nombre de equipo. Se almacena
`IP:<direccion>` o `SIN_IP_DISPONIBLE`. La fecha se obtiene de `clock_timestamp()`
en hora de Guatemala porque el campo original es timestamp sin zona. No se
convierte ni modifica ninguna fecha historica anterior; su zona original puede
ser diferente y debe considerarse al mezclar historiales.

Usuario y estacion se reutilizan; si faltan se crean automaticamente dentro de
la misma transaccion. Si existen duplicados anteriores se elige el menor ID y
no se borran registros. Se usan bloqueos de doble comprobacion para el alta
concurrente bajo el aislamiento predeterminado READ COMMITTED. En otros niveles
de aislamiento, los snapshots pueden requerir reintentos y no se garantiza la
deduplicacion de esos catalogos sin restricciones UNIQUE adicionales. No afecta
la validez de las FK de cada registro de bitacora.

## Seguridad y transacciones

- Generador y retiro: EXECUTE solo para `autoaudit_admin` y comprobacion adicional
  de `session_user`. Se mantiene la autorizacion de configuracion ya implementada.
- Funciones internas en esquema sin USAGE ni EXECUTE publico. Funciones elevadas
  con `search_path = pg_catalog, pg_temp`; tablas del proyecto siempre calificadas.
- Identificadores con `format('%I', ...)`, argumentos con `%L`, filas con USING.
  Los eventos se concatenan solo despues de filtrarlos a INSERT/UPDATE/DELETE.
- Bitacora, usuarios y estaciones: sin escritura directa para PUBLIC/admin;
  guardias BEFORE bloquean tambien DML por permisos particulares heredados,
  UPDATE, DELETE y TRUNCATE. La insercion interna exige profundidad de trigger y
  el usuario de ejecucion propietario del registrador, no solo profundidad.
- Los guardias protegen referencias historicas; impiden tambien la edicion manual
  de nombres de usuarios y estaciones. Las altas normales son automaticas.
- Propietarios, superusuarios y administradores del sistema son de confianza:
  pueden alterar objetos o desactivar triggers. No es una bitacora inmutable
  frente a un superusuario hostil. No otorgar propiedad, membresia de postgres,
  permisos DDL de tablas auditadas ni capacidad de crear objetos en esquemas
  confiables a usuarios de negocio.
- No se evita recursividad descartando ciegamente `pg_trigger_depth()>1` en el
  registrador: cambios de negocio causados por otros triggers tambien se auditan.
  Se excluyen las siete tablas internas de AutoAudit.
- Error al registrar: aborta la operacion de negocio; no se acepta un cambio sin
  historial. ROLLBACK tambien revierte bitacora. No registra intentos fallidos en
  una transaccion autonoma, que PostgreSQL no ofrece con un trigger ordinario.
- Error al generar: revierte toda la llamada, incluidas eliminaciones de triggers
  previos; el error SQL y el contexto llegan al cliente. El generador toma bloqueos
  durante la transaccion, por lo que debe ejecutarse en transacciones cortas.

No se desactiva seguridad ni session_replication_role para facilitar pruebas.
Los guardias se instalan sin cambiar claves ni datos originales. Antes de aplicar
07 a un sistema con cargas manuales de catalogos, revisar ese flujo: las cargas
directas quedaran bloqueadas por diseno.

## Alcance y limites conocidos

- Se trabaja en `public`, igual que el modulo de configuracion recibido.
- Un trigger administrado AFTER FOR EACH ROW por tabla, con la union de operaciones
  activas. La funcion de registro se comparte; cada trigger esta unido a su tabla.
- Raices particionadas: clones nativos por particion, sin configurar las hojas.
  No se permite auditar a la vez hojas ni tablas de herencia clasica. El movimiento
  entre particiones puede observarse como DELETE/INSERT, segun la semantica de
  PostgreSQL. Las pruebas de particiones estan preparadas, pendientes de servidor.
- TRUNCATE de tablas de negocio no forma parte de INSERT/UPDATE/DELETE. No usarlo
  para eliminaciones que deban conservar valores; retirar TRUNCATE a roles de
  negocio segun su politica. TRUNCATE de la bitacora si queda bloqueado.
- DROP/RENAME de negocio no se intercepta con event triggers. Validar y regenerar
  tras DDL. El historial permanece en las tablas originales del sistema.
- No se agregan interfaz, exportador de reportes, indices ni modulos ajenos a la
  responsabilidad asignada. Las consultas de abajo son solo diagnostico.
- No se garantiza impacto de rendimiento insignificante sin medir en el equipo
  objetivo. Hay una insercion por columna/evento auditado y SQL dinamico por columna.
  El ensayo mide una sola pasada de 100/1000/5000 filas; repetir con cache caliente,
  concurrencia y volumen real antes de fijar un umbral de aceptacion.

## Diagnostico y consulta de la evidencia

Estado de configuracion y triggers:

```sql
SELECT * FROM public.fn_validar_configuracion();
SELECT * FROM public.v_configuracion_actual;
SELECT c.relname AS tabla, t.tgname, pg_get_triggerdef(t.oid)
FROM pg_catalog.pg_trigger t
JOIN pg_catalog.pg_class c ON c.oid=t.tgrelid
WHERE t.tgfoid='autoaudit_interno.registrar_cambio()'::regprocedure
ORDER BY c.relname;
```

La ultima consulta de diagnostico se ejecuta como postgres (el esquema interno
no es accesible al administrador normal). Lectura de la bitacora como admin:

```sql
SELECT b.id_bitacora,c.nombre_tabla,c.nombre_columna,c.tipo_evento,
       b.id_registro,b.valor_anterior,b.valor_nuevo,
       u.nombre_usuario,b.fecha_hora,e.nombre_estacion,e.direccion_ip
FROM public.bitacora b
JOIN public.v_configuracion_actual c USING(id_configuracion)
JOIN public.usuario_auditado u USING(id_usuario)
JOIN public.estacion_trabajo e USING(id_estacion)
ORDER BY b.id_bitacora;
```

No filtrar `activo` al consultar historial: los registros antiguos siguen siendo
validos aunque esa configuracion este deshabilitada.

| Problema detectado | Solucion sin tocar el codigo anterior |
|---|---|
| fn_validar_configuracion informa columna borrada (posible tras 06) | Desactivar su evento o tabla con las funciones existentes; corregir el DDL si corresponde; regenerar. No borrar configuracion referenciada por bitacora. |
| Colision con `aa_auditar_fila` de otra funcion | El generador aborta; revisar el objeto ajeno con su responsable. Nunca se sobrescribe automaticamente. |
| No aparece un evento nuevo en auditoria | Guardar configuracion y llamar al generador dentro de la misma transaccion. |
| Escritura directa bloqueada | Usar DML de negocio y dejar que el trigger registre; no desactivar el guardia. |
| IP NULL | Comportamiento esperado en socket local; no significa fallo. |
| Auditoria falla tras ALTER TABLE | Validar configuracion y regenerar con una PK/columnas vigentes antes de operar. |
| Deadlock o lock_timeout durante administracion concurrente | ROLLBACK y reintentar toda la transaccion; coordinar los cambios de configuracion. |

## Referencias tecnicas contrastadas

- PDF original, paginas 3 a 6: alcance, AFTER, contexto, preservacion historica,
  seguridad, pruebas y plataforma. El PDF dice PL/SQL; esta parte usa PL/pgSQL.
- [CREATE TRIGGER en PostgreSQL 18](https://www.postgresql.org/docs/18/sql-createtrigger.html).
- [Funciones de trigger y OLD/NEW](https://www.postgresql.org/docs/18/plpgsql-trigger.html).
- [Transacciones y comportamiento de triggers](https://www.postgresql.org/docs/18/trigger-definition.html).
- [SECURITY DEFINER y search_path](https://www.postgresql.org/docs/18/sql-createfunction.html).
- [Identidad de sesion e IP](https://www.postgresql.org/docs/18/functions-info.html).
