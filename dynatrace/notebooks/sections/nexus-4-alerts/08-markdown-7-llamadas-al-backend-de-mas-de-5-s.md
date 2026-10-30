### 7. % llamadas al backend de más de 5 s

Estático, ABOVE, umbral 5 %.

Temporal (27/10): el corte pasó de 1 s a 5 s porque disparaba demasiado de madrugada. 5 s es el timeout del
canal, así que avisa cuando el canal ya está fallando. El objetivo acordado es 2 a 3 s sostenidos: para eso hay
que partir el tramo `1-5s` del procesador 5 en `1-3s` y `3-5s` y cambiar este filtro a `in(latency_bucket, array("3-5s", "5s+"))`.

Nota: la alerta actual de latencia suma los pasos del ESB por transacción (p90 de punta a punta). Eso necesita
agrupar por rquid, y una métrica no puede hacerlo. Esta alerta mide la parte del backend; la de punta a punta
puede quedar sobre logs, pero evaluada cada 5 minutos y no cada minuto.

Plantilla del evento. Título:
```
Nexus: llamadas al backend de más de 5 s en {dims:cluster}
```
Descripción:
```
Más del 5 % de las llamadas de los adaptadores de {dims:cluster} al backend tardaron más de 5 s (tiempo RSIN)
en 3 de los últimos 5 minutos. 5 s es el timeout del canal: el canal ya está recibiendo fallas.
Los minutos con 10 llamadas o menos no cuentan.
Revisar en el tablero Nexus V2: "LATENCIA BACKEND POR ADAPTADOR (promedio ms)" y "LLAMADAS AL BACKEND POR TRAMO DE LATENCIA" para
ver qué adaptador; suele venir junto con timeouts 504.
Tablero con la alerta (Nexus V2, sección 3. Alertas en el rango, "7. % LLAMADAS AL BACKEND DE MÁS DE 5 S"):
<url-nexus-v2>
```
