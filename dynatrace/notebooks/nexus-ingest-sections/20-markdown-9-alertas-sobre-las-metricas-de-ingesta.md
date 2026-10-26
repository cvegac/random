## 9. Alertas sobre las métricas de ingesta

Dónde: app Anomaly Detection > Custom alerts > New. Cada alerta es una query `timeseries` sobre las métricas
`custom.nexus.log.*`, un analizador y una plantilla de evento.

Por qué cambiarlas: las alertas de hoy (`dynatrace/alerts/*.dql`) corren `fetch logs` cada minuto; con 30M tx/día
escanean el bucket completo todo el día. Sobre métricas, cada evaluación cuesta lo mismo con cualquier volumen.
Como las queries devuelven una serie por `cluster`, Dynatrace evalúa y alerta cada cluster por separado.

Transición: dejar las alertas actuales activas hasta que la métrica de cada una esté validada (sección 10); después crear la nueva y apagar la vieja.

| Hecho | Alerta | Métrica | Analizador | Umbral inicial | Reemplaza |
|---|---|---|---|---|---|
| [ ] | % error real del adaptador | `custom.nexus.log.adapter.responses` | estático, ABOVE | 5 % | `adapters-real-error-pct.dql` |
| [ ] | Timeouts 504 | `custom.nexus.log.adapter.timeouts` | estático, ABOVE | 2 por minuto | `adapters-timeouts.dql` |
| [ ] | Errores de mapeo | `custom.nexus.log.adapter.mapping_errors` | estático, ABOVE | 2 por minuto | `adapters-mapping-errors.dql` |
| [ ] | 5xx del backend | `custom.nexus.log.adapter.responses` | estático, ABOVE | 1 por minuto | `adapters-backend-5xx.dql` |
| [ ] | % respuestas M al canal | `custom.nexus.log.mngr.soap_responses` | estático, ABOVE (después, línea base estacional) | 40 % (a calibrar) | `channel-rejection-pct.dql` |
| [ ] | Errores del mngr | `custom.nexus.log.mngr.errors` | auto-adaptativo | | `mngr-errors.dql` |
| [ ] | % llamadas al backend de más de 1 s | `custom.nexus.log.adapter.backend_calls` | estático, ABOVE | 5 % | `mngr-latency-p90.dql` (ver nota) |
| [ ] | Respuestas tardías de Stratus | `custom.nexus.log.adapter.stratus_late_replies` | auto-adaptativo | | nueva |
| [ ] | Consumidor que no coincide (por 100 tx) | `custom.nexus.log.mngr.consumer_mismatch` | auto-adaptativo | | nueva |
| [ ] | Datos incompletos del backend | `custom.nexus.log.adapter.stream_issues` | auto-adaptativo | | nueva |
| [ ] | Caída de tráfico | `custom.nexus.log.adapter.responses` | línea base estacional, BELOW | | nueva |

La columna Hecho se marca a mano: `[x]` hecho, `[ ]` pendiente.

Configuración común, la misma que las alertas actuales: violating samples 3, sliding window 5, dealerting
samples 5, alert on missing data apagado (salvo la caída de tráfico, donde no tener datos es justamente la falla).
Los umbrales de hoy se calibraron para todos los clusters juntos; por cluster pueden necesitar ajuste, sobre todo
en los clusters con poco tráfico. En la plantilla del evento, poner el cluster en el título, por ejemplo
`Nexus: timeouts 504 en {dims:cluster}` (verificar el formato del placeholder en el tenant).
Para que lleguen notificaciones hace falta un Workflow que tome estos eventos; hoy no hay ninguno.

Nota: ninguna de estas queries está probada; se pueden correr en un notebook en cuanto exista la métrica.
`interval: 1m` y `default: 0` hacen que los minutos sin datos cuenten como 0 y no como hueco.

% error real del adaptador (2xx y 412 no son error; minutos con 10 respuestas o menos cuentan como 0):
```
timeseries total = sum(custom.nexus.log.adapter.responses, default: 0), by: { cluster }, interval: 1m
| join [
    timeseries errors = sum(custom.nexus.log.adapter.responses, default: 0), by: { cluster },
        filter: outcome == "error", interval: 1m
  ], on: { cluster }, fields: { errors }
| fieldsAdd error_pct = if(total[] > 10, 100.0 * errors[] / total[], else: 0.0)
| fieldsKeep timeframe, interval, cluster, error_pct
```

Timeouts 504:
```
timeseries timeouts = sum(custom.nexus.log.adapter.timeouts, default: 0), by: { cluster }, interval: 1m
```

Errores de mapeo:
```
timeseries mapping_errors = sum(custom.nexus.log.adapter.mapping_errors, default: 0), by: { cluster }, interval: 1m
```

5xx del backend:
```
timeseries backend_5xx = sum(custom.nexus.log.adapter.responses, default: 0), by: { cluster },
    filter: startsWith(http_code, "5"), interval: 1m
```

% respuestas M al canal (la C no cuenta como M hasta que negocio defina qué es):
```
timeseries total = sum(custom.nexus.log.mngr.soap_responses, default: 0), by: { cluster }, interval: 1m
| join [
    timeseries rejected = sum(custom.nexus.log.mngr.soap_responses, default: 0), by: { cluster },
        filter: acceptance == "M", interval: 1m
  ], on: { cluster }, fields: { rejected }
| fieldsAdd rejection_pct = if(total[] > 10, 100.0 * rejected[] / total[], else: 0.0)
| fieldsKeep timeframe, interval, cluster, rejection_pct
```

Errores del mngr:
```
timeseries mngr_errors = sum(custom.nexus.log.mngr.errors, default: 0), by: { cluster }, interval: 1m
```

% llamadas al backend de más de 1 s:
```
timeseries total = sum(custom.nexus.log.adapter.backend_calls, default: 0), by: { cluster }, interval: 1m
| join [
    timeseries slow = sum(custom.nexus.log.adapter.backend_calls, default: 0), by: { cluster },
        filter: in(latency_bucket, array("1-5s", "5s+")), interval: 1m
  ], on: { cluster }, fields: { slow }
| fieldsAdd slow_pct = if(total[] > 10, 100.0 * slow[] / total[], else: 0.0)
| fieldsKeep timeframe, interval, cluster, slow_pct
```
Nota: la alerta actual de latencia suma los pasos del ESB por transacción (p90 de punta a punta). Eso necesita
agrupar por rquid, y una métrica no puede hacerlo. Esta alerta mide la parte del backend; la de punta a punta
puede quedar sobre logs, pero evaluada cada 5 minutos y no cada minuto.

Respuestas tardías de Stratus:
```
timeseries late_replies = sum(custom.nexus.log.adapter.stratus_late_replies, default: 0), by: { cluster }, interval: 1m
```

Consumidor que no coincide, por cada 100 transacciones (el nivel normal cambia mucho entre clusters, por eso
auto-adaptativo y no un umbral fijo):
```
timeseries tx = sum(custom.nexus.log.adapter.responses, default: 0), by: { cluster }, interval: 5m
| join [
    timeseries mismatches = sum(custom.nexus.log.mngr.consumer_mismatch, default: 0), by: { cluster }, interval: 5m
  ], on: { cluster }, fields: { mismatches }
| fieldsAdd per_100_tx = if(tx[] > 50, 100.0 * mismatches[] / tx[], else: 0.0)
| fieldsKeep timeframe, interval, cluster, per_100_tx
```

Datos incompletos del backend:
```
timeseries stream_issues = sum(custom.nexus.log.adapter.stream_issues, default: 0), by: { cluster }, interval: 5m
```

Caída de tráfico (alert on missing data encendido):
```
timeseries responses = sum(custom.nexus.log.adapter.responses, default: 0), by: { cluster }, interval: 5m
```
