### 3. Pipeline `nexus`: ruta y procesadores (etapa Processing)

Dónde: Settings > Process and contextualize > OpenPipeline > Logs. Crear un pipeline `nexus` y una
*dynamic route* con la condición:

```
matchesValue(aws.log_group, "/aws/ecs/srv/*") and (matchesValue(aws.log_group, "*-adapter") or matchesValue(aws.log_group, "*-mngr"))
```

En la etapa Processing, un procesador DQL por tipo de línea, en este orden (los de abajo pisan
`nexus.kind` de los de arriba). Cada procesador tiene su *matching condition* y su script: los dos van en bloques
separados para copiarlos y pegarlos tal cual. Las condiciones usan `matchesValue`, que acepta `*` al principio y al
final del valor y no distingue mayúsculas de minúsculas.
Estado de cada procesador en el tenant: ver Seguimiento.

## 0. Nivel del log.
dentro del mensaje no cambie el nivel de la línea.
Condición:
```
matchesValue(aws.log_group, "/aws/ecs/srv/*") and (matchesValue(aws.log_group, "*-adapter") or matchesValue(aws.log_group, "*-mngr"))
```
Script:
```
fieldsAdd head = substring(content, from: 0, to: 40)
| fieldsAdd loglevel = if(contains(head, " ERROR"), "ERROR", else: if(contains(head, " WARN"), "WARN",
                       else: if(contains(head, " INFO"), "INFO", else: if(contains(head, " DEBUG"), "DEBUG", else: "NONE"))))
| fieldsRemove head
```

## 1. Contexto común.
Condición:
```
matchesValue(aws.log_group, "/aws/ecs/srv/*") and (matchesValue(aws.log_group, "*-adapter") or matchesValue(aws.log_group, "*-mngr"))
```
Script:
```
parse aws.log_group, "'/aws/ecs/srv/' LD:cluster_raw 'ws-'"
| fieldsAdd nexus.cluster = concat(cluster_raw, "ws"),
            nexus.layer = if(endsWith(aws.log_group, "-adapter"), "adapter", else: "mngr"),
            nexus.component = replaceString(aws.log_group, "/aws/ecs/srv/", "")
| fieldsRemove cluster_raw
```

## 2. Headers del adaptador.
Condición:
```
matchesValue(aws.log_group, "*-adapter") and matchesValue(content, "*::HEAD::[*")
```
Script:
```
parse content, "LD 'X-RqUid=' LD:rquid ','"
| parse content, "LD 'X-Name=' LD:channel ','"
| parse content, "LD 'X-Referer=' LD:referer ','"
| fieldsAdd nexus.rquid = rquid, nexus.channel = channel, nexus.service = splitString(referer, "-")[3]
| fieldsRemove rquid, channel, referer
```

## 3. Respuesta del adaptador.
Condición:
```
matchesValue(aws.log_group, "*-adapter") and matchesValue(content, "*::AUDIT::RESP::*")
```
Script:
```
parse content, "LD '::HTTPCODE::' SPACE? INT:http_code"
| fieldsAdd nexus.kind = "audit_resp", nexus.http_code = http_code,
            nexus.outcome = if(isNull(http_code), "unknown", else: if(http_code >= 200 and http_code < 300, "ok_2xx",
                            else: if(http_code == 412, "business_412", else: "error")))
| fieldsRemove http_code
```

## 4. Excepciones del adaptador (mapeo / 504 / técnicas).
Condición:
```
matchesValue(aws.log_group, "*-adapter") and matchesValue(content, "*GenericExceptionMapper*") and matchesValue(content, "*HttpCode::*")
```
Script:
```
parse content, "LD 'HttpCode::' SPACE? INT:http_code"
| parse content, "LD 'Exception:' SPACE? INT:exc_code"
| parse content, "LD 'Exception:' LD '::' SPACE? LD ' .' ALPHA:direction ':' SPACE? LD:rule '. 1=' LD:params SPACE? '::HEAD::'"
| fieldsAdd args = splitString(params, ", ")
| fieldsAdd nexus.kind = if(exc_code == 504, "timeout_504", else: if(http_code == 400, "mapping_error", else: "technical_error")),
            nexus.http_code = http_code,
            nexus.mapping.direction = direction,
            nexus.mapping.rule = rule,
            nexus.mapping.field = if(contains(rule, "para: %3"), substring(args[2], from: 2), else: args[0])
| fieldsRemove http_code, exc_code, direction, rule, params, args
```
(`nexus.mapping.field` es el nombre del campo, no su valor: los valores `1=`/`2=` pueden ser datos del cliente.)

## 5. Tiempo de backend (RSIN).
Condición:
```
matchesValue(aws.log_group, "*-adapter") and matchesValue(content, "*RSIN*")
```
Script:
```
parse content, "LD 'RSIN ' LD ':' LD ',3=' DOUBLE:ms_stratus"
| parse content, "LD 'RSIN ' LD ':' LD ', 1=' DOUBLE:ms_iseries"
| fieldsAdd nexus.duration_ms = coalesce(ms_stratus, ms_iseries)
| fieldsAdd nexus.kind = "backend_time",
            nexus.latency_bucket = if(nexus.duration_ms < 100, "0-100ms", else: if(nexus.duration_ms < 500, "100-500ms",
                                   else: if(nexus.duration_ms < 1000, "500ms-1s", else: if(nexus.duration_ms < 5000, "1-5s", else: "5s+"))))
| fieldsRemove ms_stratus, ms_iseries
```

## 6. Trazas y pasos del ESB (mngr).
Condición:
```
matchesValue(aws.log_group, "*-mngr") and matchesValue(content, "*[/*")
```
Script:
```
fieldsAdd parts = arrayReverse(splitString(trim(content), "["))
| fieldsAdd step = replaceString(parts[1], "]", ""), step_time = replaceString(parts[0], "]", "")
| parse step_time, "DOUBLE:step_ms"
| fieldsAdd ids_end = indexOf(content, "][/ESBService/")
| fieldsAdd ids = if(ids_end > 0, arrayReverse(splitString(substring(content, from: 0, to: ids_end), "[")))
| parse content, "LD '/ESBService/' LD:service_raw ']'"
| fieldsAdd is_step = isNotNull(step_ms) and step != "AuditLog"
| fieldsAdd nexus.kind = if(is_step, "esb_step", else: "mngr_trace"),
            nexus.esb.step = if(is_step, step),
            nexus.duration_ms = if(is_step, step_ms),
            nexus.rquid = replaceString(ids[1], "]", ""),
            nexus.channel = ids[0],
            nexus.service = splitString(splitString(service_raw, ":")[0], "/")[0]
| fieldsRemove parts, step, step_time, step_ms, ids_end, ids, service_raw, is_step
```
rquid y canal salen de los dos corchetes que van justo antes de `[/ESBService/...]`
(`...[rquid][canal][/ESBService/...`). Así funciona con y sin el prefijo `[!dt ...]` del OneAgent; antes el rquid
se buscaba después de `] [`, que solo existe cuando la línea trae ese prefijo o `[trace]`.

## 7. Errores del mngr.
Condición:
```
matchesValue(aws.log_group, "*-mngr") and matchesValue(content, "*[ERROR*")
```
Script:
```
fieldsAdd nexus.kind = if(contains(content, "[ERROR"), "mngr_error", else: nexus.kind)
```
La condición tiene que ser esta, tal cual: con `*-mngr` (sin el asterisco no coincide ningún log group y el procesador
no corre nunca) y con `matchesValue`, no `matchesPhrase`. Como `matchesValue` no distingue mayúsculas, también deja
pasar `[error` o `[Error...`; por eso el script vuelve a mirar el marcador con `contains`, que sí las distingue: es la
misma definición que la alerta `mngr-errors.dql` y el tablero anterior. Validar con la sección 10.

## 8. Respuesta SOAP al canal.
Condición:
```
matchesValue(aws.log_group, "*-mngr") and matchesValue(content, "*<caracterAceptacion>*")
```
Script:
```
parse content, "LD '<caracterAceptacion>' LD:acceptance '</caracterAceptacion>'"
| parse content, "LD '<codMsgRespuesta>' LD:msg_code '</codMsgRespuesta>'"
| parse content, "LD '<nombreOperacion>' LD:operation '</nombreOperacion>'"
| fieldsAdd nexus.kind = "soap_resp", nexus.acceptance = acceptance, nexus.soap.msg_code = msg_code,
            nexus.soap.operation = operation
| fieldsRemove acceptance, msg_code, operation
```
Hoy `caracterAceptacion` vale B (bien) o M (mal), y se está evaluando agregar C (corregido). El procesador toma lo
que venga entre las etiquetas, así que la C aparece sola como un valor más de `nexus.acceptance`, sin cambiar nada.
Nota: el canal no viaja en la respuesta SOAP (solo en el request). En la ingesta se procesa línea por línea, sin
cruzar request y response, así que los rechazos (M) por canal siguen saliendo de una query de logs con rango corto.

Los WARN no se descartan: además de los errores de mapeo y los 504 (procesador 4), traen estos casos.

## 9. Consumidor que no coincide con el mensaje (WARN del mngr).
Condición:
```
matchesValue(aws.log_group, "*-mngr") and matchesValue(content, "*Consumidor no coincide con el cuerpo del mensaje*")
```
Script:
```
parse content, "LD 'cuerpo del mensaje:' SPACE? LD:value"
| fieldsAdd nexus.kind = "consumer_mismatch", nexus.consumer_mismatch.value = trim(value)
| fieldsRemove value
```
No pasa en todas las transacciones: varía mucho por cluster, así que apunta a consumidores puntuales. Falta que
desarrollo confirme qué es el valor final antes de usarlo como dimensión de una métrica.

## 10. Respuesta de Stratus después del timeout (WARN del adaptador).
Condición:
```
matchesValue(aws.log_group, "*-adapter") and matchesValue(content, "*despues de timeout*")
```
Script:
```
fieldsAdd nexus.kind = "stratus_late_reply"
```
Junto con `timeout_504` separa los timeouts en "Stratus contestó tarde" y "Stratus no contestó".

## 11. Datos incompletos del backend (WARN `[STREAM]` del adaptador).
Condición:
```
matchesValue(aws.log_group, "*-adapter") and matchesValue(content, "*[STREAM]*")
```
Script:
```
parse content, "LD 'atributo=' LD:attribute ','"
| fieldsAdd nexus.kind = if(contains(content, "item incompleto"), "stream_incomplete_list",
                         else: if(contains(content, "caracteres nulos"), "stream_null_chars", else: "stream_other")),
            nexus.stream.attribute = attribute
| fieldsRemove attribute
```

## 12. Errores de apagado (ruido de cada reinicio del adaptador).
Condición:
```
matchesValue(aws.log_group, "*-adapter") and matchesValue(content, "*[Error Occurred After Shutdown]*")
```
Script:
```
fieldsAdd nexus.kind = "shutdown_noise"
```
Son ERROR que aparecen en cada deploy o reinicio y no indican una falla; marcados así no inflan los conteos de errores.
