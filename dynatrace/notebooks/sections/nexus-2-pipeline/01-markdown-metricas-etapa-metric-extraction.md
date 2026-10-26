## Métricas (etapa Metric extraction)

Cada métrica se extrae de las líneas que matchean su condición, con atributos `nexus.*` como dimensiones.
Las claves de las métricas en el tenant empiezan con `custom.nexus.log.`. Sus dimensiones se llaman como en la
columna Dimensiones, sin el prefijo `nexus.` de los atributos: en las consultas sobre métricas se filtra y agrupa
por `cluster`, `outcome`, `service`...; en las consultas sobre logs, por `nexus.cluster`, `nexus.outcome`...

| Hecho | Métrica | Tipo | Condición | Dimensiones | Reemplaza en el tablero |
|---|---|---|---|---|---|
| [x] | `custom.nexus.log.adapter.responses` | counter | `matchesValue(nexus.kind, "audit_resp")` | cluster, service, channel, outcome, http_code | KPIs, respuestas en el tiempo, % error por servicio/canal |
| [x] | `custom.nexus.log.adapter.mapping_errors` | counter | `matchesValue(nexus.kind, "mapping_error")` | cluster, service, channel, mapping.direction, mapping.field | ERRORES DE MAPEO (conteos) |
| [x] | `custom.nexus.log.adapter.timeouts` | counter | `matchesValue(nexus.kind, "timeout_504")` | cluster, service, channel | TIMEOUTS 504 |
| [x] | `custom.nexus.log.adapter.backend_ms` | value (`nexus.duration_ms`) | `matchesValue(nexus.kind, "backend_time")` | cluster, component | LATENCIA ADAPTADOR |
| [x] | `custom.nexus.log.adapter.backend_calls` | counter | `matchesValue(nexus.kind, "backend_time")` | cluster, component, latency_bucket | distribución de latencia (reemplazo del p95) |
| [x] | `custom.nexus.log.mngr.errors` | counter | `matchesValue(nexus.kind, "mngr_error")` | cluster, service, channel | ERROR LOGS, errores por canal |
| [x] | `custom.nexus.log.mngr.soap_responses` | counter | `matchesValue(nexus.kind, "soap_resp")` | cluster, acceptance, soap.operation, soap.msg_code | respuestas al canal B / M / C |
| [x] | `custom.nexus.log.mngr.consumer_mismatch` | counter | `matchesValue(nexus.kind, "consumer_mismatch")` | cluster | nuevo: WARN "Consumidor no coincide" |
| [x] | `custom.nexus.log.adapter.stratus_late_replies` | counter | `matchesValue(nexus.kind, "stratus_late_reply")` | cluster, component | nuevo: respuestas tardías de Stratus |
| [x] | `custom.nexus.log.adapter.stream_issues` | counter | `matchesValue(nexus.kind, "stream_*")` | cluster, component, kind, stream.attribute | nuevo: calidad de datos del backend |
| [x] | `custom.nexus.log.log_lines` | counter | `isNotNull(nexus.cluster) and (isNull(nexus.kind) or not matchesValue(nexus.kind, "shutdown_noise"))` | cluster, component, loglevel | nuevo: volumen por nivel (ERROR / WARN / INFO) |
| [x] | `custom.nexus.log.esb.step_ms` | value (`nexus.duration_ms`) | `matchesValue(nexus.kind, "esb_step")` | cluster, service, esb.step | LATENCIA POR PASO ESB |

La columna Hecho se marca a mano al crear cada métrica en OpenPipeline: `[x]` hecho, `[ ]` pendiente.

Reglas de cardinalidad (lo que más cuesta en métricas):
- No usar `nexus.rquid` ni valores del cliente como dimensión: serían millones de series.
- Cluster, servicio, canal y resultado juntos están bien (cientos o miles de series).
- Cada combinación distinta de dimensiones es una serie que se cobra: antes de sumar una dimensión, preguntar si alguien la va a filtrar.

p95: una métrica de valor da promedio, mínimo, máximo, suma y conteo, pero no garantiza percentiles.
Por eso `backend_calls` lleva `nexus.latency_bucket`: "qué % de llamadas tarda más de 1 s" responde lo mismo que un p95
para alertar.

Qué queda en logs (con rango corto): el ejemplo del error de mapeo, los rquids con error, la traza por rquid y
los rechazos por canal. Eso es el detalle de cada tablero por cluster, no el general (ver notebook Tablero).

Cada métrica va con una prueba que agrupa por sus dimensiones: si una columna sale vacía, esa dimensión
tiene otro nombre en el tenant; si la prueba no devuelve filas, la métrica no tiene datos en el rango.
